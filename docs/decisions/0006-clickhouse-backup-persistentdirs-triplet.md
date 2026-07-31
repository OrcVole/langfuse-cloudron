# 6. ClickHouse backup: move the store to a persistentDir + logical dump (Cloudron 9.1 triplet)

Date: 2026-06-30

## Status

**Accepted — recipe now PROVEN on a sibling package; scheduled for Langfuse v0.2.0 (not yet built here).**
v0.1.0 ships unchanged with an operational workaround ([KNOWN-ISSUES.md](../KNOWN-ISSUES.md)) and the
upstream bug report ([upstream-cloudron-backup-syncer-race.md](../upstream-cloudron-backup-syncer-race.md)).

The two box-authority unknowns this ADR flagged ("settle at the start of v0.2.0") were settled **on the box**
by the **Laminar** package (`io.github.orcvole.laminar`), which built and validated this exact triplet for
its bundled ClickHouse — Laminar **ADR 0007** (the CH triplet) and **ADR 0011** (multi-store capture skew),
validated 2× under write load. The resolved answers + the proven recipe are folded in below, replacing the
"study Plausible / verify on a live box" placeholders. **The dump/restore recipe ports verbatim. The
persistentDir RELOCATION does NOT** — Langfuse is already published with ClickHouse under `/app/data`, so
v0.2.0 must add a one-time in-place migration (new "Migration" section) that Laminar, being greenfield,
never needed. Recipe-proven ≠ this-package-gated: Langfuse's v0.2.0 still earns its OWN backup→restore gate,
with the migration as a first-class gate item.

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
- **`backupCommand`** — **snapshot the live store to an unlocked copy, then logical-dump from the copy**
  into `/app/data` (which *is* backed up). The snapshot is NOT optional — the live server holds an flock the
  temp container collides with (resolved unknowns below). Atomic `.new`→rename.
- **`restoreCommand`** — repopulate the empty `persistentDir` from that dump **before** the app starts, via
  a **transient `clickhouse-server`** (NOT `clickhouse local` — its restore output is not server-startable;
  see below).

This **completes** the data-layer architecture for a stateful analytical app on box ≥ 9.1. ClickHouse
data stays captured and restorable; only the capture mechanism changes
(raw-files-under-`/app/data` → dump-and-restore). It does **not** move data outside the backup surface.

Deferred to v0.2.0 (semantic versioning) as its own phase because it is a real data-layer
re-architecture that earns its own backup→restore acceptance gate — not a point patch on the published,
gate-complete v0.1.0.

## Two box-authority unknowns — RESOLVED on the box (Laminar)

Both were settled empirically by Laminar's CH triplet (ADR 0007), validated 2× under load. The answers
contradict the intuitive design, so port them exactly:

- **(a) The live app is NOT quiesced.** The app + its ClickHouse keep running while `backupCommand`'s temp
  container runs (separate container; Cloudron will not back up a *stopped* app). So a plain dump is racy,
  AND a direct `clickhouse local --path=<persistentDir>` **fails even at idle**: the live server flocks
  `<store>/status` and that inode is shared across the bind mount, so `clickhouse local` collides —
  `Code 76, CANNOT_OPEN_FILE: Cannot lock file …/status`. There is no lock-skip flag. **Fix: dump from a
  COPY.** `rsync -a --delete --exclude=/status --exclude=/tmp/ --exclude=/shadow/ --exclude='tmp_*'` the
  store to `/app/data/.ch-snapshot`, then dump from the snapshot. (MergeTree parts are immutable and linger
  `old_parts_lifetime` ~8 min, so a copy finishing in that window is coherent; rsync tolerates a vanishing
  part, exit 24.) The snapshot is built + deleted inside `backupCommand` — never archived.
- **(b) `clickhouse local` runs in the temp container (binary present) and dumps fine — but its RESTORE
  output is NOT server-startable.** A `clickhouse local` RESTORE omits the implicit `default` database
  metadata / Atomic-UUID layout, so the real `clickhouse-server` then crash-loops with
  `Code 48: Data directory for default database exists, but metadata file does not`. The store is still
  readable by *another* `clickhouse local` (lenient) — which is exactly how an idle gate that restores via
  `clickhouse local` **masks** this; it surfaces only when the real server boots. **Fix: restore via a
  TRANSIENT `clickhouse-server`** (background, NOT `--daemon` — that conflicts with the console logger) on
  the empty `persistentDir`, RESTORE through it, then clean-shutdown.

