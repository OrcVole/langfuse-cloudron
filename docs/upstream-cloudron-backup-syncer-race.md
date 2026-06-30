# Upstream report: ClickHouse backup syncer race

This issue is filed upstream on the Cloudron forum:
https://forum.cloudron.io/topic/15663/backup-task-crashes-when-a-clickhouse-app-deletes-a-temp-merge-dir-mid-snapshot

**Summary.** A bundled-ClickHouse app's background merge temp directories (`tmp_merge_*`, `tmp_insert_*`,
`tmp_fetch_*`) can vanish mid-snapshot while Cloudron's rsync syncer walks the data tree; `readTree` then
calls `.sort()` on a `null` `readdir` result and crashes, which aborts the **whole-server** backup run,
not just this app. **Confirmed still present in Cloudron 9.2.0:** the `readTree` null guard exists but is
positioned *after* the `.sort()` (`syncer.js:31`), so it is dead code for this crash.

**Workaround and the package's own fix:** see [`KNOWN-ISSUES.md`](KNOWN-ISSUES.md). The real fix is
**v0.2.0** — the ClickHouse store moves to a `persistentDir`, backed up as a consistent logical dump via
`backupCommand`/`restoreCommand` (see [ADR 0006](decisions/0006-clickhouse-backup-persistentdirs-triplet.md)).

**Do not use stop-then-backup:** Cloudron does not back up a stopped app.

---

*The forum thread is the single canonical report and carries the full environment detail; this file is
just a pointer to it.*
