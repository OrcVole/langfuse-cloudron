#!/bin/bash
# migrate-stores.sh — the one-time relocation of the ClickHouse and MinIO stores out of /app/data into
# their persistentDirs. Implements ADR 0008; invoked by start.sh as boot leg 0, before supervisord and
# therefore before either server is running, so the SOURCE IS QUIESCENT. That is the whole trick: a copy
# whose source cannot change can be verified by simply re-running it.
#
# WHY NOT `mv` (ADR 0008, and this is measured, not reasoned): a persistentDir is bind-mounted from
# /home/yellowtent/platformdata/persistent/<appid>/... It is on the SAME ext4 filesystem as /app/data and
# reports the same st_dev inside the container, but it is a SEPARATE MOUNT, and Linux refuses rename(2)
# across mount points. `os.rename` returns EXDEV; `mv` silently degrades to copy-then-unlink. There is no
# fast path, so this is a multi-gigabyte byte copy and must be interruption-safe.
#
# MARKERS (all live in the destination, all excluded from the rsync so --delete cannot eat them):
#   .migration-in-progress    a copy has started and has NOT been verified
#   .migration-verified       the copy has been verified complete; the legacy tree is now redundant
#   .migration-cleanup-pending the legacy tree still exists and may be deleted once the app is healthy
#
# Splitting "is the data safe" from "has the old copy been cleaned up" is what makes every interruption
# point safe: a killed copy resumes, a killed verify re-verifies, a killed cleanup is retried next boot.
set -euo pipefail

log() { echo "==> [migrate] $*"; }

# Shared excludes. The ClickHouse transients are excluded because ClickHouse discards them at startup and
# they are the very directories whose vanishing causes the defect this release fixes; /status is the lock
# file, regenerated on start. The marker exclude is load-bearing: without it, --delete would remove our
# own markers, because they do not exist in the source.
RSYNC_COMMON=( -a --delete --exclude='/.migration-in-progress'
                             --exclude='/.migration-verified'
                             --exclude='/.migration-cleanup-pending'
                             --exclude='/.rebuild-in-progress' )
RSYNC_CH=( --exclude='/status' --exclude='/tmp/' --exclude='/shadow/' --exclude='tmp_*' )

# A legacy tree counts as "present" only when it actually HOLDS DATA, never merely because the directory
# exists. This is load-bearing, not fastidiousness: if anything ever recreates an empty /app/data/clickhouse
# after a completed migration, a bare -d test would read it as a restored legacy backup and discard the
# live persistentDir. Requiring real content makes that impossible.
# A sentinel directory that EXISTS but is EMPTY does not count. `rm -rf` unlinks the top directory
# last, so a killed cleanup routinely leaves a bare store/ skeleton behind; treating that as data
# would let it masquerade as a restored legacy backup and destroy a live multi-gigabyte store.
store_populated() {                       # $1 = path, $2 = space-separated sentinel subdirs ("" = any content)
  local path="$1" sentinels="${2:-}" s
  [ -d "${path}" ] || return 1
  if [ -n "${sentinels}" ]; then
    for s in ${sentinels}; do
      [ -d "${path}/${s}" ] && [ -n "$(ls -A "${path}/${s}" 2>/dev/null)" ] && return 0
    done
    return 1
  fi
  [ -n "$(ls -A "${path}" 2>/dev/null)" ]
}

