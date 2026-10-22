# 13. Raw ingestion events stay out of the backup, and expire

Date: 2026-10-22

## Status

Accepted. Ships in v0.12.0. Closes the caveat recorded in [ADR 0006](0006-clickhouse-backup-persistentdirs-triplet.md)
and corrects constraint 3 of [ADR 0010](0010-bundled-object-store-successor.md).

## Context

ADR 0006 moved MinIO to a `persistentDir` and had the `backupCommand` copy it into `/app/data/minio-backup`,
on the measured basis that MinIO held almost nothing. It recorded one caveat: MinIO had received no new
object since install day, which is not Langfuse's documented data path, and "if event uploads are later
fixed, MinIO's churn rises from bookkeeping cadence to ingestion cadence".

That happened with Langfuse 4. Every ingestion request now writes its raw data to `events/` in the
bucket, one object per event (measured: 20,000 events produced exactly 20,000 objects). On a production
install the copy reached **384,050 event objects** out of 397,713 files in `/app/data`, about 5 GB,
growing by roughly 145 MB a day, and its MinIO stage took 60 to 94 minutes a night.

Cloudron's rsync backup uploader holds the list of every file it syncs in memory. At that count it ran
out of JavaScript heap (`Reached heap limit`, about 512 MB, SIGABRT) and the box ended the run, so every
app scheduled after this one went without a backup on consecutive nights. Raising the backup site's
memory limit (2 GiB or more raises the uploader's heap) lets the run finish, but treats the symptom: the
count grows without bound.

Langfuse re-reads these objects only to retry failed ingestion, to replay, and on the legacy ingestion
endpoint to merge incremental events for one record. The data built from them lives in ClickHouse,
which the `backupCommand` already dumps. Langfuse's own documentation recommends a lifecycle
(expiration) policy on the event bucket and a matching TTL on `blob_storage_file_log`; Langfuse Cloud
keeps 30 days.

## Decision

1. **The MinIO copy excludes `langfuse/events/`.** `media/` and `.minio.sys` are still copied, so a
   restore rebuilds a working bucket; `restore-clickhouse.sh` keys on `.minio.sys` and needs no change.
2. **Raw events expire after `LANGFUSE_EVENT_RETENTION_DAYS` days, default 30.** On every boot,
   `run-web.sh` replaces the bucket's lifecycle configuration with one rule (`mc ilm rule import`, so it is
   idempotent) and sets `TTL created_at + INTERVAL N DAY DELETE` on `blob_storage_file_log`, issuing
   the `ALTER` only when the TTL differs because it rewrites the table's parts. `0` removes both. A
   failure is logged and never stops the web process: retention is housekeeping.
3. **30 days, not shorter.** With events out of the backup the period costs only live disk (about
   4.4 GB at the measured rate). A lab burst of 20,000 events hit ClickHouse's memory limit and left
   4,740 events unprocessed and unretried an hour later; their raw objects are the only replay source,
   so the window should outlive a slow diagnosis.

## Consequences

- Measured on the same install (20,000 events): MinIO copy 20,169 files / 238 MB → 11 files / 124 KB;
  backup 21.7 s → 8 s. Gate 3 passed both legs (in-place rollback; restore into a clone, which then
  ingests normally). `test/ingest.sh` asserts the rule, the TTL and the copy, and a run against v0.11.0
  fails exactly those three checks.
- A restore no longer brings back raw events, so ingestion unprocessed at backup time cannot be replayed
  after a restore. Accepted: that window is seconds.
- The first start after updating deletes events older than the period, gradually, through MinIO's
  scanner. This is irreversible for those raw objects; ClickHouse data is untouched.
- The ClickHouse dump (about 14,000 files, 1.6 GB on the same install) is still re-uploaded in full
  every night. Incremental or server-side `BACKUP` remains available if that grows; it is not this
  decision.
- Open, separate: the ingestion burst that exceeded ClickHouse's memory limit and was not retried.
