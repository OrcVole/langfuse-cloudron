# syntax=docker/dockerfile:1
#
# Langfuse for Cloudron — build shape S2 "musl-in-place".
# Rationale, alternatives, and the proven S1 fallback: docs/decisions/0002-build-shape-and-libc.md.
#
# WHY THIS LOOKS UNUSUAL (read before editing):
#   The official Langfuse images are `node:24-alpine` => MUSL libc. cloudron/base is glibc Ubuntu 24.04,
#   and Cloudron REQUIRES the final image stage to be cloudron/base (its dashboard file-manager / web
#   terminal / log viewer depend on the base userland). So we cannot ship an Alpine final stage.
#
#   Instead we run the upstream MUSL Node + the upstream MUSL Prisma engines UNCHANGED, by bringing a
#   small, fully ISOLATED musl userland onto the glibc base under /opt/musl/lib + the musl loader. This
#   keeps a version bump to "change LANGFUSE_VERSION, rebuild" with NO engine downloads and exact upstream
#   fidelity. ClickHouse and MinIO are ordinary glibc / static-Go binaries that run natively on the base.
#
#   ISOLATION: `node-musl` is the ONLY musl binary in the image. An ELF interpreter is per-binary
#   (node-musl -> /lib/ld-musl-x86_64.so.1; everything glibc -> /lib64/ld-linux-x86-64.so.2), and the
#   musl loader is pointed at /opt/musl/lib ONLY (see step 1c), so the two libc worlds never cross.

ARG LANGFUSE_VERSION=4.43.0

# ----- pinned upstream sources (digests verified 2026-09-23) -------------------------------------
# v4.x web/worker images come from ghcr.io: upstream's Docker Hub push for 4.2.0 never happened
# (Hub tops out at 4.1.0 as of 2026-08-02) while ghcr.io carries the 4.x line under the langfuse org.
# ClickHouse 26.4 is langfuse v4's RECOMMENDED version (25.12 is the floor); digest re-resolved from
# the 26.4 tag, which drifted since 2026-08-03 (mutable tag, expected; re-verify at every bump).
#
# MinIO/mc moved from docker.io to quay.io (2026-09-23 round): docker.io/minio/{minio,mc} now
# returns "requested access to the resource is denied" for EVERY tag, including the digest this
# file had pinned -- not a new restriction on old versions, the whole docker.io repo is gone for
# anonymous pulls. quay.io/minio/{minio,mc} serves the identical content (matching digests for the
# tags this file already had pinned), and is the registry MinIO's own docs point to now.
#
# minio: bumped to the newest available build (RELEASE.2025-09-07T16-13-09Z.hotfix.7aa24e772,
# 2026-04-01) to fix google.golang.org/grpc CVE-2026-33186 in one embedded copy. It does NOT close
# github.com/rabbitmq/amqp091-go CVE-2026-77405/77408/77411 (still v1.10.0, fix needs 1.13.0) or a
# second embedded grpc copy at v1.71.0 -- checked every tag MinIO has published since, none fixes
# it (trivy re-run against the candidate before pinning, not assumed). Accepted as an open upstream
# gap: amqp091-go backs MinIO's optional bucket-notification-to-RabbitMQ target, which this package
# never configures (no MINIO_NOTIFY_AMQP_* anywhere in start.sh), and the remaining grpc copy is
# MinIO's inter-node clustering RPC, inert in the single-node standalone mode this package runs
# (one MINIO_STORE path, no distributed/erasure-coding flags). Re-check every future bump.
# mc: same content as before (digest unchanged), only the registry moved.
FROM ghcr.io/langfuse/langfuse:4.43.0@sha256:d6165b4ef72027c128c6132a4d87a4643945f6ba01f9cb5d6e4af7e5e3bf5316            AS lfweb
FROM ghcr.io/langfuse/langfuse-worker:4.43.0@sha256:59be62f49978b656b27656cba7314097c6e9ca8d63ed6ef6f66394f6aaeede1b     AS lfworker
FROM docker.io/clickhouse/clickhouse-server:26.4@sha256:c7796a1335d14385c052f10061cf719f4a368a908432ec25980860b1333e9ccd AS clickhouse
FROM quay.io/minio/minio@sha256:cf3dadcfa1fb0324f43958bad1abba986d53c4ecc04d4d50b46c7dcda28bd3cd                        AS minio
FROM quay.io/minio/mc@sha256:a7fe349ef4bd8521fb8497f55c6042871b2ae640607cf99d9bede5e9bdf11727                           AS mc

