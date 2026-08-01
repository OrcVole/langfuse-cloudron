# Known issues

## ClickHouse's own system logs grow without bound, and can starve queries (all versions)

**What it is.** The bundled ClickHouse writes its internal telemetry (`system.query_log`,
`system.part_log`, `system.metric_log` and friends) into its own store, and this package does not
configure a TTL for those tables, so they grow for as long as the app runs. Measured on a production
install after five weeks of essentially idle uptime: the application's data was **19.7 kB** while the
`system` database had accumulated **176 million rows and 4.1 GB across roughly 222 000 files**.

Two consequences:

1. **Backups carry it.** The store the migration moves and the `backupCommand` snapshots is dominated
   by logs about the server itself. (The logical dump is unaffected — it exports only the application
   database — but the transient snapshot copy inside each backup pays the full weight.)
2. **Queries can starve.** ClickHouse's tracked memory can sit above this package's absolute 2 GiB cap
   (ADR 0005) once the parts metadata for those log tables is large enough, at which point **every
   aggregating query fails with `MEMORY_LIMIT_EXCEEDED`** — in the Langfuse UI that surfaces as
   dashboards and analytics erroring while the app otherwise looks healthy. A restart does not durably
   clear it, because the server reloads the same parts metadata at boot.

**Interim recipe.** In the app's terminal, truncate the log tables (they are diagnostics, not
application data; truncation is DDL and works even when queries are starving):

```
clickhouse-client --user clickhouse --password "$CLICKHOUSE_PASSWORD" \
  --query "TRUNCATE TABLE system.query_log; TRUNCATE TABLE system.part_log; TRUNCATE TABLE system.metric_log; TRUNCATE TABLE system.trace_log; TRUNCATE TABLE system.asynchronous_metric_log; TRUNCATE TABLE system.text_log"
```

(Tables that do not exist on your version can be dropped from the list.)

**Permanent fix.** Planned for v0.2.1: TTL and size caps on the system log tables in the packaged
ClickHouse configuration, so the store stays proportional to the application data it actually holds.

## An in-place restore does not roll ClickHouse back (v0.2.0 onwards)

**What it is.** From v0.2.0 the ClickHouse and MinIO stores live in Cloudron `persistentDirs`, and
**Cloudron preserves `persistentDirs` across an in-place restore**. So if you restore this app to last
Tuesday, you get last Tuesday's Postgres data and last Tuesday's ClickHouse dump file, but the
ClickHouse store the app actually reads is still **today's**. Your traces and observations are not
rolled back, and the app will not tell you so beyond a line in its boot log.

This is the one place where v0.2.0 behaves worse than v0.1.0, which kept raw files in `/app/data` and
therefore rolled them back with everything else. It is the price of taking ClickHouse out of the backup
walk, which is what stops this app aborting your whole server's backup run.

**A clone is not affected.** Cloning to a new location starts with empty `persistentDirs`, so the clone
rebuilds ClickHouse from the dump and gives you exactly the data in that backup. If what you want is a
point-in-time copy to look at, clone rather than restore.

### Restoring a backup from before v0.2.0 takes the app back to v0.1.0

Cloudron restores an app's *manifest* along with its data, so if you restore a backup that was taken
while this app was on v0.1.0, the app goes back to running v0.1.0. That is normal and the data is
correct, but one consequence is alarming if you are not expecting it.

**`/var/lib/clickhouse` will look empty from inside the app, and your data is not gone.** The v0.1.0
manifest declares no `persistentDirs`, so Cloudron simply stops mounting them; what the container shows
you is an empty directory from the image. The real store is still on the host, untouched, and it comes
back the moment a manifest that declares it is applied again. **Do not try to "clean up" that apparently
empty directory**, and do not conclude the migration destroyed anything.

When you next update to v0.2.0, the app finds the restored v0.1.0 data in `/app/data` alongside that
older store, and it says so in the boot log before doing anything:

