Langfuse is an open-source LLM engineering platform. It gives you observability and tracing for LLM
applications, evaluations, prompt management, a prompt playground, datasets, and usage/cost metrics —
all self-hosted on your own Cloudron.

This package runs the **open-source (MIT)** edition. It integrates with OpenTelemetry, the OpenAI SDK,
LangChain, LiteLLM, LlamaIndex, and most LLM tooling, so it can act as the observability sink for the
rest of your stack.

**On this Cloudron:**

* Langfuse keeps its **own login** (email/password plus optional single sign-on through your Cloudron
  users via OIDC). It is *not* fronted by the Cloudron SSO proxy.
* Trace ingestion uses **Langfuse project API keys** (a public/secret key pair you create in the UI),
  sent to the open `/api/public/*` endpoints — including the OpenTelemetry endpoint
  `/api/public/otel/v1/traces`.
* ClickHouse and MinIO are **bundled and managed for you**; PostgreSQL and Redis come from Cloudron
  addons. All trace data and object storage live in the app's backed-up data directory.

The enterprise (`/ee`) features (RBAC, audit logs, data retention policies, SCIM) are intentionally
not included.
