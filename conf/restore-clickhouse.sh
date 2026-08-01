#!/bin/bash
# restore-clickhouse.sh — rebuilds the ClickHouse and MinIO persistentDirs from the copies that
# backup-clickhouse.sh left in /app/data. Implements boot leg 3 of ADR 0009.
#
# IT IS CALLED FROM TWO PLACES, deliberately:
#   1. Cloudron's restoreCommand, in a temporary container before the app starts.
#   2. start.sh, on every boot, as leg 3.
# On a CLONE both fire, in that order, and it is the restoreCommand that actually rebuilds (measured on
# the rig: by the time leg 3 ran, both stores were populated and it no-opped). The boot leg still
# carries real weight: no restoreCommand runs on a plain boot, so it alone serves the KNOWN-ISSUES
# recipe (empty the store, restart, rebuild from the dump) and backstops a skipped or dead
# restoreCommand. The pair is only safe because this script is idempotent, no-ops loudly, and tests
# for a real store sentinel rather than a non-empty directory. See ADR 0009's correction note.
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
  # "Populated" must mean REAL DATA, not merely a directory. start.sh pre-creates the bucket
  # directory, so an `ls -A` test here would report every clone as already populated and silently
  # skip the MinIO rebuild, losing every media and event blob on the one path that has to work.
  if [ -d "${MINIO_STORE}/.minio.sys" ]; then
    log "MinIO persistentDir already holds a MinIO store — refusing to clobber (no-op)"
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
# The rebuild marker is checked BEFORE the dump, deliberately. A store carrying the marker is a store
# whose rebuild was interrupted, and it is partial: booting on it means silently missing data. If the
# dump has also gone, that is a genuine emergency and must be fatal, not a cheerful "nothing to do".
if [ -e "${REBUILD_MARKER}" ]; then
  if [ ! -d "${DUMP}" ]; then
    log "FATAL: a rebuild was interrupted (marker present) but the dump at ${DUMP} is GONE."
    log "The store is partial and there is nothing to rebuild it from. Refusing to start on it."
    log "Restore this app from a backup that contains ${DUMP}."
    exit 1
  fi
  log "a previous rebuild was interrupted (marker present) — discarding the partial store and retrying"
  find "${CH_STORE}" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
elif [ ! -d "${DUMP}" ]; then
  log "no ClickHouse dump at ${DUMP} (fresh install) — nothing to restore"
  exit 0
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
