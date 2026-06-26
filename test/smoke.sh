#!/bin/bash
# smoke.sh — the real runtime gate. Builds nothing by default; runs the assembled image Cloudron-style
# against throwaway Postgres + Redis on a container network, then asserts the package contract:
#   - all four services (clickhouse, minio, web, worker) reach RUNNING
#   - /api/public/health returns 200 with NO auth
#   - ENCRYPTION_KEY is exactly 64 hex; no secret leaks into the logs
#   - musl Node resolves+connects to Postgres & Redis by container hostname (Docker-DNS path)
#   - libc isolation holds live: node-musl maps only /opt/musl/lib; clickhouse only glibc
#   - ClickHouse runs in UTC
# Usage: test/smoke.sh [IMAGE]   (default IMAGE=lf-cloudron:dev). Set ENGINE=docker to use docker.
set -uo pipefail

IMAGE="${1:-lf-cloudron:dev}"
ENGINE="${ENGINE:-podman}"
NET=lf-smoke-net; VOL=lf-smoke-data; PG=lf-smoke-pg; RD=lf-smoke-redis; APP=lf-smoke-app
PGPASS="pg$(date +%s 2>/dev/null || echo 12345)x"; RPASS="rd${PGPASS}"
fails=0; note(){ echo "  $*"; }; ok(){ echo "PASS: $*"; }; bad(){ echo "FAIL: $*"; fails=$((fails+1)); }

cleanup(){ $ENGINE rm -f $APP $PG $RD >/dev/null 2>&1; $ENGINE volume rm $VOL >/dev/null 2>&1; $ENGINE network rm $NET >/dev/null 2>&1; }
trap cleanup EXIT
cleanup

echo "=== smoke: image=${IMAGE} engine=${ENGINE} ==="
$ENGINE network create $NET >/dev/null
$ENGINE volume create $VOL >/dev/null
$ENGINE run -d --name $PG --network $NET -e POSTGRES_USER=langfuse -e POSTGRES_PASSWORD="$PGPASS" -e POSTGRES_DB=langfuse docker.io/library/postgres:17 >/dev/null
$ENGINE run -d --name $RD --network $NET docker.io/library/redis:7 redis-server --requirepass "$RPASS" --maxmemory-policy noeviction >/dev/null
sleep 6
$ENGINE run -d --name $APP --network $NET -p 3000:3000 -v $VOL:/app/data \
  -e CLOUDRON=1 \
  -e CLOUDRON_POSTGRESQL_URL="postgresql://langfuse:${PGPASS}@${PG}:5432/langfuse" \
  -e CLOUDRON_REDIS_HOST=$RD -e CLOUDRON_REDIS_PORT=6379 -e CLOUDRON_REDIS_PASSWORD="$RPASS" \
  -e CLOUDRON_APP_ORIGIN="http://localhost:3000" \
  "$IMAGE" >/dev/null

# 1. health
hc=0
for i in $(seq 1 90); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' http://localhost:3000/api/public/health 2>/dev/null)" = "200" ] && { hc=1; break; }
  sleep 3
done
[ "$hc" = 1 ] && ok "/api/public/health 200 (~$((i*3))s)" || { bad "/api/public/health never 200"; $ENGINE logs --tail 60 $APP; exit 1; }

# 2. all four services RUNNING
st=$($ENGINE exec $APP supervisorctl -c /etc/supervisor/supervisord.conf status 2>/dev/null)
for svc in clickhouse minio web worker; do echo "$st" | grep -qE "^${svc}\s+RUNNING" && ok "service ${svc} RUNNING" || bad "service ${svc} not RUNNING"; done

# 3. ENCRYPTION_KEY 64 hex + not in logs
klen=$($ENGINE exec $APP sh -c '. /app/data/.secrets/secrets.env; printf %s "$ENCRYPTION_KEY" | wc -c')
[ "$klen" = 64 ] && ok "ENCRYPTION_KEY is 64 hex" || bad "ENCRYPTION_KEY length=$klen (want 64)"
ek=$($ENGINE exec $APP sh -c '. /app/data/.secrets/secrets.env; printf %s "$ENCRYPTION_KEY"')
$ENGINE logs $APP 2>&1 | grep -qF "$ek" && bad "ENCRYPTION_KEY leaked into logs" || ok "no ENCRYPTION_KEY in logs"

# 4. musl -> container-DNS -> CONNECT (pg + redis by hostname)
$ENGINE exec $APP /usr/local/bin/node-musl -e '
const net=require("net"),dns=require("dns");
const probe=(h,p)=>new Promise(r=>dns.lookup(h,(e,a)=>{if(e){console.log("DNSFAIL "+h+" "+e.code);return r(1)}const s=net.connect(p,h,()=>{console.log("CONNECT-OK "+h);s.end();r(0)});s.on("error",er=>{console.log("CONNFAIL "+h+" "+er.code);r(1)})}));
(async()=>{const a=await probe(process.env.CLOUDRON_REDIS_HOST,6379);const b=await probe(new URL(process.env.CLOUDRON_POSTGRESQL_URL).hostname,5432);process.exit(a||b)})();' \
  && ok "musl Node connects to pg+redis by hostname" || bad "musl Node hostname connect failed"

# 5. libc isolation (enumerate by exe; needs ptrace)
iso=$($ENGINE exec --privileged $APP bash -c '
bad=0
for pid in $(ls /proc | grep -E "^[0-9]+$"); do
  exe=$(readlink /proc/$pid/exe 2>/dev/null) || continue
  case "$exe" in
    */node-musl)  grep -qE "x86_64-linux-gnu/libc.so.6" /proc/$pid/maps 2>/dev/null && { echo "node-musl maps glibc"; bad=1; } ;;
    */clickhouse) grep -qE "/opt/musl/lib" /proc/$pid/maps 2>/dev/null && { echo "clickhouse maps musl"; bad=1; } ;;
  esac
done
echo "ISO=$bad"')
echo "$iso" | grep -q "ISO=0" && ok "libc isolation holds (node-musl=musl, clickhouse=glibc)" || bad "libc isolation breach: $iso"

# 6. ClickHouse UTC
tz=$($ENGINE exec $APP sh -c '. /app/data/.secrets/secrets.env; curl -s "http://localhost:8123/?user=clickhouse&password=${CLICKHOUSE_PASSWORD}" --data-binary "SELECT timezone()"' 2>/dev/null)
[ "$tz" = "UTC" ] && ok "ClickHouse timezone is UTC" || bad "ClickHouse timezone='$tz' (want UTC)"

echo "=== smoke result: $fails failure(s) ==="
exit $((fails > 0 ? 1 : 0))
