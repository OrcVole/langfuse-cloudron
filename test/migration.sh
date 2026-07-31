#!/bin/bash
# migration.sh — offline tests for conf/migrate-stores.sh (ADR 0008), the most dangerous code in this
# package: it relocates a live install's ClickHouse history and it only ever runs once, for real, on
# data that cannot be re-created.
#
# These run entirely in a local container against fabricated stores. They do NOT replace the box gate,
# which is the only thing that proves the real store, the real sizes and the real interruption behave;
# they exist so that the logic is already known-good before anything touches an install with history.
#
#   ./test/migration.sh [image]      default image: lf-cloudron:0.2.0-dev
set -uo pipefail
IMAGE="${1:-lf-cloudron:0.2.0-dev}"
ENGINE="${ENGINE:-podman}"
WORK="$(mktemp -d)"
PASS=0; FAIL=0
# The scripts under test chown to cloudron, which under rootless podman lands on a subuid the calling
# user cannot unlink. Tear down inside the user namespace, falling back to a plain rm when rootful.
cleanup_work() { "${ENGINE}" unshare rm -rf "${WORK}" 2>/dev/null || rm -rf "${WORK}" 2>/dev/null; }
trap cleanup_work EXIT

ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; PASS=$(( PASS + 1 )); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=$(( FAIL + 1 )); }
case_() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# Build a fabricated v0.1.0-shaped ClickHouse store. The sentinel subdir matters: migrate-stores.sh
# deliberately keys off store/ or metadata/ rather than the directory merely existing.
make_legacy() {                 # $1 = data dir, $2 = number of filler files
  mkdir -p "$1/clickhouse/store/778/aaaa" "$1/clickhouse/metadata" "$1/clickhouse/tmp" "$1/minio/langfuse"
  local i=0
  while [ "${i}" -lt "${2:-20}" ]; do
    head -c 4096 /dev/urandom > "$1/clickhouse/store/778/aaaa/part-${i}.bin"
    i=$(( i + 1 ))
  done
  echo "legacy-marker" > "$1/clickhouse/metadata/default.sql"
  # transients that must NOT be carried across
  mkdir -p "$1/clickhouse/store/778/aaaa/tmp_merge_202607_1_2_3"
  echo x > "$1/clickhouse/store/778/aaaa/tmp_merge_202607_1_2_3/junk"
  echo lock > "$1/clickhouse/status"
  # .minio.sys is what a real MinIO store always carries, and it is the sentinel the migration keys
  # off. Omitting it made an earlier version of this fixture unrealistically easy to satisfy.
  mkdir -p "$1/minio/.minio.sys/buckets" "$1/minio/.minio.sys/tmp"
  echo '{"version":"1"}' > "$1/minio/.minio.sys/format.json"
  echo "blob" > "$1/minio/langfuse/object.bin"
}

run_migrate() {                 # $1 = data dir, $2 = persistent root; echoes combined output
  "${ENGINE}" run --rm --user root \
    -v "$1:/app/data:Z" \
    -v "$2/clickhouse:/var/lib/clickhouse:Z" \
    -v "$2/minio:/var/lib/minio:Z" \
    "${IMAGE}" /app/code/conf/migrate-stores.sh 2>&1
}

new_case() {                    # $1 = case name -> sets DATA and PERS
  DATA="${WORK}/$1/data"; PERS="${WORK}/$1/persistent"
  mkdir -p "${DATA}" "${PERS}/clickhouse" "${PERS}/minio"
}

# =================================================================================================
case_ "1. Clean migration of a populated v0.1.0 store"
new_case clean
make_legacy "${DATA}" 25
OUT="$(run_migrate "${DATA}" "${PERS}")"
[ -f "${PERS}/clickhouse/metadata/default.sql" ] && ok "ClickHouse metadata copied" || bad "ClickHouse metadata missing"
[ "$(ls "${PERS}"/clickhouse/store/778/aaaa/part-*.bin 2>/dev/null | wc -l)" -eq 25 ] \
  && ok "all 25 parts copied" || bad "part count wrong"
[ -f "${PERS}/clickhouse/.migration-verified" ] && ok ".migration-verified written" || bad ".migration-verified missing"
[ -f "${PERS}/clickhouse/.migration-cleanup-pending" ] && ok "cleanup marker written" || bad "cleanup marker missing"
[ ! -f "${PERS}/clickhouse/.migration-in-progress" ] && ok "in-progress marker cleared" || bad "in-progress marker left behind"
[ ! -d "${PERS}/clickhouse/store/778/aaaa/tmp_merge_202607_1_2_3" ] && ok "tmp_merge_* excluded" || bad "tmp_merge_* was copied"
[ ! -f "${PERS}/clickhouse/status" ] && ok "status lock excluded" || bad "status lock was copied"
[ -d "${DATA}/clickhouse" ] && ok "legacy tree kept until the health gate" || bad "legacy tree deleted too early"
[ -f "${PERS}/minio/langfuse/object.bin" ] && ok "MinIO object copied" || bad "MinIO object missing"

case_ "2. Re-running after success is a no-op (idempotence)"
BEFORE="$(find "${PERS}/clickhouse" -type f | sort | md5sum)"
OUT="$(run_migrate "${DATA}" "${PERS}")"
AFTER="$(find "${PERS}/clickhouse" -type f | sort | md5sum)"
[ "${BEFORE}" = "${AFTER}" ] && ok "second run changed nothing" || bad "second run altered the store"
printf '%s' "${OUT}" | grep -q "cleanup deferred" && ok "reports cleanup still deferred" || bad "did not report deferred cleanup"

