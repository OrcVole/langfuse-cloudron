# Security

Security posture and the **Phase 6 hardening-pass record** for the Langfuse Cloudron package.

## Reporting a vulnerability

Please report suspected vulnerabilities **privately** to the maintainer (the `contactEmail` in
`CloudronManifest.json`) rather than opening a public issue. Vulnerabilities in Langfuse itself belong
upstream: <https://github.com/langfuse/langfuse/security>.

## Trust model (one paragraph)

A single Cloudron app: four processes under one Supervisor in one container, all running as the
unprivileged **`cloudron`** user (UID 1000) — only `supervisord` (the process manager) is root. Postgres
and Redis are **Cloudron addons**; ClickHouse and MinIO are **bundled** and internal. **The container is
the trust boundary.** TLS is terminated by Cloudron's reverse proxy; the app speaks plain HTTP behind it.
Langfuse owns its **own** auth (NextAuth + the Cloudron `oidc` addon); there is **no `proxyAuth`**.

---

## Phase 6 hardening pass — 2026-06-30

A discrete, recorded pass (its absence of a record before is why it could not previously be confirmed
done). Method legend: **[src]** source/config review · **[build]** `test/smoke.sh` gate ·
**[ext]** external read-only probe of the live instance · **[box]** in-container read-only inspection of
the running instance.

**Method note:** scope 1 was a **manual full-surface audit** of the committed package, *not* the
`/security-review` skill — that skill reviews a *pending diff*, and the working tree was clean
(everything committed), so a manual whole-package review is the appropriate and more thorough method here.

**Verdict: PASS — no findings requiring remediation.** Seven items were reviewed and either accepted
with rationale or noted as a low-severity hardening opportunity (listed at the end).

### 1. Code / config / dependency surface
- No hardcoded secrets in any tracked file; `test/secret-scan.sh` denylist gate **passes** (tracked tree
  clean). **[src][build]**
- Entry scripts use `set -euo pipefail`, quoted expansions, no `eval`, and never interpolate external
  data into commands. **[src]**
- Secrets are generated first-run (`openssl rand`), written under `umask 077` to `/app/data/.secrets`,
  re-asserted every boot; `ENCRYPTION_KEY` is 64-hex-guarded, **fail-loud**, and **never reseeded**
  (`start.sh`). **[src]**
- `CLICKHOUSE_PASSWORD` is injected via `from_env` at ClickHouse start — never baked into the image
  (`conf/clickhouse/users.d/`). **[src]**
- Dependencies are pinned by **digest** (base image, both Langfuse images, ClickHouse, MinIO, `mc`); the
  package adds no unpinned installs in the final stage. Tradeoff in *Maintenance*. **[src]**
- Minimal build context: `.dockerignore` admits only `start.sh` / `supervisor/` / `conf/`, and both
  `.dockerignore` and `.gitignore` exclude `*token*.txt`, `*.secret(s)`, `.env*`, and local notes. **[src]**

### 2. Container & capabilities
- Manifest declares **no `capabilities`** → Cloudron default (no `NET_ADMIN`/`MLOCK`/etc.). **[src]**
- **Zero package-introduced setuid/setgid binaries.** The only setuid files present are cloudron/base
  standard Ubuntu binaries (`su`, `sudo`, `mount`, `passwd`, …); the bundled binaries (`node-musl`,
  `clickhouse`, `minio`, `mc`, `migrate`) are not setuid. The base userland is platform-mandated and not
  package-strippable. **[box]**
- Network-facing services run as **`cloudron`**, not root (confirmed: `minio`, `clickhouse`; web/worker
  are `user=cloudron` per the supervisor config); only `supervisord` is root. **[box][src]**
- Secrets-at-rest perms confirmed on the live instance: `/app/data/.secrets` = **700**, `secrets.env` =
  **600**, owner `cloudron:cloudron`. **[box]**
- musl/glibc isolation holds: `node-musl` maps only `/opt/musl/lib`; `clickhouse` maps only glibc
  (smoke PROOF 2). **[build]**

### 3. Network surface — verified against the running instance
Listening sockets in the container **[box]**:

