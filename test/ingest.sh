#!/bin/bash
# ingest.sh — end-to-end pipeline gate. Auto-provisions a project (LANGFUSE_INIT_* — TEST ONLY; the
# shipped package never sets these), sends a trace via API-key auth, and proves the whole path:
#   web (ingest) -> Redis (BullMQ) -> worker -> ClickHouse + S3 event bucket -> read back via public API.
# Usage: test/ingest.sh [IMAGE]   (default lf-cloudron:dev). ENGINE=docker to use docker.
set -uo pipefail
IMAGE="${1:-lf-cloudron:dev}"; ENGINE="${ENGINE:-podman}"
NET=lf-ing-net; VOL=lf-ing-data; PG=lf-ing-pg; RD=lf-ing-redis; APP=lf-ing-app
PGPASS="ing$(date +%s 2>/dev/null||echo 1)"; RPASS="rd${PGPASS}"
PK=pk-lf-1111111111111111111111111111111111; SK=sk-lf-2222222222222222222222222222222222
fails=0; ok(){ echo "PASS: $*"; }; bad(){ echo "FAIL: $*"; fails=$((fails+1)); }
cleanup(){ $ENGINE rm -f $APP $PG $RD >/dev/null 2>&1; $ENGINE volume rm $VOL >/dev/null 2>&1; $ENGINE network rm $NET >/dev/null 2>&1; }
trap cleanup EXIT; cleanup
$ENGINE network create $NET >/dev/null; $ENGINE volume create $VOL >/dev/null
$ENGINE run -d --name $PG --network $NET -e POSTGRES_USER=langfuse -e POSTGRES_PASSWORD="$PGPASS" -e POSTGRES_DB=langfuse docker.io/library/postgres:17 >/dev/null
$ENGINE run -d --name $RD --network $NET docker.io/library/redis:7 redis-server --requirepass "$RPASS" --maxmemory-policy noeviction >/dev/null
sleep 6
$ENGINE run -d --name $APP --network $NET -p 3000:3000 -v $VOL:/app/data \
  -e CLOUDRON=1 -e CLOUDRON_POSTGRESQL_URL="postgresql://langfuse:${PGPASS}@${PG}:5432/langfuse" \
  -e CLOUDRON_REDIS_HOST=$RD -e CLOUDRON_REDIS_PORT=6379 -e CLOUDRON_REDIS_PASSWORD="$RPASS" \
  -e CLOUDRON_APP_ORIGIN="http://localhost:3000" \
  -e LANGFUSE_INIT_ORG_ID=testorg -e LANGFUSE_INIT_ORG_NAME=TestOrg \
  -e LANGFUSE_INIT_PROJECT_ID=testproj -e LANGFUSE_INIT_PROJECT_NAME=TestProj \
  -e LANGFUSE_INIT_PROJECT_PUBLIC_KEY=$PK -e LANGFUSE_INIT_PROJECT_SECRET_KEY=$SK \
  -e LANGFUSE_INIT_USER_EMAIL=test@example.com -e LANGFUSE_INIT_USER_PASSWORD='Test12345!' -e LANGFUSE_INIT_USER_NAME=Tester \
  -e LANGFUSE_INGESTION_QUEUE_DELAY_MS=0 -e LANGFUSE_INGESTION_CLICKHOUSE_WRITE_INTERVAL_MS=1000 \
  "$IMAGE" >/dev/null
for i in $(seq 1 90); do [ "$(curl -s -o /dev/null -w '%{http_code}' http://localhost:3000/api/public/health)" = 200 ] && break; sleep 3; done

AUTH=$(printf '%s:%s' "$PK" "$SK" | base64 -w0)
curl -s -H "Authorization: Basic $AUTH" http://localhost:3000/api/public/projects | grep -q testproj \
  && ok "API key authenticates; project provisioned" || bad "API-key auth / project init failed"

TID="trace-$(date +%s)-abc"
code=$(curl -s -o /tmp/lf-ing.json -w '%{http_code}' -X POST http://localhost:3000/api/public/ingestion \
  -H "Authorization: Basic $AUTH" -H "Content-Type: application/json" \
  -d "{\"batch\":[{\"id\":\"ev-1\",\"type\":\"trace-create\",\"timestamp\":\"2026-06-26T12:00:00.000Z\",\"body\":{\"id\":\"$TID\",\"name\":\"smoke-trace\",\"userId\":\"u1\"}}]}")
{ [ "$code" = 207 ] || [ "$code" = 200 ]; } && ok "ingestion accepted ($code)" || bad "ingestion rejected ($code): $(head -c 160 /tmp/lf-ing.json)"

seen=0
for i in $(seq 1 30); do
  curl -s -H "Authorization: Basic $AUTH" "http://localhost:3000/api/public/traces?limit=10" | grep -q "$TID" && { seen=1; break; }
  sleep 2
done
[ "$seen" = 1 ] && ok "trace read back via public API (web->redis->worker->ClickHouse)" || bad "trace not visible after 60s"

ch=$($ENGINE exec $APP sh -c '. /app/data/.secrets/secrets.env; curl -s "http://localhost:8123/?user=clickhouse&password=${CLICKHOUSE_PASSWORD}" --data-binary "SELECT count() FROM traces"' 2>/dev/null)
{ [ -n "$ch" ] && [ "$ch" -ge 1 ] 2>/dev/null; } && ok "ClickHouse has >=1 trace row ($ch)" || bad "ClickHouse trace count=$ch"
ev=$($ENGINE exec $APP sh -c 'find /app/data/minio/langfuse/events -type f 2>/dev/null | wc -l')
[ "${ev:-0}" -ge 1 ] && ok "event object written to bundled MinIO ($ev)" || bad "no event objects in MinIO"

echo "=== ingest result: $fails failure(s) ==="
exit $(( fails > 0 ? 1 : 0 ))
