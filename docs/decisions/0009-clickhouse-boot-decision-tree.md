# 9. The boot decision tree for the relocated ClickHouse and MinIO stores

Date: 2026-07-31

## Status

**Accepted, scheduled for v0.2.0.** Implements the boot side of
[ADR 0006](0006-clickhouse-backup-persistentdirs-triplet.md) and invokes
[ADR 0008](0008-clickhouse-store-migration.md).

## Context

Once the stores live in `persistentDirs`, `start.sh` can be entered in five materially different states,
and three of them look identical from inside the container. Getting this wrong does not produce an error;
it produces an app that starts happily on the wrong data. So the legs are enumerated here rather than left
to be inferred from the script.

A `restoreCommand` is also declared, ported from Laminar. The boot tree is the belt to its braces, and it
is the belt that carries the load: a `restoreCommand` cannot distinguish an in-place restore from an
ordinary restart, and it does not run at all on a plain boot. Following ADR 0005's doctrine, one script
owns every leg.

## Decision

`start.sh` evaluates these in order, after ownership fixing and before handing off to supervisord.

| Leg | Detection | Action |
|---|---|---|
| **0. Migration pending or resuming** | `/app/data/clickhouse/store` exists, or `<persistentDir>/.migration-in-progress` exists | Run or resume the migration of [ADR 0008](0008-clickhouse-store-migration.md). Do not start ClickHouse until it verifies. |
| **1. Update, the normal case** | `<persistentDir>/store` or `/metadata` present, no migration marker | Normal start. Nothing to do. |
| **2. In-place restore** | Indistinguishable from leg 1 at boot | Normal start, on the preserved and possibly newer store. Log a line naming both the dump's timestamp and the store's, so the boot log records the divergence even though the package does not act on it. |
| **3. Clone, fresh install from a backup, or an operator-cleared store** | `<persistentDir>` empty **and** `/app/data/clickhouse-backup` exists | Rebuild through a transient `clickhouse-server`. See below. |
| **4. Genuinely fresh install** | `<persistentDir>` empty and no dump present | Start clean. The web wrapper's `clickhouse/scripts/up.sh` migrations create the schema. |

MinIO follows the same shape with a shorter tree: migrate if the legacy path is present (leg 0), restore
from `/app/data/minio-backup` if `/var/lib/minio` is empty and a backup copy exists (leg 3), otherwise
start.

### Leg 3, the rebuild, is the leg that is never exercised until it is needed

**The only operation that starts a `persistentDir` empty is a clone.** An update preserves it and an
in-place restore preserves it, so a gate that only tests backup and in-place restore will pass while this
leg is broken. It is therefore a first-class gate item, not an afterthought.

Two constraints, both proven on Laminar and both counter-intuitive:

- **Restore through a transient `clickhouse-server`, never `clickhouse local`.** A `clickhouse local`
  RESTORE omits the implicit `default` database metadata and Atomic-UUID layout, and the real server then
  crash-loops with `Code 48: Data directory for default database exists, but metadata file does not`.
  Worse, another `clickhouse local` can read that broken store, so a gate that verifies with
  `clickhouse local` passes while production fails.
- Start the transient server in the background, **not** with `--daemon`, which conflicts with the console
  logger. Wait for `/ping`, issue
  `RESTORE DATABASE default FROM File('clickhouse-backup') SETTINGS allow_different_table_def=1,
  allow_different_database_def=1`, then shut it down cleanly. **Both settings are required**:
  `table_def` for views whose dictionary references ClickHouse re-normalises, `database_def` for the
  database-level UUID mismatch against the server's auto-created `default`.

Verify with real analytics queries and `/api/public/traces`, not `SELECT count()` on a base table.
`allow_different_table_def=1` re-normalises view dictionary references, and a wrong reference yields wrong
aggregates while base counts still look correct.

### Health during a long rebuild, and during a long migration

Langfuse's health check is `/api/public/health` on the Next.js web process, which does not start until the
wrappers' readiness gates pass. A long leg 0 migration or leg 3 rebuild therefore leaves the app failing
its health check, which invites the platform to restart the container in the middle of the very operation
that must not be interrupted.

**The mitigation is to make interruption harmless rather than to try to prevent it.** Leg 0 is already
resumable by construction ([ADR 0008](0008-clickhouse-store-migration.md)). Leg 3 must be made resumable
the same way: the rebuild runs against an empty `persistentDir`, so a restart mid-rebuild simply finds it
empty or partial and starts again, provided the leg treats a partially populated store as "not done". Use
the same marker discipline, `.rebuild-in-progress` written before the transient server starts and removed
only after a clean shutdown, and treat a `persistentDir` carrying that marker as empty.

**Still to measure:** how long a rebuild actually takes against a realistic dump, and **whether it
completes at all**. The second half of that question is sharper than it first looked. The transient
server runs under the same absolute `max_server_memory_usage` cap of 2 GiB as the real one (ADR 0005
sets it absolute rather than as a ratio, because it is unverified whether the bundled ClickHouse reads
the cgroup limit or host RAM). During gate loading on a throwaway, sustained ingest drove ClickHouse
into that ceiling hard enough that even `SELECT count() FROM traces` failed with
`Code: 241 ... MEMORY_LIMIT_EXCEEDED`. A RESTORE of a multi-gigabyte dump has the same 2 GiB to work
in.

So the rebuild must be measured at the **largest plausible store**, not a convenient one, and the
measurement must be recorded rather than estimated. If it turns out the cap is the binding constraint,
the options are to raise it for the transient server only (it is a separate process with a separate
config) or to restore in stages.

### Signal handling

`start.sh` is PID 1 during legs 0 and 3, and PID 1 gets no default signal dispositions, so a platform stop
would be ignored until `SIGKILL`. Install a `TERM`/`INT` trap that forwards to the child and waits. Since
both long legs are resumable, the trap turns an ugly stop into a clean one rather than being load-bearing
for correctness.

### Ownership

Create and chown `<persistentDir>/{logs,tmp,access,user_files,format_schemas}` on every boot, because a
restore drifts ownership. Use Laminar's cheap-chown pattern, a full recursive chown only when the
top-level owner has drifted, so that an ordinary boot does not walk a multi-gigabyte store to re-assert
what is already true.

## The in-place restore trap, stated plainly

`persistentDirs` are **preserved** by an in-place restore. So an operator restoring Langfuse to last
Tuesday gets last Tuesday's Postgres and last Tuesday's ClickHouse dump file, and **today's** ClickHouse
store, silently. Leg 2 logs the divergence but deliberately does not act on it, because acting on it would
mean destroying a live store on the strength of a guess about operator intent.

This is the one place where the v0.2.0 design is **worse** than v0.1.0's raw-files-in-`/app/data`
behaviour, and it must not be discovered by a user in anger. It ships with:

- a loud paragraph in `POSTINSTALL.md` and `docs/KNOWN-ISSUES.md`;
- a documented operator recipe: to make an in-place restore actually restore ClickHouse, complete the
  restore, stop the app, clear `/var/lib/clickhouse`, and start it, at which point leg 3 rebuilds from the
  restored dump;
- leg 3 itself, which is what makes that recipe work.

## Consequences

- Five legs is more boot logic than v0.1.0 had, and boot logic is hard to test. Each leg must be
  individually reachable in the gate, which is why the gate includes a clone (leg 3) and an operator-
  cleared store (also leg 3) as separate exercises.
- Legs 1 and 2 are genuinely indistinguishable. The design accepts that and documents it rather than
  inventing a heuristic that would be wrong occasionally and silently.
