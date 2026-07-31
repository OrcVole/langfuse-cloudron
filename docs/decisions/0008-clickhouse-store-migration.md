# 8. Migrating the ClickHouse and MinIO stores out of `/app/data` on an installed app

Date: 2026-07-31

## Status

**Accepted, scheduled for v0.2.0.** Supersedes the inline `mv` sketch that
[ADR 0006](0006-clickhouse-backup-persistentdirs-triplet.md) originally carried; see that file's History
note. The boot legs that invoke this migration are specified in
[ADR 0009](0009-clickhouse-boot-decision-tree.md).

## Context

[ADR 0006](0006-clickhouse-backup-persistentdirs-triplet.md) moves the ClickHouse store, and now also the
MinIO store, out of `/app/data` and into `persistentDirs`. Laminar, which proved the recipe, was greenfield:
it carried the `persistentDir` from its first published version, so a fresh install simply starts empty
there. Langfuse cannot do that. **v0.1.0 already shipped with both stores as raw files under `/app/data`**,
and there are installs holding real observability history.

On update, the new `persistentDir` is created empty while the user's data sits at the old path. If
`start.sh` merely repoints ClickHouse, every existing user's history is orphaned: still on disk, silently
unused. So a one-time relocation is mandatory, and it is the single most dangerous operation in v0.2.0,
because it happens once, on live data, with no chance to rehearse it on the install that matters.

Three facts, measured on the box 2026-07-31 (`phase-notes/phase-1-findings.md`), set the constraints:

1. **The relocation is a byte copy, always.** A `persistentDir` is bind-mounted from
   `/home/yellowtent/platformdata/persistent/<appid>/<path-with-underscores>`. It sits on the same ext4
   filesystem as `/app/data` and reports the same `st_dev` inside the container, but it is a **separate
   mount**, and Linux refuses `rename(2)` across mount points. Proven on a throwaway: `os.rename` returns
   `EXDEV` (errno 18); `mv` falls back to copy-then-unlink and the inode changes. There is no fast path.
2. **The copy is large enough to be interruptible.** ClickHouse is roughly 4.17 GB across 221 865 files on
   the production install. MinIO is 103 918 bytes across 102 files and is effectively free.
3. **Space is not a constraint.** The shared filesystem had 621 GB available of 1.27 TB, against a
   transient requirement of roughly the ClickHouse store size.

The failure that must be designed out is **silent partial migration**: a copy that dies half way leaving a
store that boots, opens, and is simply missing data.

## Decision

### The store is quiescent during the migration, and that is the whole trick

The migration runs in `start.sh` **before** supervisord starts, so `clickhouse-server` and `minio` are not
running and nothing is writing to either tree. This is a materially easier problem than the one
`backupCommand` faces against a live server, and the design leans on it: because the source cannot change,
a copy can be verified by simply re-running it.

### Two markers, not one

The original sketch had a single implicit guard ("legacy present and destination empty") which stopped
being true the moment the copy started, and therefore never fired again after an interruption. Replace it
with two explicit markers in the destination:

| Marker | Meaning |
|---|---|
| `<persistentDir>/.migration-in-progress` | A copy has started and has not been verified. Contains the source path, an ISO 8601 timestamp, and the source byte count. |
| `<persistentDir>/.migration-verified` | The copy has been verified complete. The legacy tree is now redundant and may be deleted once the app has been observed healthy. |

Splitting them separates "is the data safe" from "has the old copy been cleaned up", which are different
questions with different consequences, and it lets the cleanup happen on a later boot without re-verifying
a destination that is by then live and diverging.

### The sequence, per store

```
1. If .migration-verified exists            -> the data is already safe; skip to step 7.
2. Guard: source/store exists AND (destination is empty OR .migration-in-progress exists).
   If the guard does not hold, there is nothing to do.
3. Write .migration-in-progress (source path, ISO timestamp, source byte count).
4. rsync -a --delete --exclude='/status' --exclude='/tmp/' --exclude='/shadow/' --exclude='tmp_*' \
         <source>/ <destination>/
   Idempotent and resumable: re-running after an interruption copies only what is missing.
   NOT mv. --delete removes anything a killed earlier pass left behind.
5. Verify by re-running the same rsync with --dry-run --itemize-changes.
   It must report NOTHING to transfer. Also log the byte and file counts of both trees.
   On any transfer being reported: leave .migration-in-progress in place, refuse to start, log loudly.
6. Write .migration-verified, remove .migration-in-progress, chown the destination.
7. Cleanup, gated on health: only once the app has reached /api/public/health 200 does
   `rm -rf <source>` run, logging the reclaimed bytes. If health is never reached, the legacy
   tree is left alone and a later boot performs the cleanup, because .migration-verified persists.
```

**Why a dry-run rsync rather than comparing `du -sb` totals.** The plan this work derives from specified
byte-and-count verification. That is a weaker check than it looks: totals can match while individual files
differ, and the excludes in step 4 mean the two trees are legitimately not byte-identical, so a naive total
comparison either fails spuriously or has to be given a fudge factor, which defeats the point. A second
rsync pass answers exactly the right question, "is anything still missing or different", it accounts for
the excludes automatically because it uses the same ones, and it is cheap against a quiescent source. The
byte and file counts are still logged, as evidence for a human reading the boot log, but they are not the
gate.

