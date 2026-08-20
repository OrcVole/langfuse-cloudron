[0.7.0]
* Langfuse 4.15.0 (from 4.14.0), one upstream release
* **Carries a credential-disclosure fix that upstream does not label security.** PR 16300: automation action configs were sanitised on the read path for webhook types only, so a GITHUB_DISPATCH config was returned verbatim with its stored githubToken to any project role down to VIEWER. Upstream backported it to the maintained v3 line the same day, which is the strongest signal available that they consider it serious. Also 16308 (tool payloads redacted from sandbox runtime logs) and 16302 (session-replay content masked)
* **No schema migration.** 21 commits over 122 files with no schema.prisma change, no prisma/migrations, no ClickHouse migration and no .sql. The six files matching "migration" are the in-app v4 upgrade assistant's UI. Gate 3 was therefore run REDUCED — update over populated data, row counts and a content checksum, restore leg skipped
* Checked before publishing: neither production install had ever held an automation action config, so nothing was disclosable here and no token needed rotating

[0.6.0]
* Langfuse 4.14.0 (from 4.6.0), eleven upstream releases
* Carries database migrations: three Prisma migrations land in this span (an always-allowed-tools column for in-app agent conversations, a dropped job_execution configuration foreign key, and PostHog integration error fields), plus a schema.prisma change
* Gate 3 was run in full for this reason: update over populated data, then backup and restore

# Changelog

All notable changes to this package. The community versions channel parses the bracket headings
(`[0.1.0]`) literally, so keep that format.

[0.5.0]

* **Langfuse v4.3.0 to v4.6.0.** Routine upstream minors. One Prisma migration
  (`add_media_association_origin`), proven over a 5958-trace corpus during the update gate with
  count and content checksum identical before and after.
* Bundled ClickHouse pin deliberately unchanged; no new services, no manifest changes beyond the
  version fields.
* Backup, in-place restore and trace ingestion re-verified on the gate fixture at this version.

[0.4.0]

* **Langfuse v4.2.0 to v4.3.0.** A routine upstream minor: no schema migrations, no new required
  configuration, and no change to the bundled ClickHouse or MinIO.
* Fixes to the v4 compatibility surface that this package's `dual` write mode relies on: legacy
  dataset-run GET APIs are detected correctly again, and dashboards keep working against legacy
  v4 traces.
* The sidebar's background-migration indicator no longer lights up for migrations that are
  switched off by configuration and will never run.
* Upstream hardening: the signup API route now rejects non-POST methods with 405 rather than
  returning an empty response.

[0.3.0]

* **Langfuse v3.199.0 to v4.2.0 (major), and bundled ClickHouse 25.3 to 26.4** (langfuse v4's
  recommended version; v4 requires at least 25.12). The ClickHouse store upgrades its on-disk
  format in place on first boot; the v4 schema migrations then create the new `events` tables
  automatically. Nothing to do on update, but take it deliberately, just after a known-good backup.
* **All v3 API and SDK surfaces keep working.** This package pins langfuse's migration write mode
  to `dual` (writes go to both the v3 tables and the new v4 events tables), so old SDKs, the legacy
  ingestion endpoints, and the legacy read APIs all continue to function. Langfuse's own default
  for fresh v4 installs (`events_only`) would reject ingestion from Python SDK 2.x and JS/TS SDK
  3.x and earlier.
* Langfuse's background backfill converts existing traces into the new v4 data model automatically.
* **New: `/app/data/env.sh`** is sourced on every boot, after all package defaults. Use it to cut
  over to the pure v4 data model (`LANGFUSE_MIGRATION_V4_WRITE_MODE=events_only`) once every SDK
  and integration pointing at this install is v4-compatible. Until then the safe `dual` default
  costs a little duplicate write volume and nothing else.
* ClickHouse telemetry bounds re-verified against 26.4: `latency_log` no longer exists there; the
  new `histogram_metric_log` and `background_schedule_pool_log` are disabled, along with the rest
  of 26.4's active-by-default internal log tables (notably `query_views_log`, which would fire on
  every ingest under v4's materialised-view data path).
* **Memory limit raised from 5 GiB to 6 GiB.** Langfuse v4's web process does not fit the v3-era
  768 MB Node heap (it fails at boot); it now gets 1536 MB, and the app's total limit moves up
  with it. Existing installs pick the new limit up automatically on update.

[0.2.1]

* Bounds ClickHouse's own telemetry tables, which previously grew without limit. On a five-week idle
  install they had reached 176 million rows and 3.9 GB against 19.7 kB of application data, starved
  every analytics query of memory (dashboards erroring while the app reported healthy), and burned
  several CPU cores continuously on background merges. Ten internal log tables are now disabled;
  `query_log` and `error_log` are kept with a three-day retention.
* **Updating an existing install needs a one-time cleanup**, done together with the update rather
  than deferred: the removed tables' data is not reclaimed by disabling them, and the two kept tables
  are renamed to `query_log_0`/`error_log_0` when the retention is added. See `docs/KNOWN-ISSUES.md`
  for the exact statements. A fresh install needs nothing.

[0.2.0]

* Fixes a defect where this app could abort the **whole server's** backup run. The bundled ClickHouse
  and MinIO stores move out of `/app/data` into `persistentDirs`, which are excluded from Cloudron's
  filesystem backup walk, so their constant temporary-directory churn can no longer make the backup
  syncer trip. The data stays fully backed up and restorable through `backupCommand`/`restoreCommand`.
* **Updating from 0.1.0 performs a one-time data migration on first boot.** It copies the existing
  ClickHouse store to its new location, verifies the copy, and only then removes the old one, so the
  first boot after updating takes noticeably longer than usual. The migration is resumable: if it is
  interrupted, the next boot continues it rather than starting over or booting on partial data. Take
  the update deliberately, just after a known-good backup, rather than leaving it to run overnight.
* **In-place restore now behaves differently for ClickHouse.** An in-place restore preserves
  `persistentDirs`, so it restores your Postgres data and the ClickHouse dump but leaves the live
  ClickHouse store as it is. See `KNOWN-ISSUES.md` for the recipe that makes an in-place restore
  actually roll ClickHouse back.
* Restores of pre-0.2.0 backups onto 0.2.0 are supported: the migration recognises the restored legacy
  data and relocates it.

[0.1.0]

* Initial Cloudron package of Langfuse v3.199.0 (open-source / MIT).
* Four-process topology under Supervisor: ClickHouse + MinIO bundled; langfuse-web + langfuse-worker.
* PostgreSQL and Redis via Cloudron addons; SSO via the OIDC addon (Langfuse keeps its own login).
* Public ingestion API left open for Langfuse project API keys.
