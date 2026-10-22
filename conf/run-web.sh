#!/bin/bash
# run-web.sh — supervised web process. Waits for every dependency to be ready, runs the Postgres +
# ClickHouse migrations ONCE, ensures the MinIO bucket, then exec's the Next.js standalone server.
set -euo pipefail
log() { echo "==> [web] $*"; }

wait_for() { # <name> <cmd...>
  local name="$1"; shift; local i=0
  until "$@" >/dev/null 2>&1; do
    i=$((i + 1)); [ $((i % 10)) -eq 1 ] && log "waiting for ${name} ..."
    [ "$i" -ge 150 ] && { log "FATAL: ${name} not ready after 300s"; exit 1; }
    sleep 2
  done
  log "${name} ready"
}

cd /app/code/web
# Next.js standalone binds $HOSTNAME; Docker/Cloudron set it to the container id (gotcha 4) -> force 0.0.0.0.
export HOSTNAME="0.0.0.0"
export PORT="3000"
# v0.3.0: 768 MB was enough for every v3 web but langfuse v4's web OOMs AT BOOT under it (FATAL
# "Ineffective mark-compacts near heap limit", SIGABRT crash-loop, caught by test/ingest.sh before
# it ever reached a box). 1536 MB boots and serves with headroom; memoryLimit moved 5 -> 6 GiB in
# the same change (ADR 0005's "re-measure if a future Langfuse changes the footprint" clause).
export NODE_OPTIONS="${NODE_OPTIONS:---max-old-space-size=1536}"

wait_for "clickhouse" curl -sf http://localhost:8123/ping
wait_for "minio"      curl -sf http://localhost:9100/minio/health/live
wait_for "postgres"   pg_isready -d "${DATABASE_URL}"
REDISCLI_AUTH="${REDIS_AUTH}" wait_for "redis" redis-cli -h "${REDIS_HOST}" -p "${REDIS_PORT}" ping

# The 'langfuse' bucket is pre-created by start.sh (mkdir under the MinIO data dir — the upstream pattern).

# Migrations run ONCE here (the worker waits on the flag). the forced rhel query engine loads.
PRISMA="/app/code/prisma-cli/build/index.js"
log "postgres: cleanup + migrate deploy"
/usr/local/bin/node "${PRISMA}" db execute --url "${DIRECT_URL}" --file ./packages/shared/scripts/cleanup.sql || true
/usr/local/bin/node "${PRISMA}" migrate deploy --schema=./packages/shared/prisma/schema.prisma
log "clickhouse: migrate up"
( cd ./packages/shared && bash ./clickhouse/scripts/up.sh )   # bash, NOT sh: up.sh uses bashisms (&>)

# Raw-event retention (ADR 0013), re-applied on every boot so a changed LANGFUSE_EVENT_RETENTION_DAYS
# takes effect on restart. Never fatal: retention is housekeeping, and a failure here must not keep
# the web process down. The bucket's lifecycle is ours alone, so it is replaced whole (import), which
# makes the step idempotent without parsing the rules already there.
apply_event_retention() {
  local days="${LANGFUSE_EVENT_RETENTION_DAYS:-30}"
  if ! [[ "${days}" =~ ^[0-9]+$ ]]; then
    log "WARNING: LANGFUSE_EVENT_RETENTION_DAYS='${days}' is not a whole number; retention left unchanged"
    return 0
  fi
  local mc=(mc --config-dir /run/langfuse/mc --quiet)   # the rootfs is read-only; mc writes a config dir
  export MC_HOST_local="http://${MINIO_ROOT_USER}:${MINIO_ROOT_PASSWORD}@localhost:9100"
  local ch=(clickhouse-client --user clickhouse --password "${CLICKHOUSE_PASSWORD}")
  local current
  current="$("${ch[@]}" --query "SELECT engine_full FROM system.tables WHERE database = 'default' AND name = 'blob_storage_file_log'" 2>/dev/null || true)"
  if [ "${days}" -eq 0 ]; then
    "${mc[@]}" ilm rule rm --all --force local/langfuse >/dev/null 2>&1 || true
    if [[ "${current}" == *" TTL "* ]]; then
      "${ch[@]}" --query "ALTER TABLE default.blob_storage_file_log REMOVE TTL" || log "WARNING: could not remove the blob_storage_file_log TTL"
    fi
    log "event retention: off (events kept forever)"
    return 0
  fi
  printf '{"Rules":[{"ID":"langfuse-events-expiry","Status":"Enabled","Filter":{"Prefix":"events/"},"Expiration":{"Days":%d}}]}\n' "${days}" \
    | "${mc[@]}" ilm rule import local/langfuse >/dev/null \
    || { log "WARNING: could not set the MinIO expiry rule on events/"; }
  # MODIFY TTL rewrites the table's parts, so only issue it when the TTL actually differs.
  if [[ -z "${current}" ]]; then
    log "WARNING: blob_storage_file_log not found; its TTL is not set"
  elif [[ "${current}" != *"TTL created_at + toIntervalDay(${days})"* ]]; then
    "${ch[@]}" --query "ALTER TABLE default.blob_storage_file_log MODIFY TTL created_at + INTERVAL ${days} DAY DELETE" \
      || log "WARNING: could not set the blob_storage_file_log TTL"
  fi
  log "event retention: ${days} days (MinIO events/ expiry + blob_storage_file_log TTL)"
}
apply_event_retention

touch /run/langfuse/migrated
log "migrations complete — starting web on 0.0.0.0:${PORT}"
exec /usr/local/bin/node ./web/server.js --keepAliveTimeout 110000
