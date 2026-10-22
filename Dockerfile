# syntax=docker/dockerfile:1
#
# Langfuse for Cloudron -- build shape S3 "glibc-native".
# Rationale and history: docs/decisions/0002-build-shape-and-libc.md (S2 musl-in-place, retired in
# 0.11.0) and docs/decisions/0012-ubi-upstream-glibc-native.md.
#
# WHY THIS LOOKS UNUSUAL (read before editing):
#   Cloudron REQUIRES the final image stage to be cloudron/base (its dashboard file-manager / web
#   terminal / log viewer depend on the base userland), and cloudron/base 6.0.0 ships NO Node.js.
#   From langfuse 4.55 the official images are built on Red Hat UBI 9 micro (glibc 2.34, RHEL's
#   dynamically linked Node 24 with a separate libnode.so, Prisma "rhel-openssl-3.0.x" engines).
#   Every one of those is glibc-linked and glibc is backward compatible, so they run UNCHANGED on the
#   base's glibc 2.43. We copy the upstream node + libnode.so.137 and the rhel Prisma engines; the
#   rest of the closure (libssl, libcrypto, libstdc++, libgcc_s, libz, libm) comes from the base.
#   Until 4.54 the upstream images were node:24-alpine (musl) and this file carried an isolated musl
#   userland instead; that is gone. A version bump is "change LANGFUSE_VERSION, rebuild", then re-run
#   the ldd gates below: they fail the BUILD if upstream changes its libc or node layout again.

ARG LANGFUSE_VERSION=4.62.0

# ----- pinned upstream sources (langfuse digests resolved 2026-10-16) -------------------------------------
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
FROM ghcr.io/langfuse/langfuse:4.62.0@sha256:b40241743c639226a4bcba90e8a4d7bcb3335bd9947f84034c99dd85e60580a2            AS lfweb
FROM ghcr.io/langfuse/langfuse-worker:4.62.0@sha256:050653ef8847a09cb9c264896f832a90550fbc0cf3367ac0a1f5bf6de6f23b19     AS lfworker
FROM docker.io/clickhouse/clickhouse-server:26.4@sha256:c7796a1335d14385c052f10061cf719f4a368a908432ec25980860b1333e9ccd AS clickhouse
FROM quay.io/minio/minio@sha256:cf3dadcfa1fb0324f43958bad1abba986d53c4ecc04d4d50b46c7dcda28bd3cd                        AS minio
FROM quay.io/minio/mc@sha256:a7fe349ef4bd8521fb8497f55c6042871b2ae640607cf99d9bede5e9bdf11727                           AS mc

# =================================================================================================
# cloudron/base 6.0.0 (Ubuntu 26.04, glibc 2.43; no Node.js, which is why the upstream node is copied
# below). Tag 6.0.0 resolves to this digest. Re-run the secret scan after rebuilding (field guide
# #266: the base ships no SSH host keys, found/pinned-ok/expected must all read 0).
FROM docker.io/cloudron/base:6.0.1@sha256:7b1e729960c3ca312d26e886917ba89483241bba0219ff292858e10d9d5768ee

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
# 1. The upstream Node (RHEL build: a 30 KB launcher plus libnode.so.137) on the base's glibc.
#    Version-matched to the pinned web image automatically. The launcher's other libraries (libssl,
#    libcrypto, libstdc++, libgcc_s, libz, libm, libc) are the base's own; the build gates below
#    prove nothing is "not found" and that Intl, the Prisma CLI and both engines actually run. The base has no Node, so this one is not shadowing anything.
# -------------------------------------------------------------------------------------------------
COPY --from=lfweb /usr/bin/node           /usr/local/bin/node
COPY --from=lfweb /lib64/libnode.so.137   /usr/local/lib/libnode.so.137
#    RHEL's Node is a small-icu build whose ICU DATA is a separate file at a compiled-in path. Without
#    it Intl.Segmenter segfaults (the Prisma CLI hit it at start: SIGSEGV in JSSegments::Create).
COPY --from=lfweb /usr/share/node-24/icudata /usr/share/node-24/icudata
RUN ldconfig

