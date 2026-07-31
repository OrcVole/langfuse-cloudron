#!/bin/bash
# backup-clickhouse.sh — Cloudron backupCommand (ADR 0006). Captures BOTH bundled stores, ClickHouse and
# MinIO, from their persistentDirs into /app/data, where Cloudron's filesystem backup picks them up.
#
# It runs in a TEMPORARY container: /app/data and the persistentDirs are bind-mounted, there is NO
# CLOUDRON_* environment, the rootfs is read-only and stdout is discarded. That last point is why this
# script also appends a status line to /app/data/.last-backup.log, which is its only durable channel.
#
# WHY A SNAPSHOT AND NOT A DIRECT DUMP. The live app keeps running throughout: Cloudron does not quiesce
# it, and there is no pre/post-backup hook to stop merges with. A direct `clickhouse local` against the
# live persistentDir fails even at idle, because the running server holds an flock on <store>/status and
# that inode is shared across the bind mount (Code 76, CANNOT_OPEN_FILE). So: rsync the store to an
# unlocked copy, then dump from the copy. MergeTree parts are immutable and linger old_parts_lifetime
# (~8 minutes), so a copy that finishes inside that window is coherent, and rsync's exit 24 (source file
# vanished) is expected and tolerated.
#
# ORDER MATTERS, AND IT IS THE OPPOSITE OF LAMINAR'S. Dump ClickHouse FIRST, copy MinIO LAST, so MinIO is
# the fresher capture. Langfuse's references run from rows to blobs: Postgres media metadata and
# ClickHouse observations point AT MinIO objects, so a blob captured earlier than the row referencing it
# is a broken attachment. Postgres is dumped by Cloudron AFTER this command and is therefore freshest of
# all; that residual window cannot be closed from here and costs at worst a broken link, not corruption.
# Net oldest to newest: ClickHouse <= MinIO <= Postgres.
set -euo pipefail

CH_STORE=/var/lib/clickhouse
MINIO_STORE=/var/lib/minio
DUMP=/app/data/clickhouse-backup
MDUMP=/app/data/minio-backup
SNAP=/app/data/.clickhouse-snapshot        # transient: built and removed within this command
CONF=/etc/clickhouse-server/backups.xml
STATUS=/app/data/.last-backup.log

log() { echo "==> [backup] $*"; }
status() { printf '%s  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "${STATUS}" 2>/dev/null || true; }
fail() { log "FATAL: $*"; status "FAILED: $*"; exit "${2:-1}"; }

# ---- 0. Interlock: never dump a store that is mid-migration or mid-rebuild -----------------------
# Publishing is destructive (the previous dump is replaced), and both the migration and the leg-3
# rebuild pass through states where store/ and metadata/ exist but are INCOMPLETE. Without this check
# a backup landing in that window would overwrite the last good dump with a truncated one, and a
# subsequent rebuild would restore from the truncation. Exit non-zero so the run is recorded as
# failed rather than quietly producing a bad backup.
for _m in .migration-in-progress .rebuild-in-progress; do
  if [ -e "${CH_STORE}/${_m}" ] || [ -e "${MINIO_STORE}/${_m}" ]; then
    log "FATAL: a store is mid-operation (${_m} present). Refusing to publish a dump over the"
    log "last good one from a store that is not yet complete. Retry once the app has settled."
    status "FAILED: refused, ${_m} present"
    exit 1
  fi
done

# ---- 1. ClickHouse FIRST, so it is the OLDER capture ---------------------------------------------
if [ ! -d "${CH_STORE}/store" ] && [ ! -d "${CH_STORE}/metadata" ]; then
  log "ClickHouse persistentDir empty or absent — nothing to dump"
  status "ok: ClickHouse store empty, nothing dumped"
else
  log "snapshotting the committed ClickHouse store ${CH_STORE} -> ${SNAP} (excl /status, /tmp, /shadow, tmp_*)"
  rm -rf "${SNAP}" "${DUMP}.new" "${DUMP}.old"
  mkdir -p "${SNAP}"
  rc=0
  rsync -a \
    --exclude='/status' --exclude='/tmp/' --exclude='/shadow/' --exclude='tmp_*' \
    --exclude='/.migration-in-progress' --exclude='/.migration-verified' \
    --exclude='/.migration-cleanup-pending' --exclude='/.rebuild-in-progress' \
    "${CH_STORE}/" "${SNAP}/" || rc=$?
  # 24 == "some source files vanished during transfer", which is exactly the churn this design expects.
  if [ "${rc}" -ne 0 ] && [ "${rc}" -ne 24 ]; then
    rm -rf "${SNAP}"
    fail "ClickHouse snapshot rsync failed (rc=${rc})" "${rc}"
  fi

  log "dumping the ClickHouse 'default' database from the snapshot ($(du -sh "${SNAP}" 2>/dev/null | cut -f1))"
  # DATABASE default, NOT BACKUP ALL: ALL trips ACCESS_STORAGE_DOESNT_ALLOW_BACKUP on system.users, and
  # this package's ClickHouse user comes from users.d config at boot anyway.
  if ! clickhouse local --path="${SNAP}" --config-file="${CONF}" \
         --query="BACKUP DATABASE default TO File('clickhouse-backup.new')"; then
    rm -rf "${SNAP}" "${DUMP}.new"
    fail "ClickHouse BACKUP query failed"
  fi
  rm -rf "${SNAP}"

  [ -e "${DUMP}" ] && mv "${DUMP}" "${DUMP}.old"
  mv "${DUMP}.new" "${DUMP}"
  rm -rf "${DUMP}.old"
  log "ClickHouse dump published: ${DUMP} ($(du -sh "${DUMP}" 2>/dev/null | cut -f1))"
  status "ok: ClickHouse dumped ($(du -sb "${DUMP}" 2>/dev/null | cut -f1) bytes)"
fi

# ---- 2. MinIO LAST, so it is the FRESHER capture --------------------------------------------------
# MinIO's single-drive layout restores cleanly from a plain file copy. Publish atomically via .new
# then rename, so an interrupted run never leaves a half-written backup where a whole one was.
if [ -d "${MINIO_STORE}" ] && [ -n "$(ls -A "${MINIO_STORE}" 2>/dev/null)" ]; then
  log "copying MinIO ${MINIO_STORE} -> ${MDUMP}"
  rm -rf "${MDUMP}.new" "${MDUMP}.old"
  mrc=0
  rsync -a --delete \
    --exclude='/.minio.sys/tmp/' \
    --exclude='/.migration-in-progress' --exclude='/.migration-verified' \
    --exclude='/.migration-cleanup-pending' \
    "${MINIO_STORE}/" "${MDUMP}.new/" || mrc=$?
  if [ "${mrc}" -ne 0 ] && [ "${mrc}" -ne 24 ]; then
    rm -rf "${MDUMP}.new"
    fail "MinIO copy rsync failed (rc=${mrc})" "${mrc}"
  fi
  [ -e "${MDUMP}" ] && mv "${MDUMP}" "${MDUMP}.old"
  mv "${MDUMP}.new" "${MDUMP}"
  rm -rf "${MDUMP}.old"
  log "MinIO copy published: ${MDUMP} ($(du -sh "${MDUMP}" 2>/dev/null | cut -f1))"
  status "ok: MinIO copied ($(du -sb "${MDUMP}" 2>/dev/null | cut -f1) bytes)"
else
  log "MinIO persistentDir empty or absent — nothing to copy"
  status "ok: MinIO store empty, nothing copied"
fi

log "backup complete"
status "ok: backupCommand complete"
