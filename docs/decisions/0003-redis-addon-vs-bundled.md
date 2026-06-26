# 3. Redis: Cloudron addon vs bundled

Date: 2026-06-26

## Status

Accepted — use the Cloudron `redis` addon.

## Context

Langfuse's worker uses BullMQ for the ingestion queue. BullMQ requires Redis `maxmemory-policy
noeviction`: under any eviction policy, Redis can drop job/lock keys under memory pressure, causing
lost or duplicated ingestion. The Cloudron `redis` addon's policy was unverified (field-guide
gotcha 31), so the options were (a) use the addon if its policy is `noeviction`, else (b) bundle a 5th
supervised Redis with `--maxmemory-policy noeviction` (as upstream's compose does).

## Decision

**Verified on the box** (`redis-cli CONFIG GET maxmemory-policy` against a live redis-addon app):
the Cloudron redis addon runs **`maxmemory-policy noeviction`** (and `maxmemory` unset). That is exactly
what BullMQ needs, so we **use the addon** rather than bundling Redis. Langfuse's Redis usage (queue +
cache) is transient, so the addon's persistence/backup is a bonus, not a requirement.

## Consequences

- The manifest declares the `redis` addon; `start.sh` maps `CLOUDRON_REDIS_HOST/PORT/PASSWORD` →
  `REDIS_HOST/PORT/AUTH`, `REDIS_TLS_ENABLED=false`.
- The package stays at **four** supervised processes (ClickHouse + MinIO bundled; web + worker), not
  five.
- Re-verify the addon policy on the target box as a Phase-4 check — if a future box changed the default,
  BullMQ durability would silently degrade.
