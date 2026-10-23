# AGENTS.md — Langfuse Cloudron package working contract

The settled-decisions record ("golden rules") for packaging **Langfuse** (open-source, MIT) as a
Cloudron community app. Read this before changing anything. Do **not** relitigate these decisions
without a concrete reason found on a running box. The box is the authority, not the docs.

## What this package is

A single Cloudron app that runs the **open-source (MIT) Langfuse v3** observability stack as a
self-contained system. Topology — **four processes under Supervisor**, each logging to stdout:

| Process | Role | Port |
|---------|------|------|
| `clickhouse-server` | OLAP store for traces/observations | 8123 (HTTP) / 9000 (native), localhost only |
| `minio` | S3-compatible object storage (events, media, exports) | 9000 (api) / 9001 (console), localhost only |
| `langfuse-web` | Next.js web + public API (primary surface) | **3000 — the manifest `httpPort`** |
| `langfuse-worker` | BullMQ queue worker (ingestion → ClickHouse) | 3030, internal |

Postgres and Redis come from **Cloudron addons**, not bundled (Redis pending the eviction-policy
check, gotcha 31 → see ADR 0003).

## Golden rules

1. **Conformance to the Cloudron contract first.** Adapt Langfuse's *runtime environment* only;
   never patch Langfuse itself.
2. **Pin EVERYTHING by digest** (base, both langfuse images, clickhouse, minio). Exactly **one ARG
   per upstream version** (`LANGFUSE_VERSION`); the manifest mirrors it in `upstreamVersion`.
3. **Persisted state in `/app/data`, except the two stores that churn.** Re-assert ownership and mode on
   **every** boot (restore drifts them). **Amended for v0.2.0:** the bundled ClickHouse and MinIO stores
   move to `persistentDirs` (`/var/lib/clickhouse`, `/var/lib/minio`) because their constant
   create-then-rename churn inside the walked tree aborts the whole server's backup run. They stay inside
   Cloudron's backup surface via `backupCommand`/`restoreCommand`, so the *goal* of rule 3, that all state
   is captured and restorable, is unchanged; only the mechanism moves. Anything else still belongs in
   `/app/data`, and adding a third `persistentDir` needs an ADR. See
   [ADR 0006](docs/decisions/0006-clickhouse-backup-persistentdirs-triplet.md),
   [0008](docs/decisions/0008-clickhouse-store-migration.md) and
   [0009](docs/decisions/0009-clickhouse-boot-decision-tree.md).
4. **Fail loud.** Never silently regenerate `ENCRYPTION_KEY` or clobber operator config.
5. **Code and docs ship together.** ADRs in `docs/decisions/`; verified-vs-assumed log in
   `docs/PACKAGING-NOTES.md` (newest first, anonymized).
6. **`CMD`, never `ENTRYPOINT`** (ENTRYPOINT breaks Cloudron debug mode). `.dockerignore` as well as
   `.gitignore`.
7. **MIT only.** The official runtime images exclude the `/ee` code. Never set an EE license key or
   enable EE-gated features (RBAC, audit logs, data retention, SCIM).
8. **Anonymize before every push.** No test-box or private-mirror hostnames, no real emails, no
   tokens, no internal hostnames in any **tracked** file. Use `example.com` placeholders in public
   docs. `test/secret-scan.sh` is the release gate. Box-specific notes stay gitignored.
9. **Git hygiene.** No AI co-authorship or tool-attribution trailers in commits or files. Author
   commits as the maintainer's git identity. **Every push goes to BOTH remotes** — `origin` (GitHub,
   which serves the live `CloudronVersions.json` feed) and `forgejo` (the private mirror) — in the
   same sitting, never one without the other.
10. **Bound bundled engines' self-telemetry from day one.** A bundled database's internal logging
   (ClickHouse system tables here) grows without limit unless configured, and on this package it
   reached 176 million rows against 19.7 kB of application data, starved every analytics query, and
   burned multiple cores continuously (ADR 0011). Any future bundled engine gets its telemetry
   TTL-bounded or disabled in the same commit that introduces it.
11. **Publishing to the versions feed IS deploying.** Installs watch `CloudronVersions.json` on
   GitHub `main` with automatic updates on. A version entry is only pushed AFTER that exact digest has
   been deployed and verified on production, together with any one-time operational step its upgrade
   needs (0.2.1's DROP cleanup being the type specimen — an unattended config-only update without its
   cleanup is a measured outage).

## Locked decisions (Phase 0, operator-confirmed 2026-06-26)

- **Manifest id:** `io.github.orcvole.langfuse` (holds the `io.github.orcvole.*` line; the repo's
  `-cloudron` suffix does not enter the id).
- **Registry:** GHCR `ghcr.io/orcvole/langfuse-cloudron`, pushed **public** (box pulls without creds).
  Tag scheme `:<LANGFUSE_VERSION>-<pkg-rev>` — first build `:3.199.0-1`; rebuilds of the same upstream
  bump `-2`, `-3`. **Confirm exact namespace casing** against an existing package (docling/tei) before
  the first push (GHCR forces lowercase → `orcvole`).
