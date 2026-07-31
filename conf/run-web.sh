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
export NODE_OPTIONS="${NODE_OPTIONS:---max-old-space-size=768}"

wait_for "clickhouse" curl -sf http://localhost:8123/ping
wait_for "minio"      curl -sf http://localhost:9100/minio/health/live
wait_for "postgres"   pg_isready -d "${DATABASE_URL}"
REDISCLI_AUTH="${REDIS_AUTH}" wait_for "redis" redis-cli -h "${REDIS_HOST}" -p "${REDIS_PORT}" ping

# The 'langfuse' bucket is pre-created by start.sh (mkdir under the MinIO data dir — the upstream pattern).

# Migrations run ONCE here (the worker waits on the flag). node-musl => the forced musl query engine loads.
PRISMA="/app/code/prisma-cli/build/index.js"
log "postgres: cleanup + migrate deploy"
/usr/local/bin/node-musl "${PRISMA}" db execute --url "${DIRECT_URL}" --file ./packages/shared/scripts/cleanup.sql || true
/usr/local/bin/node-musl "${PRISMA}" migrate deploy --schema=./packages/shared/prisma/schema.prisma
log "clickhouse: migrate up"
( cd ./packages/shared && bash ./clickhouse/scripts/up.sh )   # bash, NOT sh: up.sh uses bashisms (&>)

touch /run/langfuse/migrated
log "migrations complete — starting web on 0.0.0.0:${PORT}"
exec /usr/local/bin/node-musl ./web/server.js --keepAliveTimeout 110000
