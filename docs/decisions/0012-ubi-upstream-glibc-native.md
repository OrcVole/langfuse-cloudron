# 12. Upstream moved to UBI 9: the musl-in-place shape is retired

Date: 2026-10-16

## Status

Accepted for 0.11.0 (langfuse 4.62.0 on cloudron/base 6.0.0). Supersedes the build shape of ADR 0002.
Runtime proof beyond the local smoke and ingest suites is owed on the Proving Ground (gate 3).

## Context

Langfuse 4.55.0 (PR 18009, "zero vuln base images and fips mode") moved both official images from
`node:24-alpine` to Red Hat UBI 9 micro. Measured against 4.62.0: glibc 2.34, `/usr/bin/node` is a
30 KB launcher for `/lib64/libnode.so.137` (Node 24.21.0, OpenSSL 3.5), and the only Prisma engines are
`rhel-openssl-3.0.x`. There is no `/lib/ld-musl-x86_64.so.1`, no `libstdc++` under `/usr/lib` and no
musl engine, so every `COPY --from` in the old section 1 failed. cloudron/base 6.0.0 has no Node.js
either.

## Decision

Run the upstream Node and engines on the base's glibc (2.43, backward compatible with 2.34). Copy
`/usr/bin/node` and `libnode.so.137` only; libssl, libcrypto, libstdc++, libgcc_s and libz come from
the base. Delete the musl loader, `/opt/musl/lib`, `/etc/ld-musl-x86_64.path`, the `node-musl` name and
the napi-rs gnu-to-musl symlinks. Keep the build-time `ldd` gates, now covering node, libnode and both
Prisma engines.

## Consequences

- Smaller moving parts, no libc isolation to defend. smoke.sh check 5 now asserts that nothing maps musl.
- A future upstream change of base (for example Iron Bank Alpine FIPS images, reverted once already in
  PR 18449) will fail the `ldd` or engine-discovery gates at build time, not at runtime.
- The base's glibc Node is gone with base 6; the package never used it.