| Service | Bind | Externally reachable? |
|---|---|---|
| ClickHouse HTTP / native | `127.0.0.1` + `::1` : 8123 / 9000 | no — localhost only |
| MinIO console | `127.0.0.1` : 9101 | no — localhost only |
| MinIO API | `0.0.0.0` : 9100 | **only via the blob subdomain** — gated by a private bucket + presigned URLs |
| Langfuse web | `0.0.0.0` : 3000 | yes — the app domain; Langfuse owns auth |
| Langfuse worker | container IP : 3030 | no — not declared in the manifest, so not routed |

- ClickHouse `interserver` / `mysql` / `postgresql` ports are removed (`conf/clickhouse/config.d/`). **[src]**
- Only the **two manifest-declared** surfaces are external (web → app domain; MinIO :9100 → blob
  subdomain); both are protected. **[src][box]**
- Live confirmation: an anonymous GET on the blob bucket returns **`403 AccessDenied`, no listing** (no
  anonymous-read policy has crept in); the internal ports are **unreachable** from outside. **[ext]**

### 4. Auth surface
- `/api/public/*` is the **only** open-without-session surface, and ingestion is **API-key-gated** — a
  POST without a key returns **401** (confirmed live). The health path is intentionally open (200,
  liveness). **[ext][src]**
- Everything else sits behind Langfuse NextAuth + the Cloudron `oidc` addon (`AUTH_CUSTOM_*` ←
  `CLOUDRON_OIDC_*`). **No `proxyAuth`** anywhere; `optionalSso: true`. **[src]**

### 5. Secrets — at rest & in transit
- **At rest:** `0600 cloudron` in `/app/data/.secrets` (live); `ENCRYPTION_KEY` is load-bearing and
  survives backup/restore **byte-identical** (Gate 3); never reseeded. **[box][build]**
- **In logs:** entry scripts log secret *presence*, never *values*; the smoke gate asserts no
  `ENCRYPTION_KEY` appears in logs (passes). **[src][build]**
- **In transit:** external hops are Cloudron-terminated **TLS** (web and blob; live HTTPS / HTTP-2).
  Internal hops (ClickHouse/MinIO over localhost; Postgres/Redis addons over the Docker bridge) are
  plaintext on the trusted internal network — the standard Cloudron addon model. **[ext][src]**

### Observations accepted with rationale (not defects)
1. **MinIO API on `0.0.0.0:9100`** — required so the Cloudron proxy can reach it for the public blob
   subdomain; external exposure is gated by a private bucket + presigned URLs (verified: 403 for
   anonymous).
2. **Worker on the container IP, :3030** — not declared in the manifest, so not routed or reachable
   externally; a stricter localhost bind buys nothing under per-app network isolation.
3. **All four processes inherit the secrets via env** — equivalent to the shared `0600` secrets file they
   can all read as the same `cloudron` user; the trust boundary is the container, not the process.
4. **Internal addon hops are plaintext** (Postgres/Redis over the Docker bridge) — the standard Cloudron
   model; no external exposure.
5. **Images are pinned by digest** — deliberate and reproducible; the cost is manual security-bump
   responsibility (see *Maintenance*).
6. **Base-image setuid binaries present** (`su`/`sudo`/…) — cloudron/base platform surface, required by
   the dashboard file-manager / web-terminal; not package-actionable.
7. **Bundled ClickHouse user has `access_management` + `named_collection_control` enabled** (low-severity
   opportunity, not a defect) — broader than a pure app-DB user strictly needs, but the surface is
   localhost-only, single-tenant, and behind a strong generated password, so it is not exploitable as
   shipped. Tightening would require first verifying Langfuse's migration/runtime needs; deferred.

### Maintenance / re-test triggers
- **Bump the pinned images on upstream security releases** (Langfuse, ClickHouse, MinIO, base) — pinning
  by digest means no automatic CVE patching.
- Re-run `test/secret-scan.sh` (the release gate) and `test/smoke.sh` on every change.
- **Re-run this hardening pass** when ports, binds, addons, the manifest surface, or the base image change.
