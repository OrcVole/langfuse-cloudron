# 6. ClickHouse backup: move the store to a persistentDir + logical dump (Cloudron 9.1 triplet)

Date: 2026-06-30

## Status

**Accepted — scheduled for v0.2.0 (not yet built).** v0.1.0 ships unchanged with an operational
workaround ([KNOWN-ISSUES.md](../KNOWN-ISSUES.md)) and the upstream bug report
([upstream-cloudron-backup-syncer-race.md](../upstream-cloudron-backup-syncer-race.md)). This ADR
records the decision and scope now; the build is a deliberate, gated phase, not a patch on v0.1.0.

## Context

Today the bundled ClickHouse store is raw files under `/app/data/clickhouse`, captured by Cloudron's
filesystem (rsync) backup. Gate 3 proved that captures and restores correctly in the normal case.

A backup run was then observed to **abort the whole server's backup** intermittently: the rsync
syncer's tree walk (`readTree` in `box/src/syncer.js`) recursed into a ClickHouse merge-temp directory
(`store/<uuid>/tmp_merge_*`) that had vanished mid-walk — a merge finalised by atomic rename — got
`null`, and a `.sort()` on that `null` threw, aborting the entire task. Backups run with the app live,
so this transient churn is constant and legitimate. Root cause is platform-side (filed upstream).

The intuitive package-side fix — quiesce merges around the snapshot with `SYSTEM STOP MERGES` …
`SYSTEM START MERGES` — is **impossible on Cloudron**:

- There is **no live-container pre/post-backup hook**. Cloudron staff explicitly declined generic
  pre/post-backup hooks (forum topic 8367, closed 2026-03-16) and directed packagers to
  `backupCommand`/`restoreCommand`.
- `backupCommand`/`restoreCommand` run in a **separate temporary container** (`docker run` on the app
  image with `/app/data` + `persistentDirs` bind-mounted), so they **cannot signal the live ClickHouse**.
- There is **no post-backup hook**, so a boot-time `SYSTEM START MERGES` self-heal has nothing to pair
  with — it would be dead code for this purpose.

(See the `cloudron-no-live-backup-hook` finding for the multi-source evidence.)

The constraint that actually matters is **not** "keep the raw files in `/app/data`" — it is that
ClickHouse data must remain **inside Cloudron's backup/restore surface** (captured and restorable, with
the byte-identical-`ENCRYPTION_KEY` guarantee intact). A logical dump preserves that; it changes the
*mechanism*, not the *goal*.

## Decision

Adopt the Cloudron **9.1 backup triplet** for ClickHouse in **v0.2.0**:

- **`persistentDirs`** — move the ClickHouse store out of `/app/data` (e.g. to `/var/lib/clickhouse`).
  `persistentDirs` are **excluded from the filesystem backup walk**, so the `tmp_merge_*` transients are
  no longer in the walked tree → **the race is structurally gone, independent of any upstream syncer
  patch.**
- **`backupCommand`** — produce a **consistent logical dump** of ClickHouse into `/app/data` (which *is*
  backed up).
- **`restoreCommand`** — repopulate the `persistentDir` from that dump **before** the app starts.

This **completes** the data-layer architecture for a stateful analytical app on box ≥ 9.1. ClickHouse
data stays captured and restorable; only the capture mechanism changes
(raw-files-under-`/app/data` → dump-and-restore). It does **not** move data outside the backup surface.

Deferred to v0.2.0 (semantic versioning) as its own phase because it is a real data-layer
re-architecture that earns its own backup→restore acceptance gate — not a point patch on the published,
gate-complete v0.1.0.

## Two box-authority unknowns — settle these at the START of v0.2.0

Not answerable from docs; verify on a live box before designing the dump.

- **(a) Is the live app quiesced while `backupCommand`'s temp container runs** against the shared
  `persistentDir`? If **not**, concurrent live writes make a plain copy/dump racy and we need a
  ClickHouse-native consistent export (`ALTER TABLE … FREEZE` / `BACKUP …`). → decides *plain dump* vs
  *snapshot-then-dump*.
- **(b) Can `clickhouse-server` / `clickhouse-local` actually run inside the temp container?** It has
  the app image but **no running server**. → decides the dump mechanism: *transient server* vs
  *`clickhouse-local`* vs *`clickhouse-backup`*.

**Study the precedent first.** Plausible bundles ClickHouse on Cloudron; read its
`CloudronManifest.json` + backup/restore scripts **before** designing ours — it has very likely already
solved both unknowns. Matching a proven package beats inventing.

## Consequences — scope (files v0.2.0 will touch)

- **`CloudronManifest.json`** — add `persistentDirs` (e.g. `["/var/lib/clickhouse"]`), `backupCommand`,
  `restoreCommand`; bump `version` → `0.2.0`. `minBoxVersion` is already `9.1.0`.
- **`conf/clickhouse/config.d/cloudron.xml`** — repoint `<path>`, `<tmp_path>`, `<user_files_path>`,
  `<format_schema_path>`, and the access path from `/app/data/clickhouse/…` to the `persistentDir`
  (logs may stay under `/app/data` or move — not backup-critical).
- **`start.sh`** — `mkdir -p` + `chown` the `persistentDir` every boot (it currently makes/chowns
  `/app/data/clickhouse`); keep re-asserting ownership/mode post-restore.
- **new `conf/backup-clickhouse.sh` + `conf/restore-clickhouse.sh`** — referenced by the manifest
  commands (already in the image, so reachable from the temp container).
- MinIO stays under `/app/data` (object store; no merge-temp churn) unless the same review shows cause to
  move it.

## Acceptance gate (mirrors Gate 3 — non-negotiable)

A real **backup → real restore** round-trip on the box, in which:

- **`ENCRYPTION_KEY` is byte-identical** across backup and restore (data-loss guard).
- **Data is intact**: Postgres + the now-dump-restored **ClickHouse** + MinIO (read traces back via
  `/api/public/traces`).
- Ownership/mode **`0600 cloudron`** re-asserted post-restore.
- **AND**: a **whole-server backup run no longer aborts on Langfuse** — confirming the race is
  structurally gone because `store/<uuid>/` is no longer in the walked tree.