**Proven recipe (verbatim-portable):**
- Backup: `clickhouse local --path=<snapshot> --config-file=backups.xml --query="BACKUP DATABASE default
  TO File('…')"`. **`DATABASE default`, NOT `BACKUP ALL`** — `ALL` trips on `system.users` access entities
  (`ACCESS_STORAGE_DOESNT_ALLOW_BACKUP`); user accounts come from `users.d` config at boot.
- Restore (through the transient server): `RESTORE DATABASE default FROM File('…') SETTINGS
  allow_different_table_def=1, allow_different_database_def=1`. **Both** are required — `table_def` for
  views whose dict refs CH re-normalizes to `default.`-qualified (`CANNOT_RESTORE_TABLE` otherwise),
  `database_def` for the db-level UUID mismatch restoring into the server's auto-created `default`
  (`CANNOT_RESTORE_DATABASE`, Code 607).
- `<backups><allowed_path>/app/data</allowed_path></backups>` in `config.d` so File backups are sandboxed
  there. Operational cost: the snapshot is a full cross-volume copy → `/app/data` needs free space ≥ the CH
  store size during a backup.

**Langfuse captures >1 store on different mechanisms → bias the skew (Laminar ADR 0011).** Postgres
(addon-dump), ClickHouse (`backupCommand`), and MinIO (file-walk) are captured at three different instants;
under load they diverge. Measure the actual order on the box (clone an under-load backup, compare each
store's cut — do NOT infer it from manifest field order) and ensure the residual is benign in the
foreign-key direction: a media blob (MinIO) referenced by a trace/observation row (PG/CH) must be captured
**no earlier** than the row, or a restored row points at a missing blob.

## Consequences — scope (files v0.2.0 will touch)

- **`CloudronManifest.json`** — add `persistentDirs` (`["/var/lib/clickhouse", "/var/lib/minio"]`, see
  Decision M below), `backupCommand`, `restoreCommand`; bump `version` → `0.2.0`. `minBoxVersion` is
  already `9.1.0`.
- **`AGENTS.md`** — golden rule 3 ("Persisted state ONLY in `/app/data`") is deliberately broken by this
  ADR and must be amended in the same change, or the build contradicts its own working contract.
- **`conf/clickhouse/config.d/cloudron.xml`** — repoint `<path>`, `<tmp_path>`, `<user_files_path>`,
  `<format_schema_path>`, and the access path from `/app/data/clickhouse/…` to the `persistentDir`
  (logs may stay under `/app/data` or move — not backup-critical).
- **`start.sh`** — `mkdir -p` + `chown` the `persistentDir` every boot (it currently makes/chowns
  `/app/data/clickhouse`); keep re-asserting ownership/mode post-restore.
- **new `conf/backup-clickhouse.sh` + `conf/restore-clickhouse.sh`** — referenced by the manifest
  commands (already in the image, so reachable from the temp container).
- **MinIO also moves to a `persistentDir` (Decision M).** This reverses the original position that MinIO
  "has no merge-temp churn" and stays put, which was an assumption rather than a measurement. Measured on
  the box 2026-07-31 (`phase-notes/phase-1-findings.md`):
  - MinIO's whole tree is **103 918 bytes across 102 files**, against ClickHouse's **4.17 GB across
    221 865 files**, a ratio of roughly 40 000 to 1. The copy is therefore free, and the earlier estimate
    that Decision M would roughly double the work in `backupCommand` was wrong because it assumed MinIO
    was large.
  - MinIO does churn, though not from ingestion. `.minio.sys/tmp` held 50 entries at one sample and 2 at
    the next, and the scanner rewrites `.usage-cache.bin`, `.usage.json` and their `xl.meta` children
    through the same write-temp-then-rename path the syncer trips over. Small, but the same shape as the
    defect being fixed.
  - So: `persistentDirs` becomes `["/var/lib/clickhouse", "/var/lib/minio"]`, the supervisor command
    points MinIO at the new path, and `backupCommand` copies it to `/app/data/minio-backup` with the same
    `rsync -a --delete` plus `.new`-then-rename pattern. Migration follows ADR 0008 and is easier there,
    because MinIO's single-drive layout is a plain file tree.
  - **Caveat, recorded so it is not lost:** MinIO has received no new object since install day
    (2026-06-26) even though ClickHouse kept ingesting, which is not the documented Langfuse v3 data path
    and may itself be a defect. If event uploads are later fixed, MinIO's churn rises from bookkeeping
    cadence to ingestion cadence and Decision M stops being cheap insurance and becomes necessary. That
    is a Langfuse-behaviour question and must not be allowed to delay v0.2.0.

## Migration — the already-shipped trap (greenfield ≠ published)

Laminar carried the `persistentDir` from its FIRST published version, so a fresh install just starts empty
there — no migration. **Langfuse cannot: v0.1.0 already shipped ClickHouse as raw files under
`/app/data/clickhouse`.** On UPDATE to v0.2.0 the new `persistentDir` `/var/lib/clickhouse` is created EMPTY
while the user's history sits at the old path. If `start.sh` simply points ClickHouse at the empty
persistentDir, **every existing user's analytics history is orphaned on update** (still on disk, but unused)
— silent data loss.

**Required: a guarded, one-time, in-place migration in `start.sh`, BEFORE `clickhouse-server` starts.**
The mechanism is specified in full by **[ADR 0008](0008-clickhouse-store-migration.md)**, which supersedes
the sketch this ADR originally carried. See the History note at the foot of this file for what changed and
why.

The property worth keeping from the original sketch, because it is free: **the same guard also covers
restoring a PRE-migration (v0.1.0) backup onto v0.2.0.** A legacy backup restores raw files to
`/app/data/clickhouse`, the guard fires on the next boot, and the data lands in the right place, so a
v0.1.0 backup is forward-restorable with no special case in `restoreCommand`. The same one-time-relocation
pattern is required for ANY future move of an already-shipped store, including MinIO under Decision M
below.

## Acceptance gate (mirrors Gate 3 — non-negotiable; run UNDER WRITE LOAD, 2–3×)

A real **backup → real restore** round-trip on the box, **with ingestion/writes ACTIVE** — an idle run masks
the torn-copy, the flock (Code 76), and the not-server-startable-restore (Code 48); all three only surfaced
on Laminar under load / on a real server boot. In it:

- **`ENCRYPTION_KEY` is byte-identical** across backup and restore (data-loss guard).
- **Data is intact**: Postgres + the now-dump-restored **ClickHouse** (restored via the transient server) +
  MinIO. Verify ClickHouse with **real analytics queries / `/api/public/traces`**, not just `SELECT count()`
  on a base table — `allow_different_table_def` re-normalized the view dict refs, and a wrong ref yields
  wrong aggregates while the base count still looks fine.
- Ownership/mode **`0600 cloudron`** re-asserted post-restore.
- A **whole-server backup run no longer aborts on Langfuse** — the race is structurally gone
  (`store/<uuid>/` out of the walked tree); confirm `/var/lib/clickhouse` is excluded from the file-walk.
- **MIGRATION (both paths):** (1) update a data-ful **v0.1.0** install in place → v0.2.0 → history survives
  (the guarded `start.sh` move ran once); (2) restore a **v0.1.0-era** backup onto v0.2.0 → same. Neither
  orphans data at the legacy `/app/data/clickhouse`.
- **Cross-store skew:** measure the PG/CH/MinIO capture order under load; confirm no restored row references
  a media blob absent from the restored MinIO (ADR-0011 direction).

## Decision N — the nightly upload cost, now measured rather than guessed

**The syncer compares metadata, not content.** Read from the rig's own `box/src/syncer.js` on
2026-07-31:

```js
if (entryStat.mtime.getTime() !== cacheStat.mtime || entryStat.size != cacheStat.size
    || entryStat.inode !== cacheStat.inode) {   // file changed
```

A `sha256` integrity value is recorded per file, but it is used only to notice a *missing* integrity
record, never to decide whether a file changed. So there is no content-addressed dedupe to lean on.

**Consequence, and it is unwelcome.** `backupCommand` publishes the dump atomically via
`.new`-then-rename. That changes every file's mtime **and** inode, so on the next run every file in
the ClickHouse dump is classified `changed` and re-uploaded. The backup destination is a Hetzner
Storage Box over SSH measured at **1 to 3 MB/s**, so a multi-gigabyte dump is tens of minutes added to
this app's slot, every night, forever.

This is a performance decision, not a correctness one, and it does not block v0.2.0. The options, for
whoever picks it up:

1. **ClickHouse incremental backups** (`SETTINGS base_backup=File('…')`), so each run writes only new
   parts. This is the real fix. It costs a retention policy for the base backup chain, which is a
   genuine design question rather than a switch.
2. **Drop the atomic publish** so unchanged files keep their inode and mtime. Rejected: a failed or
   killed backup would then corrupt the published dump, trading a bounded performance cost for an
   unbounded correctness one.
3. **Accept it.** Defensible while the store is small, and it is at least *bounded* and predictable,
   unlike the defect being fixed.

Do not treat option 1 as free before measuring: a full `BACKUP` of a MergeTree writes each part's data
regardless, so the saving depends on how much of the store is genuinely new between runs.

**The uncomfortable part, stated plainly: on upload cost alone, v0.1.0's raw files were BETTER.**
MergeTree parts are immutable and uniquely named. A merge adds new part files and removes old ones,
but it never rewrites a file in place, so a raw-files backup presents the syncer with exactly the
input its mtime-size-inode comparison handles well: most files are byte-for-byte unchanged with
unchanged metadata, and only genuinely new parts upload. Observed while taking a v0.1.0-era backup of
a throwaway during this work: the walk enumerated 9 739 files, and on a second run the great majority
would be skipped.

Version 0.2.0 replaces that with a single atomically-republished dump, every file of which looks new
every night. **So the relocation trades nightly upload cost for correctness.** That trade is still
plainly worth making, because the cost being removed is "this app aborts the whole rig's backup run
and every application scheduled after it silently keeps a stale backup", and the cost being added is
minutes of upload. But it should be recorded as a real trade rather than presented as a pure win, and
it is the strongest argument for pursuing option 1 once v0.2.0 is stable.

## History

**2026-07-31 — the `mv` migration sketch is withdrawn, and MinIO's position is reversed.**

This ADR originally specified the migration inline as `mv /app/data/clickhouse/* /var/lib/clickhouse/`
guarded on "legacy present and persistentDir empty". That sketch must not be built, for two reasons found
this session, one of them measured rather than reasoned:

1. **It is not atomic and not fast.** Cloudron 9.2.0 bind-mounts a `persistentDir` from
   `/home/yellowtent/platformdata/persistent/<appid>/<path-with-underscores>`, which is on the *same* ext4
   filesystem as `/app/data` and reports the same `st_dev` inside the container, but is a *separate mount*.
   Linux refuses `rename(2)` across mount points regardless of the underlying filesystem. Proven on a
   throwaway install: `os.rename` returns `EXDEV` (errno 18), and `mv` silently falls back to copy-then-
   unlink, with the inode changing (3034425 becomes 6071004). So the sketch is a multi-gigabyte byte copy
   dressed as a rename, and it takes wall-clock time proportional to the store.
2. **Its guard does not survive interruption.** A copy that dies half way leaves `/var/lib/clickhouse`
   non-empty, so the guard never fires again and the app boots on a partial ClickHouse store. That is
   silent corruption, not a clean failure. It also deleted the legacy tree before anything had shown the
   new one worked.

Replaced by **[ADR 0008](0008-clickhouse-store-migration.md)** (resumable copy, in-progress marker,
byte-and-count verification, deletion only after proven health) and **[ADR 0009](0009-clickhouse-boot-decision-tree.md)**
(which boot leg does what). The evidence sits in `phase-notes/phase-1-findings.md`.

The MinIO position ("stays under `/app/data`, no merge-temp churn") was also an assumption and is reversed
by Decision M above on measured evidence.
