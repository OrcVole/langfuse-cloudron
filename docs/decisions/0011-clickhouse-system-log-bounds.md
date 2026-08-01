# 11. Bound the bundled ClickHouse's system logs

Date: 2026-08-01

## Status

Accepted. Ships in v0.2.1.

## Context

The bundled ClickHouse writes its internal telemetry (`query_log`, `trace_log`, `part_log`,
`metric_log` and friends) into its own store, and this package configured no retention for any of it.
Measured on the production install after five weeks of near-idle uptime:

- application data (`default` database): **144 rows, 19.7 kB**
- system telemetry (`system` database): **176 million rows, 3.9 GB, roughly 222 000 files**

Three separate costs, all measured rather than reasoned:

1. **Disk and backup weight.** The v0.2.0 store migration moved fifty times more telemetry than data,
   and every `backupCommand` run pays a transient full copy of it.
2. **Memory starvation.** The parts metadata for those tables pinned the server's tracked memory above
   ADR 0005's absolute 2 GiB cap (RSS 3.5 GiB observed), at which point every aggregating query fails
   with `MEMORY_LIMIT_EXCEEDED`. The Langfuse UI's analytics were failing on production while the app
   reported healthy. A restart does not clear it: boot reloads the same metadata.
3. **Continuous CPU.** The tables are merged constantly: `clickhouse-server` was observed at 4.5 to
   7.8 cores on an instance serving no traffic, the largest single consumer on its host.

The sibling Laminar package hit the identical mechanism, shipped the fix first (its ADR 0012), and
deployment-tested it, including two traps this ADR inherits: disabling a table does not reclaim its
data, and adding a TTL renames the existing table to `<name>_0` rather than applying retroactively.

## Decision

In `conf/clickhouse/config.d/cloudron.xml`:

- **Disable** (`remove="1"`) the ten telemetry tables an operator of this package never reads:
  `trace_log`, `text_log`, `part_log`, `metric_log`, `asynchronous_metric_log`, `query_metric_log`,
  `processors_profile_log`, `asynchronous_insert_log`, `latency_log`, `opentelemetry_span_log`.
- **Keep, bounded to three days**, the two an operator does read when debugging: `query_log` and
  `error_log` (`event_date + INTERVAL 3 DAY DELETE`).

The element set was enumerated on this image's ClickHouse 25.3 via `system.tables`, not copied from
Laminar's 25.12: the sets differ (25.3 has `latency_log` and `opentelemetry_span_log`; 25.12 has a
`background_schedule_pool_log` that 25.3 does not), and a wrong element name fails silently, so
absence from `system.tables` after a restart is the only acceptable verification.

**Updating an existing install requires a one-time cleanup, performed together with the deploy and
never deferred.** Disabling does not reclaim: the removed tables' parts stay on disk, and on the first
boot with the new config the server re-opens the backlog and merges it (on Laminar this held 1.2 GiB
of the cap and pushed the health endpoint from 0.03 s to 26 s until the data was dropped). The
cleanup is `DROP TABLE IF EXISTS system.<name> SYNC` for each removed table plus the `query_log_0`
and `error_log_0` renames. The recipe lives in `docs/KNOWN-ISSUES.md`.

## Consequences

- The store becomes proportional to the application data it holds. On production that is megabytes,
  not gigabytes; the `backupCommand` transient copy shrinks by the same factor.
- The 2 GiB cap (ADR 0005) stops being consumed by telemetry metadata, which restores the analytics
  UI and un-sharpens ADR 0009's open question about whether a leg-3 rebuild fits under the cap at
  production scale — the realistic production dump is now small.
- Three days of `query_log`/`error_log` remain for debugging; deeper forensics on a longer window are
  gone, accepted deliberately for a single-tenant embedded server.
- The gate for this change on an existing install is behavioural, not cosmetic: removed tables absent
  from `system.tables`, aggregating queries succeeding again, and CPU at rest an order of magnitude
  lower.
