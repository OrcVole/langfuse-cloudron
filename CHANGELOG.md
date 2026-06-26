# Changelog

All notable changes to this package. The community versions channel parses the bracket headings
(`[0.1.0]`) literally, so keep that format.

## [0.1.0]

* Initial Cloudron package of Langfuse v3.199.0 (open-source / MIT).
* Four-process topology under Supervisor: ClickHouse + MinIO bundled; langfuse-web + langfuse-worker.
* PostgreSQL and Redis via Cloudron addons; SSO via the OIDC addon (Langfuse keeps its own login).
* Public ingestion API left open for Langfuse project API keys.
