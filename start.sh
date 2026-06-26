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
# ------------------------------------------------------------------------------------------------
mkdir -p "${DATA}/clickhouse/logs" "${DATA}/clickhouse/tmp" "${DATA}/clickhouse/access" \
         "${DATA}/clickhouse/user_files" "${DATA}/clickhouse/format_schemas" \
         "${DATA}/minio/langfuse" "${DATA}/.secrets" /run/langfuse
chown -R cloudron:cloudron "${DATA}" /run/langfuse
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
# ------------------------------------------------------------------------------------------------
exec supervisord -c /etc/supervisor/supervisord.conf