case_ "3. Interrupted migration resumes rather than restarting or booting partial"
new_case resume
make_legacy "${DATA}" 25
# Fabricate exactly what a killed copy leaves: the marker, plus a partial destination.
mkdir -p "${PERS}/clickhouse/store/778/aaaa"
cp "${DATA}/clickhouse/store/778/aaaa/part-0.bin" "${PERS}/clickhouse/store/778/aaaa/"
printf 'source=/app/data/clickhouse\nstarted=2026-07-31T00:00:00Z\nsource_bytes=1\n' \
  > "${PERS}/clickhouse/.migration-in-progress"
OUT="$(run_migrate "${DATA}" "${PERS}")"
printf '%s' "${OUT}" | grep -q "RESUMING" && ok "recognised the interruption and resumed" || bad "did not resume"
[ "$(ls "${PERS}"/clickhouse/store/778/aaaa/part-*.bin 2>/dev/null | wc -l)" -eq 25 ] \
  && ok "resumed copy is complete" || bad "resumed copy is incomplete"
[ -f "${PERS}/clickhouse/.migration-verified" ] && ok "verified after resume" || bad "not verified after resume"

case_ "4. A populated destination with legacy data present is read as a restored legacy backup"
new_case legacyrestore
make_legacy "${DATA}" 5
mkdir -p "${PERS}/clickhouse/store/999" "${PERS}/clickhouse/metadata"
echo "stale-live-data" > "${PERS}/clickhouse/store/999/old.bin"
echo "stale" > "${PERS}/clickhouse/metadata/default.sql"
OUT="$(run_migrate "${DATA}" "${PERS}")"
printf '%s' "${OUT}" | grep -q "DISCARDING" && ok "announced the discard loudly" || bad "discard not announced"
[ ! -d "${PERS}/clickhouse/store/999" ] && ok "stale destination content removed" || bad "stale content survived"
grep -q "legacy-marker" "${PERS}/clickhouse/metadata/default.sql" 2>/dev/null \
  && ok "restored legacy data is what is now in place" || bad "legacy data did not win"

case_ "5. An EMPTY legacy directory must never trigger a migration (the footgun)"
# If anything ever recreates /app/data/clickhouse empty after a completed migration, keying off the
# directory's existence rather than its content would discard the live store. It must not.
new_case emptylegacy
mkdir -p "${DATA}/clickhouse" "${DATA}/minio"
mkdir -p "${PERS}/clickhouse/store/live" "${PERS}/clickhouse/metadata"
echo "live-and-precious" > "${PERS}/clickhouse/store/live/data.bin"
OUT="$(run_migrate "${DATA}" "${PERS}")"
grep -q "live-and-precious" "${PERS}/clickhouse/store/live/data.bin" 2>/dev/null \
  && ok "live store untouched by an empty legacy directory" || bad "LIVE STORE DESTROYED by an empty legacy dir"
printf '%s' "${OUT}" | grep -q "DISCARDING" && bad "wrongly treated an empty dir as a restored backup" \
  || ok "did not treat an empty dir as a restored backup"

case_ "6. Destination pre-created by start.sh must NOT read as a restored legacy backup"
# The regression that 20 green assertions missed: start.sh used to create the persistentDir subdirs
# before leg 0, so "destination is empty" was never true and the DISCARD branch fired on every
# ordinary update. These cases pin the destination in the state a boot can actually leave it in.
new_case precreated
make_legacy "${DATA}" 8
mkdir -p "${PERS}/clickhouse"/{logs,tmp,access,user_files,format_schemas} "${PERS}/minio/langfuse"
OUT="$(run_migrate "${DATA}" "${PERS}")"
printf '%s' "${OUT}" | grep -q "DISCARDING" && bad "pre-created layout was misread as a restored backup" \
  || ok "pre-created empty layout is not mistaken for data"
[ "$(ls "${PERS}"/clickhouse/store/778/aaaa/part-*.bin 2>/dev/null | wc -l)" -eq 8 ] \
  && ok "migration still ran and copied everything" || bad "migration did not complete"
[ -f "${PERS}/minio/langfuse/object.bin" ] && ok "MinIO migrated despite the pre-created bucket dir" \
  || bad "MinIO did not migrate"

case_ "7. An EMPTY sentinel directory must not count as data"
# `rm -rf` unlinks the top directory last, so a killed cleanup leaves a bare store/ skeleton. If that
# counts as a legacy store, it discards the live persistentDir and the loss is total and silent.
new_case skeleton
mkdir -p "${DATA}/clickhouse/store" "${DATA}/minio"
mkdir -p "${PERS}/clickhouse/store/live" "${PERS}/clickhouse/metadata"
echo "live-and-precious" > "${PERS}/clickhouse/store/live/data.bin"
OUT="$(run_migrate "${DATA}" "${PERS}")"
grep -q "live-and-precious" "${PERS}/clickhouse/store/live/data.bin" 2>/dev/null \
  && ok "live store survives an empty store/ skeleton" || bad "LIVE STORE DESTROYED by an empty store/ skeleton"
printf '%s' "${OUT}" | grep -q "DISCARDING" && bad "empty skeleton treated as a restored backup" \
  || ok "empty skeleton correctly ignored"

case_ "8. Fresh install with no legacy data does nothing"
new_case fresh
OUT="$(run_migrate "${DATA}" "${PERS}")"
[ -z "$(ls -A "${PERS}/clickhouse" 2>/dev/null)" ] && ok "persistentDir left empty" || bad "wrote something on a fresh install"

# =================================================================================================
printf '\n\033[1m%d passed, %d failed\033[0m\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ] || exit 1
