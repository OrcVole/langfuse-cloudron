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

## License

The packaging in this repository is MIT-licensed (see [LICENSE](LICENSE)). Langfuse itself is a
trademark of Langfuse GmbH; the bundled runtime is the MIT-licensed open-source build. Upstream:
<https://github.com/langfuse/langfuse>.
