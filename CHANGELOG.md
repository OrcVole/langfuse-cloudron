# Changelog

All notable changes to this package. The community versions channel parses the bracket headings
(`[0.1.0]`) literally, so keep that format.

## [0.2.0]

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

## [0.1.0]

* Initial Cloudron package of Langfuse v3.199.0 (open-source / MIT).
* Four-process topology under Supervisor: ClickHouse + MinIO bundled; langfuse-web + langfuse-worker.
* PostgreSQL and Redis via Cloudron addons; SSO via the OIDC addon (Langfuse keeps its own login).
* Public ingestion API left open for Langfuse project API keys.