# =================================================================================================
# 5.1.0, not 5.0.0: fleet policy since crawl4ai 2026-09-23 (field guide #265) is to fold the base
# bump into each package's next natural update round rather than a dedicated sweep; this is that
# round for langfuse. Same Ubuntu 24.04/glibc 2.39 ABI. Re-run the secret scan after rebuilding
# (field guide #266: 5.1.0 dropped the base's inert SSH host keys entirely, 3 -> 0 expected).
FROM cloudron/base:5.1.0@sha256:1c0666c9abe9e2090d33686826d4e97769b799124573118d41e0d7485135748e

ARG LANGFUSE_VERSION
ENV LANGFUSE_VERSION=${LANGFUSE_VERSION}
# The PACKAGE version, ours, distinct from LANGFUSE_VERSION above. It exists only to stamp the OCI
# label at the bottom of this file. That label was hardcoded "0.3.0" from 0.3.0 until 2026-08-20 and
# was therefore wrong on four consecutive releases -- a version string that nothing reads is a
# version string nobody notices is lying. Passed by the build as --build-arg PKG_VERSION=<manifest
# version>; it defaults to "0.0.0-unset" so an unstamped image is obviously unstamped rather than
# quietly claiming a real release.
ARG PKG_VERSION=0.0.0-unset

# -------------------------------------------------------------------------------------------------
# 1. The isolated musl userland (S2). Every artifact here is COPYed from the pinned upstream web image,
#    so it is automatically version-matched whenever LANGFUSE_VERSION moves.
# -------------------------------------------------------------------------------------------------
#  1a. The musl dynamic loader. node-musl's ELF interpreter is hard-coded to this absolute path, so the
#      file MUST live exactly here. It is also the musl C library (libc.musl-x86_64.so.1 -> this file).
COPY --from=lfweb /lib/ld-musl-x86_64.so.1 /lib/ld-musl-x86_64.so.1
#  1b. The shared-library closure node-musl + the Prisma engines need (from `ldd`):
#        node          -> libstdc++.so.6, libgcc_s.so.1
#        prisma engines -> libssl.so.3, libcrypto.so.3, libgcc_s.so.1
#      Kept in a DEDICATED dir so the musl loader can never resolve a glibc object from /usr/lib.
RUN mkdir -p /opt/musl/lib
COPY --from=lfweb /usr/lib/libstdc++.so.6 /opt/musl/lib/libstdc++.so.6
COPY --from=lfweb /usr/lib/libgcc_s.so.1  /opt/musl/lib/libgcc_s.so.1
COPY --from=lfweb /usr/lib/libssl.so.3    /opt/musl/lib/libssl.so.3
COPY --from=lfweb /usr/lib/libcrypto.so.3 /opt/musl/lib/libcrypto.so.3
#  1c. Point the musl loader's search path at ONLY our dir. This file REPLACES musl's built-in default
#      path, so a musl binary can never pick up a glibc /usr/lib object (and vice-versa).
RUN printf '/opt/musl/lib\n' > /etc/ld-musl-x86_64.path
#  1d. The upstream MUSL Node 24.18, installed as `node-musl` — it deliberately does NOT shadow the
#      base's glibc `node` (the Cloudron dashboard tooling uses the base node). We invoke node-musl
#      explicitly for web, worker, and the Prisma CLI.
COPY --from=lfweb /usr/local/bin/node /usr/local/bin/node-musl

