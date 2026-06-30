# Upstream report — whole-server backup aborts on a vanished ClickHouse merge-temp dir

**Status:** drafted for filing on the Cloudron forum (Support). Not yet posted.
**Where to file:** <https://forum.cloudron.io> — "Get technical support … Our engineers monitor the
forum." (Email is reserved for sensitive/billing/legal.) Post under **Support**.
**Before posting:** fill the `[confirm]` cells in the environment table, and sanity-check the exact
`box/src/syncer.js` file/line against *your* box version (box internals shift between releases). Keep it
anonymised — no hostnames/emails/IPs.

The text between the rulers below is paste-ready.

---

### Title

Whole-server backup run aborts when an app's data dir mutates mid-walk (rsync syncer trips over a
ClickHouse merge-temp directory that vanishes between listing and traversal)

### Summary

On a multi-app server, a full backup run **aborted entirely** partway through. The cause is a
time-of-check/time-of-use race in the **rsync backup syncer's directory walk**: it listed a child
directory that existed at `readdir` time, then tried to traverse it after it had been removed, got
`null` back, and a subsequent `.sort()` on that `null` threw — and the exception aborted the **whole
backup task**, not just the one app. Every app scheduled *after* the failing one was left without a
fresh backup.

The directory that vanished is a **normal, expected ClickHouse transient**: a `tmp_merge_*` directory
under `store/<uuid>/` that ClickHouse atomically renames to the final data part when a background merge
finalises. Backups run with apps **live**, so this churn is constant and legitimate. A single benign
transient from one busy app should not be able to abort the entire server's backup.

### Impact / severity

- **One app's benign file churn aborts the whole-server backup run.** The run stopped at app *k* of *N*;
  the remaining *N − k* apps (about forty, here) were left on **stale snapshots** — a silent
  data-protection gap until the next successful run.
- Intermittent and load-dependent (only when a merge finalises in the exact window between the walker
  listing a parent and recursing into the child), so it can pass for a long time and then bite.
- Affects an entire class of apps, not one package (see *Affected apps* below).

### Environment

| Field | Value |
|-------|-------|
| Cloudron (box) version | `9.1.x` `[confirm exact]` |
| Backup strategy | **rsync** (the tree-walk path) |
| Backup storage backend | `[confirm: filesystem / NFS / CIFS / SSHFS / S3 …]` |
| Host OS / arch | `[confirm]` |
| Server scale | ~70 apps; the abort left ~40 later apps unbacked this run |
| Triggering app | a community package bundling **ClickHouse 25.3** with its data under `/app/data/clickhouse` (a Langfuse package; repo link optional: `[your package URL]`) |
| Other affected-class apps present | `[optional: Plausible / PostHog / SigNoz / Elasticsearch …]` |

### What happens (mechanism)

1. The rsync syncer builds a tree of `/app/data` by walking it (`readdir` + recurse). The failing
   function appears to be **`readTree` in `box/src/syncer.js`** `[confirm line]`.
2. ClickHouse (MergeTree) continuously creates transient directories under `store/<uuid>/` during
   background work — chiefly `tmp_merge_*` (merges), plus `tmp_mut_*`, `tmp_insert_*`, `delete_tmp_*`.
   When a merge finalises, its `tmp_merge_*` dir is **atomically renamed in place** to the final part
   name, so the temp name disappears.
3. The walker listed a parent and saw a `tmp_merge_*` child, then recursed into it **after** the merge
   finalised. The path no longer existed → the read returned **`null`**.
4. `readTree` then called **`.sort()` on that `null`** → `TypeError`, which propagated up and **aborted
   the entire backup task**.

Two compounding defects:

- **(a)** A child that vanishes between *list* and *traverse* is treated as fatal (yields `null`) rather
  than "it's gone, skip it."
- **(b)** That `null` flows into `.sort()` unguarded, so a transient read-miss becomes a hard crash of
  the whole walk.

### Why this can't be fixed in the app

- The `tmp_merge_*` dirs are core MergeTree behaviour and **must** sit beside the parts in
  `store/<uuid>/` (a merge finalises by atomic rename *in place*), so they can't be relocated out of the
  backed-up tree.
- Quiescing merges for the backup window isn't reachable from the app: `backupCommand` runs in a
  **separate temporary container** (it can't signal the live ClickHouse), and there is **no
  live-container pre/post-backup hook** (this was raised in forum topic 8367 and resolved by pointing to
  `backupCommand`/`restoreCommand`). So the syncer has to tolerate concurrent mutation.

### Minimal reproduction

- Install any app that bundles ClickHouse with data under `/app/data` (a Langfuse- or Plausible-style
  package).
- Drive sustained ingestion so ClickHouse produces many small parts and runs **frequent background
  merges**.
- Trigger an **rsync** backup while merges are active; repeat. Intermittently the walk recurses into a
  `tmp_merge_*` that has just finalised and the run aborts.
- More deterministically: a synthetic directory that is **created, listed, then removed** between the
  walker's `readdir` and its recursion reproduces the same TOCTOU.

### Suggested fix (syncer robustness)

- In the tree walk, treat **`ENOENT`** (and `ENOTDIR`) on a child during `lstat`/`readdir`/recurse as
  **"entry disappeared mid-walk → skip and continue"**, not fatal.
- **Guard the `.sort()` site** (and any array consumer) against `null`, so a transient read-miss can
  never crash the walk.
- Optional: **isolate per-app backup failures** so one app's error can't abort the whole-server run
  (defence in depth — this is the part that turned a one-file blip into ~40 unbacked apps).
- Optional: retry-once on a vanished path.

### Affected apps (the general class)

Any app whose data dir legitimately mutates during a live backup: ClickHouse-bundling apps (**Langfuse,
Plausible, PostHog, SigNoz**), **Elasticsearch/OpenSearch** (Lucene segment merges), **RocksDB/LevelDB**
compaction, and similar. Because backups run with apps live, transient-file churn is expected and the
walker should tolerate it.

### Offer

I can reproduce this reliably on a live install under ingestion load, and I'm happy to **test a
candidate patch** against that setup.

---

*End of paste-ready report.*
