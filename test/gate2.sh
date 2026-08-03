#!/bin/bash
# gate2.sh — data-level functional assertions for langfuse 4.2.0 -> 4.3.0.
# Usage: gate2.sh <host> [before|after]
# Designed from the 4.2.0..4.3.0 diff. Each assertion is a DIFFERENTIAL: it is expected to give one
# answer on 4.2.0 and a different one on 4.3.0, so running it in both legs is the fail-lever.
set -uo pipefail
H="https://${1:?host required}"
LEG="${2:-after}"
PK=pk-lf-gate0000000000000000000000000000
SK=sk-lf-gate1111111111111111111111111111
AUTH=$(printf '%s:%s' "$PK" "$SK" | base64 -w0)
fails=0; ok(){ echo "PASS: $*"; }; bad(){ echo "FAIL: $*"; fails=$((fails+1)); }
note(){ echo "  ~ $*"; }

echo "=== gate2 leg=${LEG} host=${H} ==="

# --- A. version actually serving -------------------------------------------------------------
V=$(curl -s "$H/api/public/health" | jq -r '.version // empty' 2>/dev/null)
note "health reports version: ${V:-<none>}"

# --- B. data preservation: trace count (the thing an update must never change) ----------------
CNT=$(curl -s -H "Authorization: Basic $AUTH" "$H/api/public/traces?limit=1" | jq -r '.meta.totalItems // empty')
if [ -n "$CNT" ]; then ok "traces API reachable, totalItems=${CNT}"; else bad "traces API gave no totalItems"; fi
echo "TRACE_COUNT=${CNT}" > "/tmp/gate2-${LEG}.count"

# --- 1. signup route rejects non-POST with 405 (upstream fix #15670) --------------------------
# 4.2.0: `return;` with no response.  4.3.0: 405 + {"message":"Method not allowed"}
SC=$(curl -s -o /tmp/gate2-su.json -w '%{http_code}' -X GET "$H/api/auth/signup" --max-time 20)
MSG=$(jq -r '.message // empty' /tmp/gate2-su.json 2>/dev/null)
if [ "$LEG" = after ]; then
  { [ "$SC" = 405 ] && [ "$MSG" = "Method not allowed" ]; } \
    && ok "signup GET -> 405 'Method not allowed'" \
    || bad "signup GET -> status=${SC} message='${MSG}' (want 405 / Method not allowed)"
else
  note "baseline signup GET -> status=${SC} message='${MSG}' (4.2.0 expected NOT to be 405)"
  echo "BEFORE_SIGNUP_STATUS=${SC}" >> "/tmp/gate2-${LEG}.count"
fi

# --- 6. managed model price reseed ran (upstream chore) ------------------------------------
# PAGINATED. The first draft fetched page 1 of /api/public/models and concluded "absent" when the
# model was simply further down the list — an assertion that was inconclusive in BOTH legs and so
# tested nothing (recorded 2026-08-03). Walk pages until found or exhausted, and SAY which.
MODEL="${GATE2_PRICE_MODEL:-gpt-5.6-luna}"
found=""; page=1
while [ "$page" -le 20 ]; do
  PJ=$(curl -sf -H "Authorization: Basic $AUTH" "$H/api/public/models?limit=100&page=${page}" 2>/dev/null) || break
  n=$(echo "$PJ" | jq '.data | length' 2>/dev/null); [ "${n:-0}" -eq 0 ] && break
  hit=$(echo "$PJ" | jq -c --arg m "$MODEL" '[.data[]|select(.modelName==$m)][0] // empty' 2>/dev/null)
  [ -n "$hit" ] && { found="$hit"; break; }
  page=$((page+1))
done
if [ -z "$found" ]; then
  note "${MODEL} not present in ${page} page(s) of /api/public/models — assertion NOT RUN (not a pass)"
else
  IN=$(echo "$found" | jq -r '.prices.input.price // empty')
  OUT=$(echo "$found" | jq -r '.prices.output.price // empty')
  note "${MODEL} prices: input=${IN} output=${OUT} (page ${page})"
  echo "LUNA_IN=${IN} LUNA_OUT=${OUT}" >> "/tmp/gate2-${LEG}.count"
  if [ "$LEG" = after ] && [ -n "$IN" ]; then
    python3 - "$IN" "$OUT" <<'PYX' && ok "${MODEL} reseeded to the expected cut prices" || bad "${MODEL} prices are not the expected values (seed may not have re-run)"
import sys
i,o=float(sys.argv[1]),float(sys.argv[2])
sys.exit(0 if abs(i-2e-7)<1e-12 and abs(o-1.2e-6)<1e-12 else 1)
PYX
  fi
fi

# --- 7. containment: the new v2-only dimension must NOT appear on the v1 metrics API ----------
Q='{"view":"observations","metrics":[{"measure":"count","aggregation":"count"}],"dimensions":[{"field":"isRootObservation"}],"fromTimestamp":"2020-01-01T00:00:00Z","toTimestamp":"2030-01-01T00:00:00Z"}'
QE=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' "$Q")
S1=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Basic $AUTH" "$H/api/public/metrics?query=$QE" --max-time 30)
# fail-lever: the same request with a KNOWN-GOOD dimension must succeed, proving the 400 is
# specific to the new field and not just a broken endpoint.
Q2=${Q//isRootObservation/name}
QE2=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' "$Q2")
S2=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Basic $AUTH" "$H/api/public/metrics?query=$QE2" --max-time 30)
if [ "$S1" = 400 ] && [ "$S2" = 200 ]; then
  ok "v1 metrics rejects isRootObservation (400) but accepts name (200) — containment holds"
else
  bad "v1 metrics containment: isRootObservation=${S1} (want 400), name=${S2} (want 200)"
fi

echo "=== gate2 leg=${LEG} result: ${fails} failure(s) ==="
exit $fails