# -------------------------------------------------------------------------------------------------
# 2. The Langfuse application trees + Prisma CLI (migrations) + the static ClickHouse migrate binary.
#    Each tree keeps its upstream /app layout so cwd-relative paths match upstream exactly:
#      /app/code/web   = web image /app    (run cwd here: node ./web/server.js)
#      /app/code/worker= worker image /app (run cwd here: node worker/dist/index.js)
# -------------------------------------------------------------------------------------------------
COPY --from=lfweb    /app                               /app/code/web
COPY --from=lfworker /app                               /app/code/worker
COPY --from=lfweb    /usr/local/lib/node_modules/prisma /app/code/prisma-cli
COPY --from=lfweb    /usr/bin/migrate                   /usr/bin/migrate

# -------------------------------------------------------------------------------------------------
# 3. VERSION-AGNOSTIC engine pins. The real engine files carry the .pnpm hash and the openssl suffix in
#    their paths/names and can move between Langfuse releases. Resolve them ONCE at build time and expose
#    STABLE symlinks, so PRISMA_*_ENGINE never needs editing on a version bump (a moved path just gets a
#    fresh symlink at the next build). Prisma's own os-release detection would look for a debian engine
#    on this Ubuntu base; the upstream image carries only the "rhel-openssl-3.0.x" engines, and those
#    run fine here (glibc, OpenSSL 3), so pointing the env at them overrides the detection.
# -------------------------------------------------------------------------------------------------
RUN set -eu; mkdir -p /app/code/.engines; \
    QE="$(find /app/code/web -name 'libquery_engine-rhel-openssl-3.0.x.so.node' | head -1)"; \
    SE="$(find /app/code/prisma-cli /app/code/web -name 'schema-engine-rhel-openssl-3.0.x' -type f | head -1)"; \
    [ -n "$QE" ] && [ -n "$SE" ] || { echo "FATAL: rhel Prisma engine(s) not found"; exit 1; }; \
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
# 4b. napi-rs native modules. Retired in 0.11.0: it symlinked the "gnu" binary names to the "musl"
#     ones because the Alpine upstream shipped only musl builds. The UBI upstream ships gnu builds and
#     the node here is glibc, so the loaders pick the right file by themselves. The gate in section 5
#     still proves every napi-rs module loads.
# -------------------------------------------------------------------------------------------------

# 5. Build-time gates — prove the assembled shape on the base before shipping (deeper engine-load, DNS,
#    and live libc-isolation proofs run in the runtime smoke test).
# -------------------------------------------------------------------------------------------------
RUN echo "== gate: node + shared-library closure ==" && node --version \
 && { ldd /usr/local/bin/node /usr/local/lib/libnode.so.137 2>&1 | grep -i 'not found' && { echo 'node: unresolved libs'; exit 1; } || true; } \
 && { ldd /app/code/.engines/query-engine.so.node /app/code/.engines/schema-engine 2>&1 | grep -i 'not found' && { echo 'prisma engines: unresolved libs'; exit 1; } || true; } \
 && node -p "'node '+process.versions.node+' openssl '+process.versions.openssl" \
 && node -e "const n=[...new Intl.Segmenter('en',{granularity:'word'}).segment('hi there')].length; if(n<3) process.exit(1); console.log('Intl.Segmenter ok ('+n+' segments)')" \
 && node /app/code/prisma-cli/build/index.js --version
# Every napi-rs native module must actually LOAD under this Node. A module that does not
# load kills the worker on start, which supervisor restarts forever while reporting RUNNING.
RUN echo "== gate: napi-rs native modules load ==" && set -eu \
 && n=0; for idx in $(grep -rl --include=index.js isMuslFromFilesystem /app/code/web /app/code/worker || true); do \
      node -e "require('$idx')" || { echo "napi-rs module FAILS to load: $idx"; exit 1; }; \
      echo "loads: $idx"; n=$((n+1)); \
    done; echo "napi-rs modules loaded: $n"; [ "$n" -ge 2 ]
RUN echo "== gate: schema-engine ==" && /app/code/.engines/schema-engine --version
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
