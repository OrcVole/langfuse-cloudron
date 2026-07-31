#!/bin/bash
# start.sh — Langfuse Cloudron entrypoint. Runs as root for setup, then exec's supervisord which drops
# each of the four services (clickhouse, minio, web, worker) to the unprivileged cloudron user.
set -euo pipefail

CODE=/app/code
DATA=/app/data
VERSION="${LANGFUSE_VERSION:-unknown}"
log() { echo "==> [start] $*"; }
log "langfuse ${VERSION} booting"

# ------------------------------------------------------------------------------------------------
# 1. Layout + ownership. A restore can reset owner/mode across /app/data, so re-assert every boot.
#
#    v0.2.0 (ADR 0006): the ClickHouse and MinIO stores live on persistentDirs, OUT of the backed-up
#    rsync walk, so their create-then-rename churn can no longer abort the whole server's backup run.
#    NOTE the two things deliberately NOT done here, both of which would destroy data on this package:
#      * /app/data/{clickhouse,minio} are NOT created. Recreating them would look like a restored
#        pre-0.2.0 backup to the migration guard on the next boot.
#      * they are NOT rm -rf'd either. The sibling Laminar package does exactly that, safely, because
#        it was greenfield and never had data there. Langfuse shipped v0.1.0 with real history at those
#        paths, so they are migrated (ADR 0008) and only then deleted, once the app is proven healthy.
# ------------------------------------------------------------------------------------------------
CH_STORE=/var/lib/clickhouse
MINIO_STORE=/var/lib/minio
# "${MINIO_STORE}/langfuse" pre-creates the bucket exactly as v0.1.0 did at the old path.
mkdir -p "${DATA}/.secrets" /run/langfuse \
         "${CH_STORE}"/{logs,tmp,access,user_files,format_schemas} \
         "${MINIO_STORE}/langfuse"
chown -R cloudron:cloudron "${DATA}" /run/langfuse
# Re-assert persistentDir ownership, but only walk the whole store when the top level has actually
# drifted (a restoreCommand runs as root). Otherwise a multi-gigabyte chown -R on every single boot.
for _store in "${CH_STORE}" "${MINIO_STORE}"; do
  if [ "$(stat -c %U "${_store}" 2>/dev/null || echo x)" != cloudron ]; then
    chown -R cloudron:cloudron "${_store}"
  else
    chown cloudron:cloudron "${_store}"
  fi
done
chown cloudron:cloudron "${CH_STORE}"/{logs,tmp,access,user_files,format_schemas}
chmod 0700 "${DATA}/.secrets"

# ------------------------------------------------------------------------------------------------
# 2. Secrets: first-run-only + idempotent. ENCRYPTION_KEY is DATA-LOSS-CRITICAL — generate ONCE,
#    never reseed. Re-assert mode/owner every boot (restore drifts them). All hex => URL-safe.
# ------------------------------------------------------------------------------------------------
SECRETS="${DATA}/.secrets/secrets.env"
if [[ ! -f "${SECRETS}" ]]; then
  log "first run: generating secrets"
  ( umask 077
    {
      echo "NEXTAUTH_SECRET=$(openssl rand -hex 32)"
      echo "SALT=$(openssl rand -hex 32)"
      echo "ENCRYPTION_KEY=$(openssl rand -hex 32)"      # EXACTLY 64 hex chars
      echo "CLICKHOUSE_PASSWORD=$(openssl rand -hex 24)"
      echo "MINIO_ROOT_USER=lf$(openssl rand -hex 6)"
      echo "MINIO_ROOT_PASSWORD=$(openssl rand -hex 24)"
    } > "${SECRETS}" )
else
  log "existing secrets found (not reseeding)"
fi
chown cloudron:cloudron "${SECRETS}"; chmod 0600 "${SECRETS}"
set -a; . "${SECRETS}"; set +a

if [[ ! "${ENCRYPTION_KEY:-}" =~ ^[0-9a-f]{64}$ ]]; then
  log "FATAL: ENCRYPTION_KEY is not exactly 64 hex chars — refusing to start (data-loss guard)"; exit 1