# migrate_store <label> <source> <destination> <sentinels> [extra rsync args...]
migrate_store() {
  local label="$1" src="$2" dst="$3" sentinels="$4"; shift 4
  local extra=( "$@" )
  local marker_prog="${dst}/.migration-in-progress"
  local marker_done="${dst}/.migration-verified"
  local marker_clean="${dst}/.migration-cleanup-pending"

  mkdir -p "${dst}"

  # ---- Step 1: nothing to do? ---------------------------------------------------------------------
  if ! store_populated "${src}" "${sentinels}"; then
    return 0                                   # fresh install, or the legacy tree is already cleaned up
  fi

  # ---- Step 2: cleanup still pending from our own earlier migration -------------------------------
  # The legacy tree is present because WE have not deleted it yet, not because anything new arrived.
  if [ -e "${marker_clean}" ]; then
    log "${label}: already migrated; legacy tree still present, cleanup deferred to the health gate"
    return 0
  fi

  # ---- Step 3: legacy data is present and no cleanup is pending ------------------------------------
  # Either this is the first migration, or an operator has restored a pre-0.2.0 backup on top of a
  # v0.2.0 install. Those two are the same operation; the only difference is whether the destination
  # currently holds anything worth mentioning. Deliberately NOT decided by comparing mtimes: Cloudron's
  # restore preserves them, so a restored legacy tree is routinely OLDER than the marker it must beat.
  # Resuming our own interrupted copy is excluded here and handled in step 4.
  # NOTE the destination test uses store_populated, NOT `ls -A`. start.sh must not create anything
  # inside a persistentDir before this runs, but defence in depth is cheap and the consequence of
  # getting it wrong is destroying a live store: an incidental subdirectory must never read as data.
  if [ ! -e "${marker_prog}" ] && store_populated "${dst}" "${sentinels}"; then
    log "${label}: legacy data at ${src} while ${dst} is already populated and no migration of ours"
    log "${label}: is outstanding. Reading this as a pre-0.2.0 backup restored onto 0.2.0, which is"
    log "${label}: what an operator restoring that backup is asking for. DISCARDING the current"
    log "${label}: contents of ${dst} and migrating the restored data in their place."
    rm -f "${marker_done}"
    find "${dst}" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
  elif [ -e "${marker_done}" ]; then
    rm -f "${marker_done}"                     # stale: a fresh migration is about to re-establish it
  fi

  # ---- Step 4: mark, so an interruption is recognisable next boot --------------------------------
  local src_bytes; src_bytes="$(du -sb "${src}" 2>/dev/null | cut -f1 || echo unknown)"
  if [ -e "${marker_prog}" ]; then
    log "${label}: RESUMING an interrupted migration (marker present)"
  else
    printf 'source=%s\nstarted=%s\nsource_bytes=%s\n' \
           "${src}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${src_bytes}" > "${marker_prog}"
    log "${label}: starting migration ${src} -> ${dst} (${src_bytes} bytes)"
  fi

  # ---- Step 5: the copy. Idempotent and resumable; re-running copies only what is missing ---------
  local rc=0
  rsync "${RSYNC_COMMON[@]}" "${extra[@]}" "${src}/" "${dst}/" || rc=$?
  if [ "${rc}" -ne 0 ]; then
    log "${label}: FATAL: rsync failed (rc=${rc}). The marker is left in place so the next boot"
    log "${label}: resumes rather than starting over. Refusing to start on a partial store."
    return "${rc}"
  fi

  # ---- Step 6: verify by re-running the same copy as a dry run ------------------------------------
  # This asks exactly the right question ("is anything still missing or different?") and accounts for
  # the excludes automatically, because it uses the same ones. Comparing du totals would not: totals
  # can match while files differ, and the excludes mean the two trees are legitimately not identical.
  # This is the last gate before cleanup-legacy-stores.sh deletes the only other copy of the data, so
  # it must FAIL CLOSED. Capture rsync's status and let its stderr reach the boot log: discarding
  # either would turn "rsync could not run" into "nothing left to transfer", i.e. "verified".
  local pending vrc=0
  pending="$(rsync "${RSYNC_COMMON[@]}" "${extra[@]}" --dry-run --itemize-changes "${src}/" "${dst}/" 2>&1)" || vrc=$?
  if [ "${vrc}" -ne 0 ]; then
    log "${label}: FATAL: the verification pass itself failed (rc=${vrc}). Treating as NOT verified."
    printf '%s\n' "${pending}" | head -20 | sed 's/^/    /' || true
    log "${label}: marker left in place; refusing to start."
    return 1
  fi
  if [ -n "${pending}" ]; then
    log "${label}: FATAL: verification found work still outstanding after the copy:"
    # `| head` would SIGPIPE printf, and pipefail would then abort before the explanation below.
    printf '%s\n' "${pending}" | head -20 | sed 's/^/    /' || true
    log "${label}: marker left in place; refusing to start."
    return 1
  fi
  log "${label}: verified complete ($(du -sb "${dst}" 2>/dev/null | cut -f1 || echo '?') bytes, $(find "${dst}" -type f 2>/dev/null | wc -l) files)"

  # ---- Step 7: publish the result -----------------------------------------------------------------
  # Clear the in-progress marker FIRST. A crash between the two publish writes would otherwise leave
  # all three markers present, and step 2 would then return early forever, so the stale in-progress
  # marker would permanently suppress the legacy-restore branch for a genuine future restore.
  rm -f "${marker_prog}"
  printf 'source=%s\nverified=%s\n' "${src}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${marker_done}"
  printf '%s\n' "${src}" > "${marker_clean}"
  chown -R cloudron:cloudron "${dst}"
  log "${label}: migration complete. Legacy tree kept until the app is proven healthy."
}

CH_SRC=/app/data/clickhouse
CH_DST=/var/lib/clickhouse
MINIO_SRC=/app/data/minio
MINIO_DST=/var/lib/minio

# MinIO's sentinel is .minio.sys, the directory the server itself creates to mark a real store. The
# bucket directory will NOT do: start.sh pre-creates it, so using it would make an empty layout count
# as data. restore-clickhouse.sh keys off the same sentinel, deliberately.
migrate_store clickhouse "${CH_SRC}"    "${CH_DST}"    "store metadata" "${RSYNC_CH[@]}"
migrate_store minio      "${MINIO_SRC}" "${MINIO_DST}" ".minio.sys"
