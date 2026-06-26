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

ARG LANGFUSE_VERSION=3.199.0

# ----- pinned upstream sources (digests verified 2026-06-26) -------------------------------------
FROM docker.io/langfuse/langfuse:3.199.0@sha256:21d2596b364b63f880e5e0f53153719dd85562451f05cc406c6c4a9b0f5e2b01        AS lfweb
FROM docker.io/langfuse/langfuse-worker:3.199.0@sha256:8999216f0e18f445bb19195423aa7dbb58e64114c3c4d4c8fe27856994169130 AS lfworker
FROM docker.io/clickhouse/clickhouse-server:25.3@sha256:b627d7a9bc0e0c1bac26cdbe9d2fc6316faa29c5d8a174f28f5abd57d0fa6ba2 AS clickhouse
FROM docker.io/minio/minio@sha256:14cea493d9a34af32f524e538b8346cf79f3321eff8e708c1e2960462bd8936e                      AS minio
FROM docker.io/minio/mc@sha256:a7fe349ef4bd8521fb8497f55c6042871b2ae640607cf99d9bede5e9bdf11727                         AS mc

# =================================================================================================
FROM cloudron/base:5.0.0@sha256:04fd70dbd8ad6149c19de39e35718e024417c3e01dc9c6637eaf4a41ec4e596c

ARG LANGFUSE_VERSION
ENV LANGFUSE_VERSION=${LANGFUSE_VERSION}

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
RUN rm -f /etc/clickhouse-server/config.d/docker_related_config.xml \
 && ln -sf /usr/bin/clickhouse /usr/bin/clickhouse-server \
 && ln -sf /usr/bin/clickhouse /usr/bin/clickhouse-client
COPY --from=minio /usr/bin/minio /usr/bin/minio
COPY --from=mc    /usr/bin/mc    /usr/bin/mc

# -------------------------------------------------------------------------------------------------
# 5. Build-time gates — prove the assembled shape on the base before shipping (deeper engine-load, DNS,
#    and live libc-isolation proofs run in the runtime smoke test).
# -------------------------------------------------------------------------------------------------
RUN echo "== gate: musl node =="        && /usr/local/bin/node-musl --version
RUN echo "== gate: musl schema-engine ==" && /app/code/.engines/schema-engine --version
RUN echo "== gate: static migrate =="   && /usr/bin/migrate -version
RUN echo "== gate: clickhouse =="        && /usr/bin/clickhouse --version \
 && { ldd /usr/bin/clickhouse 2>&1 | grep -qi 'not found' && { echo 'clickhouse: unresolved libs'; exit 1; } || true; }
RUN echo "== gate: minio + mc =="       && /usr/bin/minio --version && /usr/bin/mc --version

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
      org.opencontainers.image.version="0.1.0"

CMD [ "/app/code/start.sh" ]
