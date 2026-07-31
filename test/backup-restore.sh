#!/bin/bash
# backup-restore.sh — offline backup and CLONE round trip for v0.2.0 (ADR 0006 / 0009).
#
# WHY THIS EXISTS. The only operation that leaves a persistentDir EMPTY is a clone. An update preserves
# it and an in-place restore preserves it, so a gate that only tests backup plus in-place restore passes
# while the rebuild path is broken -- and the rebuild path is the one an operator reaches for after
# losing data. This reproduces the clone locally.
#
# It also reproduces the condition that makes the design necessary: backupCommand runs in a SEPARATE
# container WHILE THE APP IS STILL LIVE, so the running server holds its flock on <store>/status
# throughout. A backup taken against a stopped app would mask exactly the failure this design exists to
# avoid.
#
#   ./test/backup-restore.sh [image]      default image: lf-cloudron:0.2.0-dev
set -uo pipefail
IMAGE="${1:-lf-cloudron:0.2.0-dev}"; ENGINE="${ENGINE:-podman}"
NET=lf-br-net; PG=lf-br-pg; RD=lf-br-redis
APP=lf-br-app; CLONE=lf-br-clone
VOL=lf-br-data; CHVOL=lf-br-ch; MVOL=lf-br-minio
CHVOL2=lf-br-ch2; MVOL2=lf-br-minio2
PGPASS="br$(date +%s)"; RPASS="rd${PGPASS}"
PK=pk-lf-1111111111111111111111111111111111; SK=sk-lf-2222222222222222222222222222222222
fails=0; ok(){ printf '  \033[32mPASS\033[0m  %s\n' "$*"; }; bad(){ printf '  \033[31mFAIL\033[0m  %s\n' "$*"; fails=$((fails+1)); }
case_(){ printf '\n\033[1m%s\033[0m\n' "$*"; }

cleanup(){
  $ENGINE rm -f $APP $CLONE $PG $RD >/dev/null 2>&1
  $ENGINE volume rm $VOL $CHVOL $MVOL $CHVOL2 $MVOL2 >/dev/null 2>&1
  $ENGINE network rm $NET >/dev/null 2>&1
}
trap cleanup EXIT; cleanup

start_app(){                       # $1 = container name, $2 = ch volume, $3 = minio volume, $4 = host port
  $ENGINE run -d --name "$1" --network $NET -p "$4":3000 \
    -v $VOL:/app/data -v "$2":/var/lib/clickhouse -v "$3":/var/lib/minio \
    -e CLOUDRON=1 -e CLOUDRON_POSTGRESQL_URL="postgresql://langfuse:${PGPASS}@${PG}:5432/langfuse" \
    -e CLOUDRON_REDIS_HOST=$RD -e CLOUDRON_REDIS_PORT=6379 -e CLOUDRON_REDIS_PASSWORD="$RPASS" \
    -e CLOUDRON_APP_ORIGIN="http://localhost:$4" \
    -e LANGFUSE_INIT_ORG_ID=testorg -e LANGFUSE_INIT_ORG_NAME=TestOrg \
    -e LANGFUSE_INIT_PROJECT_ID=testproj -e LANGFUSE_INIT_PROJECT_NAME=TestProj \
    -e LANGFUSE_INIT_PROJECT_PUBLIC_KEY=$PK -e LANGFUSE_INIT_PROJECT_SECRET_KEY=$SK \
    -e LANGFUSE_INIT_USER_EMAIL=test@example.com -e LANGFUSE_INIT_USER_PASSWORD='Test12345!' -e LANGFUSE_INIT_USER_NAME=Tester \
    -e LANGFUSE_INGESTION_QUEUE_DELAY_MS=0 -e LANGFUSE_INGESTION_CLICKHOUSE_WRITE_INTERVAL_MS=1000 \
    "$IMAGE" >/dev/null
}
wait_health(){                     # $1 = host port, $2 = seconds
  local i; for i in $(seq 1 "$2"); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$1/api/public/health")" = 200 ] && return 0
    sleep 3
  done; return 1
}

$ENGINE network create $NET >/dev/null
for v in $VOL $CHVOL $MVOL $CHVOL2 $MVOL2; do $ENGINE volume create $v >/dev/null; done
$ENGINE run -d --name $PG --network $NET -e POSTGRES_USER=langfuse -e POSTGRES_PASSWORD="$PGPASS" -e POSTGRES_DB=langfuse docker.io/library/postgres:17 >/dev/null
$ENGINE run -d --name $RD --network $NET docker.io/library/redis:7 redis-server --requirepass "$RPASS" --maxmemory-policy noeviction >/dev/null
sleep 6

case_ "1. Original install ingests data"
start_app $APP $CHVOL $MVOL 3000
wait_health 3000 90 && ok "app healthy" || { bad "app never became healthy"; $ENGINE logs $APP 2>&1 | tail -30; exit 1; }
AUTH=$(printf '%s:%s' "$PK" "$SK" | base64 -w0)
TID="trace-clone-$(date +%s)"
for n in 1 2 3 4 5; do
  curl -s -o /dev/null -X POST http://localhost:3000/api/public/ingestion \
    -H "Authorization: Basic $AUTH" -H "Content-Type: application/json" \
    -d "{\"batch\":[{\"id\":\"ev-$n\",\"type\":\"trace-create\",\"timestamp\":\"2026-06-26T12:00:0$n.000Z\",\"body\":{\"id\":\"$TID-$n\",\"name\":\"clone-trace\",\"userId\":\"u1\"}}]}"
