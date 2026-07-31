#!/bin/bash
# restore-clickhouse.sh — rebuilds the ClickHouse and MinIO persistentDirs from the copies that
# backup-clickhouse.sh left in /app/data. Implements boot leg 3 of ADR 0009.
#
# IT IS CALLED FROM TWO PLACES, deliberately:
#   1. Cloudron's restoreCommand, in a temporary container before the app starts.
#   2. start.sh, on every boot, as leg 3.
# The second is the one that carries the load. A restoreCommand cannot tell an in-place restore from an
# ordinary restart and does not run at all on a plain boot, whereas the only operation that leaves a
# persistentDir EMPTY is a clone. So the boot path is what actually rebuilds a cloned install, and this
# script is written to be idempotent and to no-op loudly when there is nothing to do.
#
# CRITICAL (ADR 0006/0009): the dump MUST be restored through a real clickhouse-SERVER, never
# `clickhouse local`. A `clickhouse local` RESTORE omits the implicit `default` database metadata and
# Atomic-UUID layout, and the real server then crash-loops with Code 48. Worse, another `clickhouse
# local` CAN read that broken store, so a gate that verifies with `clickhouse local` passes while
# production fails.
set -euo pipefail

CH_STORE=/var/lib/clickhouse
MINIO_STORE=/var/lib/minio
DUMP=/app/data/clickhouse-backup
MDUMP=/app/data/minio-backup
SECRETS=/app/data/.secrets/secrets.env
REBUILD_MARKER="${CH_STORE}/.rebuild-in-progress"

log() { echo "==> [restore] $*"; }

# ---- MinIO: a plain copy back into its empty persistentDir ---------------------------------------
if [ -d "${MDUMP}" ] && [ -n "$(ls -A "${MDUMP}" 2>/dev/null)" ]; then
  if [ -n "$(ls -A "${MINIO_STORE}" 2>/dev/null)" ]; then
    log "MinIO persistentDir already populated — refusing to clobber (no-op)"
  else
    log "restoring MinIO ${MDUMP} -> ${MINIO_STORE}"
    mkdir -p "${MINIO_STORE}"
    rsync -a "${MDUMP}/" "${MINIO_STORE}/"
    chown -R cloudron:cloudron "${MINIO_STORE}"
    log "MinIO restore complete ($(du -sh "${MINIO_STORE}" 2>/dev/null | cut -f1))"
  fi
else
  log "no MinIO copy at ${MDUMP} — skipping"
fi

# ---- ClickHouse: rebuild through a transient server -----------------------------------------------
if [ ! -d "${DUMP}" ]; then
  log "no ClickHouse dump at ${DUMP} (fresh install) — nothing to restore"
  exit 0
fi

# A store carrying the rebuild marker is a store whose rebuild was interrupted. Treat it as empty and
# start again: a partially restored ClickHouse store opens happily and is simply missing data, which is
# precisely the silent failure this package is being rebuilt to avoid.
if [ -e "${REBUILD_MARKER}" ]; then
  log "a previous rebuild was interrupted (marker present) — discarding the partial store and retrying"
  find "${CH_STORE}" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
elif [ -d "${CH_STORE}/store" ] || [ -d "${CH_STORE}/metadata" ]; then
  log "ClickHouse persistentDir already populated — refusing to clobber (no-op)"
  exit 0
fi

if [ ! -f "${SECRETS}" ]; then
  log "FATAL: ${SECRETS} missing — cannot start ClickHouse to restore into"
  exit 1
fi

log "restoring the ClickHouse 'default' database from ${DUMP} via a transient clickhouse-server"
mkdir -p "${CH_STORE}"/{tmp,logs,access,user_files,format_schemas}
touch "${REBUILD_MARKER}"
chown -R cloudron:cloudron "${CH_STORE}"

# The ClickHouse user's password comes from the environment (users.d uses <password from_env=...>), so
# export it for the transient server. `su` without a dash preserves the exported environment.
set -a; . "${SECRETS}"; set +a

# Background, NOT --daemon: --daemon conflicts with the console logger this package configures.
su -s /bin/bash cloudron -c "exec clickhouse-server --config-file=/etc/clickhouse-server/config.xml" \
  > /tmp/restore-ch.log 2>&1 &
SVPID=$!
cleanup() { kill -TERM "${SVPID}" 2>/dev/null || true; wait "${SVPID}" 2>/dev/null || true; }
trap cleanup EXIT

i=0
until curl -sf http://localhost:8123/ping >/dev/null 2>&1; do
  i=$(( i + 1 ))
  if [ "${i}" -ge 90 ]; then
    log "FATAL: the transient ClickHouse did not become ready within 90s"
    tail -20 /tmp/restore-ch.log
    exit 1
  fi
  sleep 1
done
log "transient ClickHouse is up — running RESTORE"

# Both settings are required: allow_different_table_def for views whose dictionary references ClickHouse
# re-normalises, allow_different_database_def for the database-level UUID mismatch against the server's
# auto-created `default`.
if ! clickhouse-client --user clickhouse --password "${CLICKHOUSE_PASSWORD}" \
       --query "RESTORE DATABASE default FROM File('clickhouse-backup') SETTINGS allow_different_table_def=1, allow_different_database_def=1" 2>&1 | grep -q RESTORED; then
  log "FATAL: RESTORE failed"
  tail -20 /tmp/restore-ch.log
  exit 1
fi

log "RESTORE ok — stopping the transient ClickHouse cleanly"
cleanup
trap - EXIT
rm -f "${REBUILD_MARKER}"
chown -R cloudron:cloudron "${CH_STORE}"
log "ClickHouse restore complete: $(du -sh "${CH_STORE}" 2>/dev/null | cut -f1)"
