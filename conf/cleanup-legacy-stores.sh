#!/bin/bash
# cleanup-legacy-stores.sh — step 7 of the ADR 0008 migration: delete the legacy /app/data stores, but
# ONLY once this boot has proven the app actually works on the migrated data.
#
# start.sh launches this in the background on every boot and it exits immediately when there is nothing
# pending, so it needs no special-casing anywhere else. If the app never becomes healthy, the markers
# survive and the next boot's run tries again. Deleting early would throw away the only copy of the data
# before anything had demonstrated the new one serves traffic; deleting late costs one backup run that
# may still walk the legacy tree, which is why this is gated on health rather than deferred a whole boot.
set -uo pipefail

log() { echo "==> [cleanup] $*"; }

HEALTH_URL="http://localhost:3000/api/public/health"
WAIT_SECONDS="${LANGFUSE_CLEANUP_HEALTH_WAIT:-1200}"      # 20 minutes, then give up until next boot

declare -a PENDING=()
for dst in /var/lib/clickhouse /var/lib/minio; do
  [ -e "${dst}/.migration-cleanup-pending" ] && PENDING+=( "${dst}" )
done
[ "${#PENDING[@]}" -eq 0 ] && exit 0

log "legacy cleanup pending for: ${PENDING[*]} — waiting for ${HEALTH_URL} (up to ${WAIT_SECONDS}s)"

waited=0
until curl -sf --max-time 5 "${HEALTH_URL}" >/dev/null 2>&1; do
  sleep 10
  waited=$(( waited + 10 ))
  if [ "${waited}" -ge "${WAIT_SECONDS}" ]; then
    log "app did not become healthy within ${WAIT_SECONDS}s — leaving the legacy trees in place."
    log "They will be retried on the next boot. This is safe: the data is already migrated and"
    log "verified, the legacy copy is redundant, and keeping it costs only disk and the chance that"
    log "a backup run walks it."
    exit 0
  fi
done

log "app is healthy after ${waited}s — removing the redundant legacy trees"
for dst in "${PENDING[@]}"; do
  marker="${dst}/.migration-cleanup-pending"
  src="$(head -1 "${marker}" 2>/dev/null || true)"
  case "${src}" in
    /app/data/clickhouse|/app/data/minio) ;;                      # only ever these two
    *) log "refusing to delete unexpected path '${src}' recorded in ${marker}"; continue ;;
  esac
  if [ -d "${src}" ]; then
    bytes="$(du -sb "${src}" 2>/dev/null | cut -f1 || echo '?')"
    if rm -rf "${src}" && [ ! -e "${src}" ]; then
      log "removed ${src} (reclaimed ${bytes} bytes, and took it out of the backup walk)"
    else
      # KEEP the marker. A half-deleted legacy tree with no marker is the exact input that makes the
      # next boot's migration read it as a restored backup and discard the live store.
      log "WARNING: could not fully remove ${src}. Leaving the cleanup marker in place so the next"
      log "boot retries, and so the migration does not mistake the remains for a restored backup."
      continue
    fi
  fi
  rm -f "${marker}"
done
log "legacy cleanup complete"