```
==> [migrate] clickhouse: legacy data at /app/data/clickhouse while /var/lib/clickhouse is already populated
==> [migrate] clickhouse: ... DISCARDING the current contents of /var/lib/clickhouse
==> [migrate] clickhouse: and migrating the restored data in their place.
```

That is deliberate, not a bug: you restored that backup because you wanted its data, so the restored
data wins and the older store is discarded. The migration then verifies the copy and only deletes the
legacy tree once the app has actually served traffic. This path is gate-tested end to end.

### Recipe: making an in-place restore actually restore ClickHouse

1. Perform the in-place restore as normal and let the app come up.
2. **Stop** the app.
3. Clear the ClickHouse store: in *Terminal* or the file manager, empty `/var/lib/clickhouse`.
4. **Start** the app.

On that boot the app finds an empty store alongside the restored dump and rebuilds ClickHouse from it,
which takes a few minutes for a large store. To roll MinIO back too, empty `/var/lib/minio` in the same
step. Take a backup first if there is any chance you want the current data back.

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
[`docs/upstream-cloudron-backup-syncer-race.md`](upstream-cloudron-backup-syncer-race.md), and **reproduced live on Cloudron 9.2.0** (the `readTree` null guard is positioned after the `.sort()`, so it does not prevent the crash). The permanent package-side fix lands in **v0.2.0**
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

> **Correction, 2026-07-31: "just re-run it" does not work either, and this page previously said it did.**
> An earlier version of this section suggested that re-running the backup usually succeeds because the
> collision window is small. Measured evidence refutes that. On one box, the whole-server run failed on
> **twelve consecutive nights (3 to 14 July)**, on every single night that Langfuse was running, in two
> alternating error signatures that are the same hazard seen by two different tools (`find exited with
> code 1` from the rsync format's tree passes, and `Cannot read properties of null (reading 'sort')` from
> the syncer's `readTree`). The run only started succeeding when Langfuse was **stopped** on 15 July, and
> it failed again the first night after Langfuse was restarted. The collision window is not small on an
> app with real ingestion: ten concurrent `tmp_merge_*` directories were observed in a single sample of a
> 221 865-file store.

If you would rather not snapshot out-of-band, the honest position is that there is **no reliable interim
option**: keeping automatic backups on for Langfuse means accepting that the whole-server run will
probably abort, taking every app scheduled after Langfuse with it. Backing up during **low-ingest
periods** genuinely does reduce the odds, because fewer merges means fewer temporary directories, but it
does not make the run reliable. Step 1 above, excluding Langfuse from the schedule, is the only measure
that protects the rest of the server.

### Permanent fix

- **Upstream:** a syncer that tolerates a directory vanishing mid-walk (helps *all* ClickHouse-bundling
  apps, not just Langfuse). Filed; patch-testing offered.
- **This package (v0.2.0):** move the ClickHouse store, and the bundled MinIO store with it, out of
  `/app/data` into `persistentDirs` (excluded from the filesystem walk → the temp dirs are no longer in
  the walked tree → the race is structurally gone) and back them up via a consistent logical dump using
  Cloudron 9.1's `backupCommand`/`restoreCommand`. Design and acceptance gate:
  [ADR 0006](decisions/0006-clickhouse-backup-persistentdirs-triplet.md), with the one-time migration of
  existing installs in [ADR 0008](decisions/0008-clickhouse-store-migration.md) and the boot logic in
  [ADR 0009](decisions/0009-clickhouse-boot-decision-tree.md).

  **Upgrading from v0.1.0 will be a one-time in-place data migration.** It is resumable and verified, but
  it copies the whole ClickHouse store, so the first boot after the update takes noticeably longer than
  usual. Take the update deliberately, immediately after a known-good backup, rather than leaving it to
  run overnight. v0.2.0 also changes what an **in-place restore** does to ClickHouse; that behaviour is
  documented on this page when v0.2.0 ships.