done
seen=0
for i in $(seq 1 30); do
  curl -s -H "Authorization: Basic $AUTH" "http://localhost:3000/api/public/traces?limit=50" | grep -q "$TID-5" && { seen=1; break; }
  sleep 2
done
[ "$seen" = 1 ] && ok "5 traces ingested and readable" || bad "traces never became readable"
KEY_BEFORE=$($ENGINE exec $APP sh -c 'sha256sum /app/data/.secrets/secrets.env | cut -d" " -f1')

case_ "2. backupCommand runs in a separate container while the app is LIVE"
# This is the flock condition: the running server holds <store>/status throughout.
BOUT=$($ENGINE run --rm -v $VOL:/app/data -v $CHVOL:/var/lib/clickhouse -v $MVOL:/var/lib/minio \
        "$IMAGE" /app/code/conf/backup-clickhouse.sh 2>&1)
brc=$?
[ "$brc" = 0 ] && ok "backupCommand exited 0 against a live server" || { bad "backupCommand exited $brc"; printf '%s\n' "$BOUT" | tail -20; }
printf '%s' "$BOUT" | grep -qi "CANNOT_OPEN_FILE\|Code: 76" && bad "hit the flock (Code 76) — the snapshot step is not working" || ok "no flock collision"
$ENGINE run --rm -v $VOL:/app/data "$IMAGE" test -d /app/data/clickhouse-backup \
  && ok "ClickHouse dump present in /app/data" || bad "no ClickHouse dump written"
$ENGINE run --rm -v $VOL:/app/data "$IMAGE" test -d /app/data/minio-backup \
  && ok "MinIO copy present in /app/data" || bad "no MinIO copy written"
$ENGINE run --rm -v $VOL:/app/data "$IMAGE" sh -c 'test -s /app/data/.last-backup.log' \
  && ok "status written to .last-backup.log (stdout is discarded in the real temp container)" \
  || bad ".last-backup.log empty or missing"
$ENGINE run --rm -v $VOL:/app/data "$IMAGE" sh -c 'test -e /app/data/.clickhouse-snapshot' \
  && bad "transient snapshot was left behind and would be archived" || ok "transient snapshot cleaned up"

case_ "3. Clone: EMPTY persistentDirs plus the restored /app/data must rebuild"
$ENGINE rm -f $APP >/dev/null 2>&1
start_app $CLONE $CHVOL2 $MVOL2 3001          # note: fresh, EMPTY store volumes
if wait_health 3001 120; then ok "clone became healthy"; else bad "clone never became healthy"; $ENGINE logs $CLONE 2>&1 | tail -40; fi
CLONELOG=$(mktemp); $ENGINE logs $CLONE > "$CLONELOG" 2>&1
grep -q "transient clickhouse-server" "$CLONELOG" \
  && ok "rebuilt through a transient clickhouse-server (not clickhouse local)" \
  || { bad "no transient-server rebuild in the log"; echo "    --- boot legs as logged ---"; grep -aE "\[restore\]|\[migrate\]|\[start\]" "$CLONELOG" | head -20 | sed 's/^/    /'; }
grep -q "RESTORE ok" "$CLONELOG" && ok "RESTORE reported success" || bad "no RESTORE success line"
grep -q "restoring MinIO" "$CLONELOG" && ok "MinIO was restored on the clone path" \
  || bad "MinIO restore did NOT run on the clone (the defect the review found)"
rm -f "$CLONELOG"

# Verify through the app's own read path, which goes through the restored VIEWS. A bare SELECT count()
# on a base table would pass even when allow_different_table_def has re-normalised a view's dictionary
# reference and the aggregates are wrong.
got=$(curl -s -H "Authorization: Basic $AUTH" "http://localhost:3001/api/public/traces?limit=50")
printf '%s' "$got" | grep -q "$TID-5" && ok "trace 5 readable from the clone via /api/public/traces" || bad "trace 5 missing from the clone"
n=$(printf '%s' "$got" | grep -o "$TID-" | wc -l)
[ "${n:-0}" -ge 5 ] && ok "all 5 traces present in the clone ($n)" || bad "only $n of 5 traces in the clone"

KEY_AFTER=$($ENGINE exec $CLONE sh -c 'sha256sum /app/data/.secrets/secrets.env | cut -d" " -f1')
[ "$KEY_BEFORE" = "$KEY_AFTER" ] && ok "secrets (ENCRYPTION_KEY) byte-identical across the round trip" \
  || bad "SECRETS CHANGED across the round trip — encrypted rows would be orphaned"

$ENGINE exec $CLONE sh -c 'ls -A /app/data/clickhouse /app/data/minio 2>/dev/null | wc -l' | grep -q '^0$' \
  && ok "clone keeps nothing churning inside /app/data" || bad "clone left a store inside the backed-up tree"

printf '\n\033[1m%d failure(s)\033[0m\n' "$fails"
exit $(( fails > 0 ? 1 : 0 ))