- **memoryLimit:** **8 GiB (`8589934592`)** since v0.13.2 (5 GiB originally, ADR 0005; 6 GiB from v0.3.0).
  Pin bundled-service memory so nothing sizes against host RAM:
  - ClickHouse: **absolute** cap in `conf/clickhouse/config.d/cloudron.xml`, **4 GiB** since v0.13.2
    (2 GiB, then 2.5 GiB; ADR 0014). Absolute, not a ratio: it is unverified whether the bundled
    ClickHouse reads the cgroup limit or host RAM. `background_pool_size` 4, with the three
    `number_of_free_entries_in_pool_*` thresholds at 4 (above the pool, ClickHouse will not start).
  - `langfuse-web` / `langfuse-worker`: `NODE_OPTIONS=--max-old-space-size=768` (provisional).
- **contactEmail:** `Most+github@OrcadianVole.com` (GitHub-verified public alias on the OrcVole
  namespace; ships in the public manifest, leaks no private infra). Never a box/mirror address.
- **Commit author:** `OrcVole <Most+github@OrcadianVole.com>`, set **repo-local** (never the machine's
  global git identity); identical author on GitHub + Forgejo. No co-author / AI trailers.

## Pinned upstream (verified by `skopeo inspect`, 2026-06-26)

- `cloudron/base:6.0.1@sha256:7b1e729960c3ca312d26e886917ba89483241bba0219ff292858e10d9d5768ee` (Ubuntu 26.04, glibc 2.43)
- `ghcr.io/langfuse/langfuse:4.67.0@sha256:8e2b58b5086bfc955452a12c72eb2306bf3cb2ec59de8115454514c4c8e36e33`
  (web — Red Hat UBI 9 micro / glibc since 4.55, formerly `node:24-alpine`; Node 24.21.0; `WORKDIR /app`; runs `node ./web/server.js`)
- `ghcr.io/langfuse/langfuse-worker:4.67.0@sha256:a0ec08090953ad8d710565a23cda1b24e84dc889c9122e88df2c5b8ada4cfe1f`
  (worker — same base; runs `node worker/dist/index.js`)
- ClickHouse server — **TBD**, pin `>=24.3` by digest in Phase 1.
- MinIO server + `mc` — **TBD**, pin by digest in Phase 1.

## Build shape (settled: glibc-native since 0.11.0; see ADR 0002 and ADR 0012)

Until upstream 4.54 the images were `node:24-alpine` (musl) and the package ran the upstream musl
userland in place under `/opt/musl/lib`. From 4.55 upstream builds on Red Hat UBI 9 micro (glibc 2.34,
RHEL's Node 24 with a separate `libnode.so`, Prisma `rhel-openssl-3.0.x` engines). Those run unchanged
on the base's newer glibc, so the package now copies `/usr/bin/node` and `/lib64/libnode.so.137` and
points the Prisma env at the rhel engines. Every bump re-runs the `ldd` build gates, which fail the
build if upstream changes its libc or Node layout again.

## Secrets (first-run-only, idempotent, `/app/data/.secrets`, mode 0600, re-assert every boot)

`NEXTAUTH_SECRET`, `SALT`, `ENCRYPTION_KEY` (**exactly 64 hex chars** — `openssl rand -hex 32`),
`CLICKHOUSE_PASSWORD`, `MINIO_ROOT_USER`, `MINIO_ROOT_PASSWORD` (and `REDIS_AUTH` if Redis is bundled).
**`ENCRYPTION_KEY` is DATA-LOSS-CRITICAL** — it encrypts stored API keys and integration secrets.
Generate once, never reseed; reseeding orphans all encrypted rows (gotcha 33).

## Env mapping (translate CLOUDRON_* → Langfuse env on EVERY boot)

- `DATABASE_URL` ← `CLOUDRON_POSTGRESQL_URL`
- `REDIS_HOST`/`REDIS_PORT`/`REDIS_AUTH` ← `CLOUDRON_REDIS_*` (or bundled)
- `NEXTAUTH_URL` ← `CLOUDRON_APP_ORIGIN`
- `CLICKHOUSE_URL=http://localhost:8123`, `CLICKHOUSE_MIGRATION_URL=clickhouse://localhost:9000`,
  `CLICKHOUSE_USER`/`CLICKHOUSE_PASSWORD` (generated)
- All `LANGFUSE_S3_*` → bundled MinIO (`langfuse` bucket; event/media/export prefixes); **media
  external endpoint must be browser-reachable** (gotcha 34 → ADR 0004)
- `AUTH_CUSTOM_*` ← `CLOUDRON_OIDC_*` (SSO)
- `TELEMETRY_ENABLED=false` (no phone-home)

## Auth topology (the departure from the usual proxyAuth pattern)

Langfuse owns its own login (NextAuth). **No `proxyAuth` in front of anything.** Use
`optionalSso: true` + the **`oidc`** addon wired to Langfuse's custom OIDC provider (`AUTH_CUSTOM_*`).
Leave `/api/public/*` open at the network layer — Langfuse's own public/secret keys protect ingestion
(gotcha 35).

## Health

`healthCheckPath: /api/public/health` (liveness, 200 without auth). **Not** `/api/public/ready`
(503s during first-boot migration → restart loop; gotcha 6).

## Future-compat

A single `LANGFUSE_VERSION` build ARG is the only bump point; point releases auto-migrate on boot.
Anticipate a **v3 → v4 major** (v4 work already present in 3.199 notes) — leave an ADR stub (0007).