**Why the excludes.** `/status` is the lock file the live server flocks and is regenerated on start.
`/tmp/`, `/shadow/` and `tmp_*` are transients that ClickHouse discards at startup; carrying stale
`tmp_merge_*` directories across is at best pointless and at worst confusing, and these are the very
directories whose vanishing caused the original defect.

**Every interruption point is safe.** A killed copy resumes. A killed verify re-verifies. A killed cleanup
leaves a harmless duplicate that a later boot removes. At no point does a partially populated destination
look complete, because completeness is asserted by `.migration-verified` and nothing else.

### Signal handling

`start.sh` is PID 1 while the migration runs, and PID 1 receives no default signal dispositions, so a
platform stop during a multi-gigabyte copy would be ignored until `SIGKILL`. Install a `TERM`/`INT` trap
that forwards to the running child and waits for it. An interrupted copy is safe by construction, so the
trap costs nothing and turns a nine-second-then-kill stop into a clean one.

### MinIO

Identical shape against `/app/data/minio` to `/var/lib/minio`, and materially easier: MinIO's single-drive
layout is a plain file tree, the whole store is around 101 KB, and the copy is instantaneous. It gets the
same two markers and the same verification, because the cost of consistency here is a few lines.

### Restoring a v0.1.0-era backup onto v0.2.0

This falls out for free and must be preserved. A v0.1.0 backup restores raw files to `/app/data/clickhouse`
and `/app/data/minio`. On the next boot the destination is a populated `persistentDir` carrying
`.migration-verified` from the earlier migration, so step 1 would skip to cleanup and **delete the restored
legacy tree without using it**, which is wrong.

**Therefore the guard in step 2 takes precedence over step 1 when the source tree is newer than the
marker.** Concretely: if `/app/data/clickhouse/store` exists and its mtime is later than
`.migration-verified`, treat it as a freshly restored legacy backup, clear `.migration-verified`, empty the
destination, and migrate again. This is the only place in the design where data is deliberately discarded
from the destination, and it is correct: an operator who restores a v0.1.0-era backup is asking for exactly
that. Log it unmistakably.

## Deployment: publishing v0.2.0 is itself the production update

Found this session and recorded here because it changes when the migration reaches real data. An install
of this package was inspected and turned out to have been installed manually (`appStoreId` is empty) while
still carrying `versionsUrl` pointing at this repository's `CloudronVersions.json` on `main`, with
`enableAutomaticUpdate: true`, and never having been updated in place (`updateTime` is null). That
combination is the default for anyone who installs from a manifest that declares a `versionsUrl`, so it is
not a local quirk.

**So the box is watching `main`, and publishing 0.2.0 to `CloudronVersions.json` deploys it to production
without any further human action.** The plan this work derives from treats publishing and deploying as
separate steps, and on this install they are not.

Required sequencing, in order of preference and ideally both:

1. Set `enableAutomaticUpdate: false` on the production app before any 0.2.0 work reaches `main`, and
   re-enable it after the production update is confirmed. Small, reversible, visible, and it matches the
   backup stopgap already in place.
2. Keep 0.2.0 off `main`, on a branch or a separate versions file, until the migration gate passes.

Still unverified: whether an update delivered through `versionsUrl` actually redeploys a manually installed
app, given that Laminar ADR 0010 found `cloudron update --image` did not. That is the same question the
migration gate asks anyway, and it is answered there.

## Consequences

- The legacy tree survives for the duration of at least one boot, so **one** backup run could still walk it
  and abort. Mitigate by updating deliberately rather than overnight: take the update immediately after a
  known-good backup and confirm `/app/data/clickhouse` is gone before the next run.
- Boot is slower, once, by the time it takes to copy the store. On the production install that is a
  multi-gigabyte copy on local ext4. The health check will not be satisfied during it, which
  [ADR 0009](0009-clickhouse-boot-decision-tree.md) addresses.
- The escape hatch is Cloudron's automatic pre-update backup, but for a v0.1.0 install that backup is a raw
  copy of the very tree whose churn crashes the syncer. It is a genuine escape hatch only if it succeeds,
  which is the reason to schedule the update immediately after a known-good backup.

## Acceptance gate

Non-negotiable, and all three paths must be clean on a throwaway before production is touched:

1. **Clean migration.** Install v0.1.0, load it with data, update in place to v0.2.0. History survives,
   `/app/data/clickhouse` and `/app/data/minio` are gone, the app is healthy.
2. **Interrupted migration.** Repeat, killing the container mid-copy. The next boot resumes and completes,
   and the resulting store is verified complete, not merely non-empty.
3. **Legacy restore.** Restore a v0.1.0-era backup onto v0.2.0 and confirm the guard fires and the restored
   history is what the app serves, not the pre-restore store.
