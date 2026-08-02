# 7. Langfuse v3 to v4 major upgrade, with ClickHouse 25.3 to 26.4, as one round

Date: 2026-08-03 (supersedes the placeholder reserved 2026-06-30)

## Status

Accepted. Ships in v0.3.0.

## Context

Langfuse v4 (4.0.0 released 2026-07-29; we ship 4.2.0) requires ClickHouse >= 25.12, with 26.4
recommended. This package bundled 25.3, so the upstream-documented path is two independently stable
steps: upgrade ClickHouse while still on v3, then upgrade the server. The operator chose to take both
in one round, gated on the fleet's only real canary (`langfuse-test`, auto-update on; production off).
The cost of combining, accepted explicitly: a gate failure would not attribute to one half, and the
rollback is both halves at once (0.2.1, digest recorded in the fleet registry).

PostgreSQL (16.13) and Redis (8.4.0), both Cloudron addons, already cleared v4's floors.

## Decisions

**The single-ARG build shape survives v4 unchanged.** The v4 web/worker images keep node:24-alpine,
the same musl engine paths, the same /app layout, and the same migration scripts, so the S2
musl-in-place shape (ADR 0002) needed nothing but new pins. One wrinkle: upstream never published
4.2.0 images to Docker Hub (it stops at 4.1.0); 4.2.0 exists only on ghcr.io, so the web and worker
pins moved registries.

**ClickHouse target is 26.4** (upstream's recommendation), not the 25.12 floor and not 26.3 LTS.
Going straight to the recommended version avoids a second datastore bump when v4 features start
assuming it. The 26.4 element set for the system-log bounds (ADR 0011) was re-enumerated on the
pinned image: latency_log is gone; histogram_metric_log and background_schedule_pool_log are new and
disabled; the remaining active-by-default log elements are now disabled wholesale, keeping only
query_log/error_log (TTL 3 days) and crash_log (writes only on a crash, and is what an operator
reads after one).

**Write mode is pinned to `dual`, OTel behaviour to `dual_write`.** The v4 code defaults
(events_only / direct) reject ingestion from Python SDK <= 2 and JS SDK <= 3 and hide native-OTel
writes from the default read path. Existing installs have consumers of unknown vintage, so the
package pins the safe posture: every v3 surface keeps working, new events tables converge in the
background (historic backfill on, upstream default). The cutover to events_only is per-install
operator policy, exercised through the new `/app/data/env.sh` (sourced last on every boot), not
through a package release.

**Memory was re-measured, as ADR 0005 required.** v4's web does not boot in 768 MB of Node heap
(FATAL mark-compact OOM crash-loop, caught by test/ingest.sh locally); it gets 1536 MB. ClickHouse
26.4's RSS-based accounting breached the absolute 2 GiB cap at near-idle on a 32-core host, killing
every query; the cap is now 2.5 GiB. manifest memoryLimit moves 5 GiB to 6 GiB.

**backups.xml inverted (the gotcha 108 fix became the defect).** On 25.3, `clickhouse local` needed
a `default_database` override to load a store carrying explicit metadata/default.sql (Code 82). On
26.4 that same override causes Code 57 TABLE_ALREADY_EXISTS (table-UUID collision); without it, 26.4
loads the store cleanly. Reproduced in both directions on a minimal one-table store against the
pinned binary. The override is removed; the file carries the history.

## Gate evidence (2026-08-02/03, all on the box unless noted)

- Local suite (podman, 32-core host): smoke, ingest, backup-restore, migration all PASS after the
  three fixes above; the suite caught all three defects before any box install was touched.
- Clone of the canary's fresh 0.2.1 backup: byte-faithful (2373 traces, cityHash64 fingerprint
  11026962476872948669, ENCRYPTION_KEY sha256 identical).
- Update 0.2.1 -> 0.3.0 over that data: ClickHouse opened the 25.3 store as 26.4.5.143, v4
  migrations created events_core/events_full/events_core_mv, all 2373 traces intact by fingerprint,
  health 200.
- v4 behaviour: historic backfill converted all 2373 traces into events_full; a legacy-format
  ingestion POST returned 207, landed in the v3 traces table immediately and converged into
  events_full via the partition-based dual-write job (upstream's design: convergence is
  asynchronous, not per-event).
- Backup at 0.3.0 -> clone: restore ran through the 26.4 transient server; source and clone both at
  2374 traces, fingerprint 2012295329645041242 on both, key hash identical.
- Residue on updated installs: query_log_0 (TTL re-rename under 26.4's serialisation) and
  backup_log (created by the rebuild server under the pre-0.3.0 config), tens of KB; optional
  cleanup documented in KNOWN-ISSUES.md. No boot-path DROP: the 0.2.1 round already cleared the
  gigabyte-scale backlog, so the #123 merge-storm precondition does not exist here.

## Consequences

- Round B's remaining scope is exactly one decision per install: when to flip
  LANGFUSE_MIGRATION_V4_WRITE_MODE to events_only. Gating artifact: the consumer/SDK inventory,
  which still does not exist.
- The dump/restore recipe (ADR 0006) survives the major with the backups.xml change; restores of
  0.2.x-era dumps through the 26.4 transient server are covered by the update gate having restored
  a 25.3-era store in place.
- Production (`langfuse`) stays on 0.2.1 with auto-update off until 0.3.0 has soaked on the canary.
