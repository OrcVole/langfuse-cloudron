# Packaging notes — verified vs assumed (newest first)

The empirical-verification log. Every entry records what was **confirmed against a running
box/image** versus **carried over by assumption**. Anonymized (no real hostnames/emails/tokens).

---

## Phase 4 — gates on the box (2026-06-26)

All four gates **GREEN** on a throwaway test install, by digest
`sha256:3e1388815ef1d0faecd9f4571e174d8ffa0e2d2a01a658119629c62d5e501dbb` (the `:3.199.0-1` content).

- **Gate 1 — OIDC SSO ✅** oidc addon injected `CLOUDRON_OIDC_*`; NextAuth provider id `custom`, callback
  `/api/auth/callback/custom` (verified via `/api/auth/providers`, the live OAuth `redirect_uri`, AND
  Cloudron's `loginRedirectUri: /api/auth/callback/custom` setup log). A real Cloudron user signed in
  end-to-end → `users` row created + `Account` row `custom|oauth` linked. `/api/public/*` stayed open
  (health 200; ingestion 401, not a 302 login); no proxyAuth. **Prediction held — no callback-path
  correction needed.**
- **Gate 2 — media ✅** (a) Host preservation: external SigV4 + byte-identical upload/download through
  the proxy. (b) Real Langfuse media POST→PUT→**PATCH**→GET: presigned URLs resolve to
  `https://<blob>/langfuse/media/…`, PUT 200, download sha256-identical. (c) Hairpin: container→own blob
  URL = 200/150 ms; `/etc/hosts` fallback NOT needed. New 0.1.2 detail: skip the PATCH and the download
  404s "not yet uploaded" though bytes are in MinIO.
- **Gate 3 — update + backup/restore ✅** Real update (rc1→rc2) + real backup→in-place restore:
  ENCRYPTION_KEY **byte-identical** (`04895f12…`) across both; `0600 cloudron` re-asserted post-restore;
  `existing secrets` path; data intact (pg 1/1/1/1, CH traces). **Bundled ClickHouse + MinIO data in
  `/app/data` survives Cloudron backup/restore** alongside addon Postgres.
- **Gate 4 — memory ✅** (ADR 0005) Heavy-ingest peak **2.58 GiB**; worst-case bound ~4.6 GiB (CH 2 GiB
  cap + 2 Node + MinIO + base) → **memoryLimit 5 GiB**, CH cap 2 GiB. Constrained-box option:
  4 GiB / CH 1.5 GiB. CPU: `nproc=12`, `cpu.max` unlimited; ClickHouse 737 threads + MinIO 66 use cores
  well, Node JS single-threaded per process. Ship the default (no cgroup-CPU pools); caveat for
  operators who set a Cloudron CPU limit → field guide 0.1.2.

---

## Phase 2/3 — entrypoint, manifest, media + local hardening (2026-06-26)

### Verified (local containers)

- **`test/smoke.sh` = 10/10** (health 200; four services RUNNING; ENCRYPTION_KEY 64-hex + not in logs;
  musl→container-DNS→connect; libc isolation live; **ClickHouse timezone = UTC**).
- **`test/ingest.sh` = full pipeline end-to-end**: API-key auth → ingestion (HTTP 207) → web → Redis →
  worker → ClickHouse (read back via `/api/public/traces`) → event object in bundled MinIO. Proves the
  open `/api/public/*` ingestion path works.
- **Lifecycle (data-loss-critical)**: first-run generates secrets; restart/update takes the
  existing-secrets path with **ENCRYPTION_KEY sha256 UNCHANGED**; a simulated restore mode-drift
  (owner→root, mode→0644) is **re-asserted to 0600 cloudron:cloudron** every boot, key still unchanged.
- **ClickHouse bound localhost-only**: removed the upstream image's `docker_related_config.xml` (forced
  `listen_host 0.0.0.0` + `::`) at build time; bind `127.0.0.1` + `::1` via the override. App still
  healthy → Langfuse reaches CH over localhost.
- **httpPorts contract** (agentgateway): key = runtime env var = subdomain FQDN; `containerPort` = listen
  port. → `LANGFUSE_BLOB_DOMAIN` key, MinIO binds **0.0.0.0:9100** so the proxy can reach it.
- **OIDC**: custom provider id = `custom` → `loginRedirectUri /api/auth/callback/custom`; AUTH_CUSTOM_*
  var names confirmed.
- **Media** (3.199): single `LANGFUSE_S3_MEDIA_UPLOAD_ENDPOINT` (presign + server-side) → blob subdomain
  (ADR 0004).

### Pending (need the box — Phase 4)

OIDC SSO login end-to-end; media presigned upload/preview through the Cloudron proxy (Host preservation,
real upload+download, hairpin); update + backup/restore survival on the platform; memoryLimit RSS
measurement.

---

## Phase 1 — Build-shape spike & integration gate (2026-06-26)

### Verified (on the box / in real containers)

- **Build shape S2 (musl-in-place) proven and adopted** (ADR 0002). The upstream musl Node 24.18 + the
  in-image musl Prisma engines + the static `migrate` run on glibc cloudron/base via an isolated
  `/opt/musl/lib` + the musl loader + `PRISMA_*_ENGINE` env overrides. S1 (glibc-native) was also proven
  but rejected (CDN engine download, Node 22-vs-24 mismatch, per-bump version sync).
- **Full Dockerfile builds clean**; all build gates pass (musl node, musl schema-engine, static migrate,
  clickhouse 25.3.14.14, minio + mc).
- **Four-service integration gate PASSED**: ClickHouse + MinIO + web + worker all boot;
  `/api/public/health` = **200 in ~15 s**. ENCRYPTION_KEY is 64 hex; no secret appears in logs.