# -------------------------------------------------------------------------------------------------
# 2. The Langfuse application trees + Prisma CLI (migrations) + the static ClickHouse migrate binary.
#    Each tree keeps its upstream /app layout so cwd-relative paths match upstream exactly:
#      /app/code/web   = web image /app    (run cwd here: node-musl ./web/server.js)
#      /app/code/worker= worker image /app (run cwd here: node-musl worker/dist/index.js)
# -------------------------------------------------------------------------------------------------
COPY --from=lfweb    /app                               /app/code/web
COPY --from=lfworker /app                               /app/code/worker
COPY --from=lfweb    /usr/local/lib/node_modules/prisma /app/code/prisma-cli
COPY --from=lfweb    /usr/bin/migrate                   /usr/bin/migrate

# -------------------------------------------------------------------------------------------------
# 3. VERSION-AGNOSTIC engine pins. The real engine files carry the .pnpm hash and the openssl suffix in
#    their paths/names and can move between Langfuse releases. Resolve them ONCE at build time and expose
#    STABLE symlinks, so PRISMA_*_ENGINE never needs editing on a version bump (a moved path just gets a
#    fresh symlink at the next build). Prisma's own os-release detection would (wrongly) demand a debian
#    engine on this glibc base; pointing the env at the in-image MUSL engines overrides that.
# -------------------------------------------------------------------------------------------------
RUN set -eu; mkdir -p /app/code/.engines; \
    QE="$(find /app/code/web -name 'libquery_engine-linux-musl-*.so.node' | head -1)"; \
    SE="$(find /app/code/prisma-cli /app/code/web -name 'schema-engine-linux-musl-*' -type f | head -1)"; \
    [ -n "$QE" ] && [ -n "$SE" ] || { echo "FATAL: musl Prisma engine(s) not found"; exit 1; }; \
    ln -sf "$QE" /app/code/.engines/query-engine.so.node; \
    ln -sf "$SE" /app/code/.engines/schema-engine; \
    ls -l /app/code/.engines
ENV PRISMA_QUERY_ENGINE_LIBRARY=/app/code/.engines/query-engine.so.node \
    PRISMA_SCHEMA_ENGINE_BINARY=/app/code/.engines/schema-engine

# -------------------------------------------------------------------------------------------------
# 4. Bundled glibc services: ClickHouse (one ~590 MB multicall binary + the symlinks we use) and the
#    static-Go MinIO server + mc client.
# -------------------------------------------------------------------------------------------------
COPY --from=clickhouse /usr/bin/clickhouse    /usr/bin/clickhouse
COPY --from=clickhouse /etc/clickhouse-server /etc/clickhouse-server
COPY conf/clickhouse/config.d/cloudron.xml     /etc/clickhouse-server/config.d/cloudron.xml
COPY conf/clickhouse/users.d/cloudron-user.xml /etc/clickhouse-server/users.d/cloudron-user.xml
# Remove the upstream image's docker config that binds ClickHouse to 0.0.0.0/:: — we bind localhost only
# (listen settings are in conf/clickhouse/config.d/cloudron.xml).
COPY conf/clickhouse/backups.xml                /etc/clickhouse-server/backups.xml
RUN rm -f /etc/clickhouse-server/config.d/docker_related_config.xml \
 && ln -sf /usr/bin/clickhouse /usr/bin/clickhouse-server \
 && ln -sf /usr/bin/clickhouse /usr/bin/clickhouse-client \
 && ln -sf /usr/bin/clickhouse /usr/bin/clickhouse-local
COPY --from=minio /usr/bin/minio /usr/bin/minio
COPY --from=mc    /usr/bin/mc    /usr/bin/mc

