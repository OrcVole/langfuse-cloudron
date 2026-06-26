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
3. **Persisted state ONLY in `/app/data`.** Re-assert ownership and mode on **every** boot (restore
   drifts them).
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
   commits as the maintainer's git identity.

## Locked decisions (Phase 0, operator-confirmed 2026-06-26)

- **Manifest id:** `io.github.orcvole.langfuse` (holds the `io.github.orcvole.*` line; the repo's
  `-cloudron` suffix does not enter the id).
- **Registry:** GHCR `ghcr.io/orcvole/langfuse-cloudron`, pushed **public** (box pulls without creds).
  Tag scheme `:<LANGFUSE_VERSION>-<pkg-rev>` — first build `:3.199.0-1`; rebuilds of the same upstream
  bump `-2`, `-3`. **Confirm exact namespace casing** against an existing package (docling/tei) before
  the first push (GHCR forces lowercase → `orcvole`).
- **memoryLimit:** **5 GiB (`5368709120`)** — Phase-4 measured (ingestion peak 2.58 GiB; worst-case
  bound ~4.6 GiB from the 2 GiB ClickHouse cap; ADR 0005). Constrained-box option: 4 GiB + CH cap
  1.5 GiB. Pin bundled-service memory so nothing sizes against host RAM:
  - ClickHouse: **absolute** cap via a `config.d` override —
    `<max_server_memory_usage>2147483648</max_server_memory_usage>` (2 GiB). Absolute, not a ratio:
    it is unverified whether the bundled ClickHouse reads the cgroup limit or host RAM.
  - `langfuse-web` / `langfuse-worker`: `NODE_OPTIONS=--max-old-space-size=768` (provisional).
- **contactEmail:** `Most+github@OrcadianVole.com` (GitHub-verified public alias on the OrcVole
  namespace; ships in the public manifest, leaks no private infra). Never a box/mirror address.
- **Commit author:** `OrcVole <Most+github@OrcadianVole.com>`, set **repo-local** (never the machine's
  global git identity); identical author on GitHub + Forgejo. No co-author / AI trailers.

## Pinned upstream (verified by `skopeo inspect`, 2026-06-26)

- `cloudron/base:5.0.0@sha256:04fd70dbd8ad6149c19de39e35718e024417c3e01dc9c6637eaf4a41ec4e596c`
- `langfuse/langfuse:3.199.0@sha256:21d2596b364b63f880e5e0f53153719dd85562451f05cc406c6c4a9b0f5e2b01`
  (web — `node:24-alpine` / **musl**; Node 24.18.0; `WORKDIR /app`; runs `node ./web/server.js`)
- `langfuse/langfuse-worker:3.199.0@sha256:8999216f0e18f445bb19195423aa7dbb58e64114c3c4d4c8fe27856994169130`
  (worker — same base; runs `node worker/dist/index.js`)
- ClickHouse server — **TBD**, pin `>=24.3` by digest in Phase 1.
- MinIO server + `mc` — **TBD**, pin by digest in Phase 1.

## Build shape (HYPOTHESIS — prove on the box in Phase 1; see ADR 0002)

The upstream images are **`node:24-alpine` (musl libc)**; `cloudron/base` is **glibc Ubuntu 24.04**.
A naive `COPY /app` onto the base yields a tree whose **node binary, Prisma 6.19.3 query engines, and
the bundled golang-migrate binary are all musl-linked** and will not run under glibc (gotcha 36, hard
form).

- **Leading approach (musl-in-place):** run the upstream musl userland (its `node`, Prisma engines,
  `migrate`) on `cloudron/base` via the musl loader + minimal Alpine libs, keeping every native
  artifact musl-consistent. A version bump stays a one-ARG re-`COPY` (aligns with the future-compat
  requirement). Risk: foreign-libc footguns (NSS/DNS).
- **Alternative (glibc-native):** run the app JS on the base's glibc Node 24 and **regenerate** the
  Prisma engines + rebuild native `.node` addons + the `migrate` binary for glibc. More idiomatic but
  fragile across upstream changes.

Decide empirically with the runtime smoke test (Prisma reaches Postgres, ClickHouse migration runs).

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
