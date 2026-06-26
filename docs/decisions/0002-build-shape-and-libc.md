# 2. Build shape and the musl-vs-glibc question

Date: 2026-06-26

## Status

**Accepted** — Strategy 2 (musl-in-place). Both strategies were proven on the box; S2 chosen for
maintainability/reproducibility (operator-confirmed).

## Context

The official Langfuse runtime images (`langfuse/langfuse`, `langfuse/langfuse-worker`, v3.199.0) are
built `FROM node:24-alpine` — **musl libc**, Node 24.18.0. `cloudron/base:5.0.0` is **glibc** Ubuntu
24.04, and Cloudron requires the final image stage to be `cloudron/base` (dashboard file manager / web
terminal / log viewer depend on it). A naive `COPY /app` lands musl-linked artifacts on glibc.

Ground-truth inventory of the web image:

- The only load-bearing native module is **Prisma** (`libquery_engine-linux-musl-openssl-3.0.x.so.node`,
  6.19.3; engine hash `c2990dca…`); a `schema-engine-linux-musl-openssl-3.0.x` ships in the global
  prisma CLI. The image carries **only musl engines** (no debian engine).
- `/usr/bin/migrate` (ClickHouse migrations) is a **static** Go binary → libc-agnostic.
- `@datadog/*` native addons are **dormant** (dd-trace only imported when
  `NEXT_PUBLIC_LANGFUSE_CLOUD_REGION` is set; we leave it empty).
- musl dependency closure (from `ldd`): `node` → ld-musl + libstdc++.so.6 + libgcc_s.so.1;
  Prisma engines → ld-musl + libssl.so.3 + libcrypto.so.3 + libgcc_s.so.1.

## Options proven on the box

**S1 (glibc-native)** — base glibc Node + `npm i -g prisma@6.19.3` (downloads debian engines) + place
the debian query engine in the app client dir. PASS, but: base default `node` is **22.14.0** (not the
24 upstream builds for) so Node-24 PATH pinning is needed; engines come from a **build-time CDN
download** (binaries.prisma.sh) hurting reproducibility; each upstream bump needs a prisma-version sync.
Image 3.42 GB.

**S2 (musl-in-place)** — copy the musl loader + the lib closure into an isolated `/opt/musl/lib`, set
`/etc/ld-musl-x86_64.path`, run the upstream **musl Node 24.18** + the in-image musl Prisma engines +
the static migrate. Prisma's os-release detection (which would demand a debian engine) is bypassed with
`PRISMA_QUERY_ENGINE_LIBRARY` / `PRISMA_SCHEMA_ENGINE_BINARY` pointing at the in-image musl engines.
PASS end-to-end: musl node runs, schema-engine runs, `prisma version` resolves both engines,
PrismaClient loads the engine (`$connect` fails only with "Can't reach database server"), and **musl
DNS works** (`localhost→::1`, `example.com→172.66.x`). Image 3.29 GB.

## Decision

**Strategy 2 (musl-in-place).** It is the more maintainable shape for an officially-supported app:

- **Version bump = re-COPY.** Engines and node come from the pinned image, auto-matched to the upstream
  Prisma version; no engine download, no version sync, no Node-tier juggling.
- **Reproducible.** Every artifact is from the pinned upstream image — no build-time dependency on
  Prisma's CDN.
- **Exact upstream fidelity.** Runs the same Node 24.18 + engines upstream ships and tests, removing the
  most common maintenance failure ("works upstream, breaks in the package").

The one oddity — a musl userland on a glibc base — is fully isolated under `/opt/musl/lib` (it never
touches the base's glibc tooling) and is documented here + in the Dockerfile.

## Consequences

- The final image copies from `langfuse/langfuse` (web) **and** `langfuse/langfuse-worker` (worker)
  trees (worker tree carries `worker/dist`, absent from the web image), each with its musl Prisma engine.
- `start.sh` exports `PRISMA_QUERY_ENGINE_LIBRARY` (computed: the app's musl query engine) and
  `PRISMA_SCHEMA_ENGINE_BINARY` (the musl schema engine) so migrations + client both bypass os-release
  detection. `/etc/ld-musl-x86_64.path` → `/opt/musl/lib`.
- The musl libs to copy (real files, via COPY deref): `ld-musl-x86_64.so.1`, `libstdc++.so.6`,
  `libgcc_s.so.1`, `libssl.so.3`, `libcrypto.so.3`.
- We invoke the upstream musl `node` explicitly (not the base's glibc node) for web + worker.
- Build-time linkage/runtime gate: load the Prisma engine + run a musl DNS lookup, per the spike.
- Re-verify this spike on any `LANGFUSE_VERSION` bump (engine hash / musl lib versions can move).