- **PROOF 1 — musl → Docker-internal DNS → CONNECT**: musl Node resolves and connects to Postgres
  (`lf-pg:5432`) and Redis (`lf-redis:6379`) by container hostname; the real **412 Postgres + 34
  ClickHouse migrations** ran over those hostnames. (Local podman/netavark DNS; re-confirm on real
  Docker 127.0.0.11 in Phase 4.)
- **PROOF 2 — libc isolation under all four processes**: `node-musl` (web `next-server` + worker) map
  **only** `/opt/musl/lib/*` + ld-musl (no glibc); `clickhouse` maps **only** glibc; `minio` is static
  Go. No cross-contamination.
- **ClickHouse**: migrations succeed; `from_env` password auth works; tables created. UTC set via
  config (verify timezone at runtime in Phase 4).
- **Redis addon policy = `noeviction`** → use the addon, no bundling (ADR 0003).
- **MinIO bucket** created the upstream way (`mkdir` the bucket dir before MinIO starts) — no `mc`
  needed at boot.

### New gotchas hit (fold into the field guide at 0.1.2)

- **Port 9000 collision**: ClickHouse native (9000) vs MinIO API (9000) in one container → moved MinIO
  to **9100/9101**; ClickHouse keeps 8123 + 9000 for the migration URL.
- **up.sh is bash, not sh**: ClickHouse `up.sh` uses `&>` (a bashism); under the base's `/bin/sh`→dash
  it mis-parses and falsely reports "golang-migrate not installed". Invoke with **`bash`**.
- **Next standalone binds `$HOSTNAME`**, which Docker sets to the container id → force `HOSTNAME=0.0.0.0`
  in the web wrapper (gotcha 4, Next.js form).
- **`mc` needs a writable HOME/config dir** as the cloudron user — sidestepped by the mkdir-bucket
  approach.

### Assumed / pending

- **S3 presigned media browser-reachability** (gotcha 34, ADR 0004) — event uploads are server-side
  (internal endpoint, fine); media presigned URLs need a browser-reachable endpoint. Decide routing in
  Phase 3 (httpPorts blob subdomain vs path proxy). Verify which `LANGFUSE_S3_MEDIA_*` external-endpoint
  vars 3.199 exposes.
- **OIDC SSO end-to-end** (Phase 3) — `start.sh` maps `CLOUDRON_OIDC_*` → `AUTH_CUSTOM_*`; unverified
  until a real Cloudron user signs in.
- **memoryLimit** — measure RSS under ingestion load in Phase 4 (target ~3–4 GiB).

---

## Phase 0 — Orientation & contract (2026-06-26)

### Verified (against the registry / local tooling)

- **Upstream images exist for v3.199.0** and are `amd64/linux`, released 2026-06-26. Digests pinned:
  - web `langfuse/langfuse:3.199.0` → `sha256:21d2596b364b63f880e5e0f53153719dd85562451f05cc406c6c4a9b0f5e2b01`
  - worker `langfuse/langfuse-worker:3.199.0` → `sha256:8999216f0e18f445bb19195423aa7dbb58e64114c3c4d4c8fe27856994169130`
- **Both images are `node:24-alpine` (musl libc)**, Node **24.18.0**, `WORKDIR /app`, run behind
  `dumb-init -- ./{web,worker}/entrypoint.sh`. Web `CMD`: `node ./web/server.js --keepAliveTimeout
  110000`; worker `CMD`: `node worker/dist/index.js`. Confirmed from `skopeo inspect --config` + the
  upstream `web/Dockerfile` / `worker/Dockerfile` (`FROM node:24-alpine`, `npm i -g prisma@6.19.3`,
  a `golang:1.26` migrate-builder stage).
- **`cloudron/base:5.0.0` ships glibc Node 24.13.1** (and Node 22.14 LTS) — same Node major as the
  images (ABI-compatible for N-API), **different libc** (glibc vs musl). → Build-shape risk #1.
- **Logo**: the provided `langfuse-logo-512.png` is **byte-identical** to the canonical upstream
  `web/public/icon512.png` (sha256 `cd876c08…`). Copied verbatim to `logo.png` (512×512 RGBA PNG).
- **cloudron CLI is logged into the box** and lists apps. AI-stack apps confirmed present:
  `agentgateway`, `owebui` (OpenWebUI), `docling`, `tei`, `qdrant`, `ollama`. **No `langfuse` app
  exists yet** — clean slate.
- Local tooling present: podman 5.8.2, docker 29.5.3, skopeo 1.22.2, buildah, git 2.54, cloudron CLI 7.0.5.
- Both publish tokens are present and readable outside the repo (41 bytes each).

### Assumed / pending (to prove later)

- **libc strategy** (musl-in-place vs glibc-native) — the #1 Phase 1 spike. ADR 0002.
- **Redis eviction policy** of the Cloudron addon — must be `noeviction` for BullMQ, else bundle
  Redis as a 5th process (gotcha 31). ADR 0003. Investigate on box in Phase 1.
- **ClickHouse + MinIO versions** — not yet picked/pinned. Must run on the base and be UTC (CH).
- **Postgres 14.9** (Cloudron addon) vs upstream default 17 — assume compatible (Langfuse supports
  PG 12+); verify no PG15+ feature is required.
- **S3 presigned media reachability** — media endpoint must be browser-reachable (gotcha 34). Routing
  (path proxy vs `httpPorts` blob subdomain) undecided. ADR 0004.
- **Web image vs worker image** — assume both are needed as separate `COPY --from` sources (web tree
  lacks `worker/dist`); confirm in Phase 1.
- **Manifest `id`, `memoryLimit`, registry, `contactEmail`, prod domain** — pending operator
  confirmation (Phase 0 STOP & ASK).
