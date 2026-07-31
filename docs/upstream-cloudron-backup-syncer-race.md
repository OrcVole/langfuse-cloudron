# Upstream report: ClickHouse backup syncer race

This issue is filed upstream on the Cloudron forum:
https://forum.cloudron.io/topic/15663/backup-task-crashes-when-a-clickhouse-app-deletes-a-temp-merge-dir-mid-snapshot

**Summary.** A bundled-ClickHouse app's background merge temp directories (`tmp_merge_*`, `tmp_insert_*`,
`tmp_fetch_*`) can vanish mid-snapshot while Cloudron's rsync syncer walks the data tree; `readTree` then
calls `.sort()` on a `null` `readdir` result and crashes, which aborts the **whole-server** backup run,
not just this app. **Reproduced live on Cloudron 9.2.0:** the `readTree` null guard is
positioned *after* the `.sort()` (`syncer.js:31`), so it does not prevent the crash.

**Workaround and the package's own fix:** see [`KNOWN-ISSUES.md`](KNOWN-ISSUES.md). The real fix is
**v0.2.0** — the ClickHouse store moves to a `persistentDir`, backed up as a consistent logical dump via
`backupCommand`/`restoreCommand` (see [ADR 0006](decisions/0006-clickhouse-backup-persistentdirs-triplet.md)).

**Do not use stop-then-backup:** Cloudron does not back up a stopped app.

## Cadence evidence, gathered 2026-07-31 — worth adding to the thread

The thread currently describes the crash as intermittent. Measured on one box, it is not intermittent in
any useful sense: it is close to deterministic whenever the app is running and ingesting.

- The whole-server run failed on **twelve consecutive nights (3 to 14 July)**, that is, every night the
  app was running.
- It succeeded on **thirteen of fifteen nights (16 to 30 July)**, during which the app was **stopped**.
  The two failures in that window were an unrelated signature (`Task was stopped because the server
  restarted or crashed`).
- It failed again on the **first night after the app was restarted**.
- The two failing signatures are the same hazard seen by two different tools: `find exited with code 1
  signal null` from the rsync backup format's `find … -type d -empty` / `-type f -executable` / `-type l`
  passes, which return 1 when a directory vanishes underneath them, and `TypeError: Cannot read
  properties of null (reading 'sort')` from `readTree`. A fix that only guards `readTree` will convert
  the crash into the `find` signature rather than removing it.
- Scale, for a sense of the collision surface: **ten concurrent `tmp_merge_*` directories** were observed
  in a single sample of a **221 865-file, 4.17 GB** ClickHouse store under ordinary load.
- The platform's own `du --dereference-args` also fails on the same vanishing directories, in
  `checkPreconditions`, before the syncer is reached.

This strengthens the case that the guard needs to cover every tree-walking pass, not just `readTree`.

## A second, unrelated defect found in the same file — the inode comparison never fires

Worth reporting separately, because it is an integrity issue rather than a crash.

`syncer.js` decides a file has changed with:

```js
if (entryStat.mtime.getTime() !== cacheStat.mtime || entryStat.size != cacheStat.size
    || entryStat.inode !== cacheStat.inode) { // file changed
```

and caches it with `stat: { mtime: ..., size: ..., inode: entryStat.inode, mode: ... }`.

**Node's `fs.Stats` has no `inode` property; it is `ino`.** So `entryStat.inode` is `undefined`,
`JSON.stringify` omits it from the cache entry, and the third clause evaluates
`undefined !== undefined`, which is always false. Verified on a 9.2.0 rig:

```
$ node -e 'const s=require("fs").statSync("/etc/hostname"); console.log(s.ino, s.inode)'
149641 undefined
```

The effective comparison is therefore **mtime and size only**. A file modified in place that keeps
both its size and its mtime is never re-uploaded, and the backup silently retains the stale copy.
Restores and tools that preserve mtimes make that less exotic than it sounds.

Changing `inode` to `ino` would fix it, but note it would also invalidate every existing cache entry
(all of which lack the field), so the first run afterwards would re-upload everything.

**Not yet posted.** The forum thread is the canonical report and only the maintainer can update it; this
section is the copy to be pasted, held here until then.

---

*The forum thread is the single canonical report and carries the full environment detail; this file is
just a pointer to it.*