fi

# ------------------------------------------------------------------------------------------------
# 2b. Store boot legs (ADR 0009). Runs before supervisord, so neither ClickHouse nor MinIO is up and
#     both stores are quiescent. Five states are possible and three of them look identical from in here:
#       leg 0  migration pending or resuming  -> migrate-stores.sh
#       leg 1  ordinary update                -> nothing to do
#       leg 2  in-place restore               -> indistinguishable from leg 1; logged, not acted on
#       leg 3  clone / cleared store          -> restore-clickhouse.sh rebuilds from the dump
#       leg 4  genuinely fresh install        -> nothing to do; the web wrapper's migrations build it
#
#     SIGNALS: this script is PID 1 here, and PID 1 gets no default signal dispositions, so a platform
#     stop during a multi-gigabyte migration would be ignored until SIGKILL. Forward TERM/INT to the
#     running child. Both long legs are resumable by construction, so this makes an ugly stop clean
#     rather than being load-bearing for correctness.
# ------------------------------------------------------------------------------------------------
_child=""
_forward() { [ -n "${_child}" ] && kill -TERM "${_child}" 2>/dev/null || true; }
trap _forward TERM INT

run_leg() {                                   # run "$@" as a child we can signal, and return its status
  local rc=0
  "$@" & _child=$!
  wait "${_child}" || rc=$?
  _child=""
  return "${rc}"
}

if ! run_leg "${CODE}/conf/migrate-stores.sh"; then
  log "FATAL: store migration did not complete — refusing to start on a partial store."
  log "Nothing has been deleted; the legacy data is still at ${DATA}/clickhouse. The next boot resumes."
  exit 1
fi

# Leg 3. No-ops unless a persistentDir is empty AND a dump is present, so it is safe on every boot.
# This is the leg that rebuilds a CLONE, which is the only operation that leaves a persistentDir empty:
# an update and an in-place restore both preserve it, so nothing else ever exercises this path.
if ! run_leg "${CODE}/conf/restore-clickhouse.sh"; then
  log "FATAL: rebuilding the stores from the backup copies failed — refusing to start."
  exit 1
fi

# Leg 2 cannot be detected, only recorded. An in-place restore PRESERVES persistentDirs, so an operator
# who restores to last Tuesday gets last Tuesday's Postgres and dump but TODAY's ClickHouse store. Log
# both timestamps so the divergence is at least in the record. The operator recipe for making an
# in-place restore actually restore ClickHouse is in POSTINSTALL.md and docs/KNOWN-ISSUES.md.
if [ -d "${DATA}/clickhouse-backup" ] && [ -d "${CH_STORE}/store" ]; then
  log "store check: dump on disk dated $(date -u -r "${DATA}/clickhouse-backup" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown), live ClickHouse store dated $(date -u -r "${CH_STORE}/store" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
  log "store check: if you have just done an IN-PLACE RESTORE, the store above is preserved, NOT restored — see KNOWN-ISSUES.md"
fi

trap - TERM INT

# ------------------------------------------------------------------------------------------------
# 3. Map CLOUDRON_* addon vars -> Langfuse env (every boot; addon values can change on restart).
# ------------------------------------------------------------------------------------------------
export HOME="${DATA}"
export DATABASE_URL="${CLOUDRON_POSTGRESQL_URL:?postgresql addon required}"
export DIRECT_URL="${DATABASE_URL}"
export REDIS_HOST="${CLOUDRON_REDIS_HOST:?redis addon required}"
export REDIS_PORT="${CLOUDRON_REDIS_PORT:-6379}"
export REDIS_AUTH="${CLOUDRON_REDIS_PASSWORD:-}"
export REDIS_TLS_ENABLED="false"
export NEXTAUTH_URL="${CLOUDRON_APP_ORIGIN:?app origin required}"

