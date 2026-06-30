# Known issues

## Backups: an intermittent platform race can abort the whole-server backup run (v0.1.0)

**What it is.** Langfuse bundles ClickHouse, whose storage engine constantly creates and removes
short-lived temporary directories (`store/<uuid>/tmp_merge_*`) as it merges data in the background.
Cloudron's backup syncer walks `/app/data` while the app is **live**. If one of those temp directories
disappears in the exact moment between the syncer listing it and descending into it, the syncer trips
and **the entire server's backup run aborts** — every app scheduled after Langfuse in that run is left
without a fresh backup.

**This is a Cloudron platform bug, not Langfuse data loss.** Your data is intact. Normal
backup/restore of this app works (it passes our backup→restore round-trip gate); the failure is an
*intermittent* collision that only happens when ClickHouse is mid-merge during the walk. It is reported
upstream — filed on the [Cloudron forum (topic 15663)](https://forum.cloudron.io/topic/15663/backup-task-crashes-when-a-clickhouse-app-deletes-a-temp-merge-dir-mid-snapshot), with a short pointer in
[`docs/upstream-cloudron-backup-syncer-race.md`](upstream-cloudron-backup-syncer-race.md), and **confirmed still present in Cloudron 9.2.0**. The permanent package-side fix lands in **v0.2.0**
([ADR 0006](decisions/0006-clickhouse-backup-persistentdirs-triplet.md)).

### Interim workaround (until the upstream fix and/or v0.2.0)

The most important thing is to **protect the rest of your server's backups**, because one Langfuse
collision can abort the whole run:

1. **Exclude Langfuse from the automatic backup schedule** (App → *Backups* → turn off automatic
   backups for this app). This keeps the other apps' scheduled backups reliable.
2. **Back Langfuse up out-of-band.** Take a **filesystem/volume snapshot** of the app's data volume from
   outside Cloudron (e.g. an LVM/ZFS/btrfs snapshot of the underlying dataset) — ideally with the app
   **stopped** so ClickHouse isn't mid-write.

> **Correction to an earlier, intuitive idea — it does *not* work.**
> "Stop the app, then run `cloudron backup create`" is **not** a valid quiesced-backup path:
> **Cloudron does not back up a stopped app.** A quiesced backup therefore has to be a filesystem/volume
> snapshot taken *outside* the platform (as in step 2), not a platform backup of a stopped app.

If you'd rather not snapshot out-of-band, the alternative is to **keep automatic backups on and accept
that a run may occasionally abort** — re-running the backup usually succeeds (the collision window is
small). Backing up during **low-ingest periods** (fewer merges) reduces the odds further. Neither is a
fix; both just lower the collision probability.

### Permanent fix

- **Upstream:** a syncer that tolerates a directory vanishing mid-walk (helps *all* ClickHouse-bundling
  apps, not just Langfuse). Filed; patch-testing offered.
- **This package (v0.2.0):** move the ClickHouse store out of `/app/data` into a `persistentDir`
  (excluded from the filesystem walk → the temp dirs are no longer in the walked tree → the race is
  structurally gone) and back it up via a consistent logical dump using Cloudron 9.1's
  `backupCommand`/`restoreCommand`. Design and acceptance gate:
  [ADR 0006](decisions/0006-clickhouse-backup-persistentdirs-triplet.md).
