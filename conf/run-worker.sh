#!/bin/bash
# run-worker.sh — supervised worker process. Waits for dependencies + the web's migration-complete flag,
# then exec's the worker. The worker image's own entrypoint runs NO migrations (the web does).
set -euo pipefail
log() { echo "==> [worker] $*"; }

wait_for() { # <name> <cmd...>
  local name="$1"; shift; local i=0
  until "$@" >/dev/null 2>&1; do
    i=$((i + 1)); [ $((i % 10)) -eq 1 ] && log "waiting for ${name} ..."
    [ "$i" -ge 150 ] && { log "FATAL: ${name} not ready after 300s"; exit 1; }
    sleep 2
  done
  log "${name} ready"
}

cd /app/code/worker
export PORT="3030"
export NODE_OPTIONS="${NODE_OPTIONS:---max-old-space-size=768}"

wait_for "clickhouse" curl -sf http://localhost:8123/ping
wait_for "minio"      curl -sf http://localhost:9100/minio/health/live
REDISCLI_AUTH="${REDIS_AUTH}" wait_for "redis" redis-cli -h "${REDIS_HOST}" -p "${REDIS_PORT}" ping

i=0
until [ -f /run/langfuse/migrated ]; do
  i=$((i + 1)); [ $((i % 15)) -eq 1 ] && log "waiting for migrations to complete ..."
  [ "$i" -ge 200 ] && { log "FATAL: migrations never completed"; exit 1; }
  sleep 2
done

log "dependencies ready — starting worker on :${PORT}"
exec /usr/local/bin/node-musl worker/dist/index.js