# -------------------------------------------------------------------------------------------------
# 4b. napi-rs native modules: point each loader at the musl binary upstream actually installed.
#     napi-rs loaders choose a binary by reading /usr/bin/ldd. On this glibc base that says "gnu", but
#     the upstream Alpine images install only the *-musl binaries -- and musl is correct, because the
#     Node we run IS musl (step 1d). Found 2026-09-23: langfuse 4.43's new @langfuse/native (and
#     @node-rs/xxhash, used by traceBatching) failed to load, so the worker crash-looped while
#     supervisor still reported it RUNNING and the smoke test passed; no trace ever reached
#     ClickHouse (test/ingest.sh caught it). Fixed PER MODULE with a symlink from the gnu name to the
#     installed musl binary: the loaders' global override, NAPI_RS_NATIVE_LIBRARY_PATH, would make
#     every napi-rs module in the process load the same file.
# -------------------------------------------------------------------------------------------------
RUN set -eu; \
    for idx in $(grep -rl --include=index.js isMuslFromFilesystem /app/code/web /app/code/worker || true); do \
      d=$(dirname "$idx"); \
      for gnu in $(grep -oE "\./[A-Za-z0-9._-]+\.linux-x64-gnu\.node" "$idx" | sort -u); do \
        name=${gnu#./}; musl=$(echo "$name" | sed 's/linux-x64-gnu/linux-x64-musl/'); \
        if [ -f "$d/$musl" ]; then ln -sf "$musl" "$d/$name"; echo "napi: $d/$name -> $musl"; continue; fi; \
        pkg=$(grep -oE "require\('[^']+-linux-x64-musl'\)" "$idx" | head -1 | sed -E "s/require\('(.+)'\)/\1/"); \
        f=$(find /app/code -path "*/node_modules/$pkg/$musl" | head -1); \
        if [ -n "$f" ]; then ln -sf "$f" "$d/$name"; echo "napi: $d/$name -> $f"; \
        else echo "napi: NO musl binary for $idx ($pkg/$musl)"; exit 1; fi; \
      done; \
    done

# 5. Build-time gates — prove the assembled shape on the base before shipping (deeper engine-load, DNS,
#    and live libc-isolation proofs run in the runtime smoke test).
# -------------------------------------------------------------------------------------------------
RUN echo "== gate: musl node =="        && /usr/local/bin/node-musl --version
# Every napi-rs native module must actually LOAD under the musl Node (step 4b). A module that does not
# load kills the worker on start, which supervisor restarts forever while reporting RUNNING.
RUN echo "== gate: napi-rs native modules load ==" && set -eu \
 && n=0; for idx in $(grep -rl --include=index.js isMuslFromFilesystem /app/code/web /app/code/worker || true); do \
      /usr/local/bin/node-musl -e "require('$idx')" || { echo "napi-rs module FAILS to load: $idx"; exit 1; }; \
      echo "loads: $idx"; n=$((n+1)); \
    done; echo "napi-rs modules loaded: $n"; [ "$n" -ge 2 ]
RUN echo "== gate: musl schema-engine ==" && /app/code/.engines/schema-engine --version
RUN echo "== gate: static migrate =="   && /usr/bin/migrate -version
RUN echo "== gate: clickhouse =="        && /usr/bin/clickhouse --version \
 && { ldd /usr/bin/clickhouse 2>&1 | grep -qi 'not found' && { echo 'clickhouse: unresolved libs'; exit 1; } || true; }
RUN echo "== gate: minio + mc =="       && /usr/bin/minio --version && /usr/bin/mc --version
# v0.2.0: backup/restore run in a temp container with a read-only rootfs, so everything they need must
# already be in the image. rsync comes from cloudron/base (never installed here) — prove it, do not
# assume it. `clickhouse local` is the multicall subcommand; the symlink above just makes it explicit.
RUN echo "== gate: backup toolchain ==" && command -v rsync && rsync --version | head -1 \
 && /usr/bin/clickhouse-local --version

# -------------------------------------------------------------------------------------------------
# 6. Packaging runtime: config overrides + supervisor + entrypoint. CMD, never ENTRYPOINT.
# -------------------------------------------------------------------------------------------------
ENV NODE_ENV=production NEXT_TELEMETRY_DISABLED=1 TELEMETRY_ENABLED=false
COPY conf/                /app/code/conf/
COPY supervisor/          /etc/supervisor/
COPY start.sh             /app/code/start.sh
RUN chmod 0755 /app/code/start.sh /app/code/conf/*.sh 2>/dev/null || chmod 0755 /app/code/start.sh

LABEL org.opencontainers.image.title="Langfuse for Cloudron" \
      org.opencontainers.image.description="Open-source Langfuse (LLM observability) packaged for Cloudron" \
      org.opencontainers.image.source="https://github.com/OrcVole/langfuse-cloudron" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${PKG_VERSION}"

CMD [ "/app/code/start.sh" ]
