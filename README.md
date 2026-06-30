# Langfuse for Cloudron

A [Cloudron](https://cloudron.io) community package of **[Langfuse](https://langfuse.com)** — the
open-source LLM engineering platform (tracing, evals, observability, metrics, prompt management,
playground, datasets).

This package ships the **open-source (MIT)** Langfuse stack as a single Cloudron app. It bundles
ClickHouse and MinIO under Supervisor, uses Cloudron's PostgreSQL and Redis addons, and integrates
single sign-on through the **OIDC addon** (Langfuse keeps its own NextAuth login). The public
ingestion API (`/api/public/*`) stays open and is protected by Langfuse's own project API keys, so
SDKs, OpenTelemetry exporters, and integrations can send traces.

- **Upstream:** Langfuse v3.199.0 (open-source / MIT; the `/ee` enterprise code is excluded)
- **Package version:** 0.1.0
- **Status:** in development

## Architecture

| Component | Source | Notes |
|-----------|--------|-------|
| `langfuse-web` | `langfuse/langfuse` | Next.js web + public API, primary `httpPort` 3000 |
| `langfuse-worker` | `langfuse/langfuse-worker` | BullMQ queue worker |
| ClickHouse | bundled | OLAP store, data in `/app/data/clickhouse`, UTC |
| MinIO | bundled | object storage, data in `/app/data/minio` |
| PostgreSQL | Cloudron addon | `CLOUDRON_POSTGRESQL_URL` |
| Redis | Cloudron addon | BullMQ broker (see ADR 0003) |

See [`docs/`](docs/) for architecture decisions (ADRs) and the verified-vs-assumed packaging notes.

## Known issues

- **Backups (v0.1.0):** an intermittent Cloudron *platform* race — the backup syncer can trip over a
  ClickHouse merge-temp directory that vanishes mid-walk — can abort the **whole-server** backup run.
  Your Langfuse data is not corrupted and normal backup/restore works; this is a platform bug, reported
  upstream. See **[docs/KNOWN-ISSUES.md](docs/KNOWN-ISSUES.md)** for the interim workaround, and
  **[ADR 0006](docs/decisions/0006-clickhouse-backup-persistentdirs-triplet.md)** for the structural fix
  landing in v0.2.0.

## License

The packaging in this repository is MIT-licensed (see [LICENSE](LICENSE)). Langfuse itself is a
trademark of Langfuse GmbH; the bundled runtime is the MIT-licensed open-source build. Upstream:
<https://github.com/langfuse/langfuse>.