export CLICKHOUSE_URL="http://localhost:8123"
export CLICKHOUSE_MIGRATION_URL="clickhouse://localhost:9000"
export CLICKHOUSE_USER="clickhouse"
export CLICKHOUSE_CLUSTER_ENABLED="false"
# CLICKHOUSE_PASSWORD, MINIO_ROOT_USER/PASSWORD, NEXTAUTH_SECRET, SALT, ENCRYPTION_KEY: from secrets above.

export TELEMETRY_ENABLED="false"
export NEXT_TELEMETRY_DISABLED="1"

# S3 -> bundled MinIO. Event uploads are server-side (internal endpoint). Media external endpoint must be
# browser-reachable — resolved in ADR 0004 (Phase 2.6/3); for now points at the internal endpoint.
_s3_common() { # $1 = LANGFUSE_S3_<KIND>_UPLOAD
  export ${1}_BUCKET="langfuse"
  export ${1}_REGION="auto"
  export ${1}_ENDPOINT="http://localhost:9100"
  export ${1}_ACCESS_KEY_ID="${MINIO_ROOT_USER}"
  export ${1}_SECRET_ACCESS_KEY="${MINIO_ROOT_PASSWORD}"
  export ${1}_FORCE_PATH_STYLE="true"
}
_s3_common LANGFUSE_S3_EVENT_UPLOAD; export LANGFUSE_S3_EVENT_UPLOAD_PREFIX="events/"
_s3_common LANGFUSE_S3_MEDIA_UPLOAD; export LANGFUSE_S3_MEDIA_UPLOAD_PREFIX="media/"
# Media presigned URLs must be browser-reachable (ADR 0004). 3.199 has ONE media endpoint (presign +
# server-side), so point it at the public blob subdomain (httpPorts). Server-side ops hairpin via the
# proxy. Event uploads stay on the internal endpoint (server-side only).
if [[ -n "${LANGFUSE_BLOB_DOMAIN:-}" ]]; then
  export LANGFUSE_S3_MEDIA_UPLOAD_ENDPOINT="https://${LANGFUSE_BLOB_DOMAIN}"
  log "media S3 endpoint -> https://${LANGFUSE_BLOB_DOMAIN}"
else
  log "WARNING: LANGFUSE_BLOB_DOMAIN unset; media presigned URLs will not be browser-reachable"
fi

# OIDC SSO (Phase 3) — wire Langfuse custom OIDC to the Cloudron oidc addon, only when present.
if [[ -n "${CLOUDRON_OIDC_CLIENT_ID:-}" ]]; then
  export AUTH_CUSTOM_CLIENT_ID="${CLOUDRON_OIDC_CLIENT_ID}"
  export AUTH_CUSTOM_CLIENT_SECRET="${CLOUDRON_OIDC_CLIENT_SECRET}"
  export AUTH_CUSTOM_ISSUER="${CLOUDRON_OIDC_ISSUER}"
  export AUTH_CUSTOM_NAME="Cloudron"
  export AUTH_CUSTOM_SCOPE="openid email profile"
  export AUTH_CUSTOM_ALLOW_ACCOUNT_LINKING="true"
  log "OIDC SSO wired to the Cloudron oidc addon"
fi

# Make the generated/bundled-service secrets visible to the supervised children.
export CLICKHOUSE_PASSWORD MINIO_ROOT_USER MINIO_ROOT_PASSWORD NEXTAUTH_SECRET SALT ENCRYPTION_KEY

log "origin ${NEXTAUTH_URL}  encryption_key present  pg set  redis ${REDIS_HOST}:${REDIS_PORT}"

# ------------------------------------------------------------------------------------------------
# 4. Hand off to supervisor (clickhouse + minio start now; web/worker wrappers gate on readiness).
#
#    First, step 7 of the ADR 0008 migration: delete the legacy /app/data stores, but only once THIS
#    boot has shown the app actually serves traffic on the migrated data. It runs in the background
#    because the health check cannot pass until supervisord is up, and it exits immediately when there
#    is nothing pending, so it costs nothing on an ordinary boot.
# ------------------------------------------------------------------------------------------------
"${CODE}/conf/cleanup-legacy-stores.sh" &

exec supervisord -c /etc/supervisor/supervisord.conf
