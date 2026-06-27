# Integrations and gotchas

How to get traces into this Langfuse from other apps, what works, and the rough edges worth knowing.
All hostnames below are placeholders — substitute your own.

## The two ways in

Langfuse ingests over TLS on its app domain. Two transports, two auth forms — never cross them:

- **Langfuse SDK (recommended for application code).** The Python/JS SDK creates a full trace +
  *generation* tree (prompt, completion, model, token usage). Configure it with SDK env:
  ```
  LANGFUSE_PUBLIC_KEY=<your-public-key>
  LANGFUSE_SECRET_KEY=<your-secret-key>
  LANGFUSE_HOST=https://langfuse.example.com
  ```
  See `examples/rag_langfuse_example.py` for a working RAG pipeline (Docling → TEI → Qdrant → LLM)
  traced with SDK v4, where the LLM call lands as a `type=GENERATION` observation via the
  `langfuse.openai` drop-in.

- **Raw OpenTelemetry / OTLP.** Point any OTLP/HTTP client at the OTLP path with HTTP Basic auth:
  ```
  endpoint:      https://langfuse.example.com/api/public/otel/v1/traces
  Authorization: Basic base64(<public-key>:<secret-key>)
  Content-Type:  application/x-protobuf   (application/json also accepted)
  ```
  Verified: the endpoint accepts OTLP/protobuf and OTLP/JSON, gzip or not, HTTP/1.1 or HTTP/2 —
  **as long as the request is real TLS.** A client that emits cleartext to the `:443` port gets
  nginx's `400 "The plain HTTP request was sent to HTTPS port"` (see agentgateway below).

## Per-app status

### Application code (Python / JS SDK) — works, full generations
The intended path. Use the SDK; the `langfuse.openai` drop-in auto-records LLM calls as generations,
and `@observe` + `start_as_current_observation(as_type="span"|"retriever")` build the surrounding tree.
This is the only path that yields the rich prompt/completion/model/token tree Langfuse is for.

### Open WebUI — works over TLS, infrastructure spans only
Open WebUI (v0.6.16+) has native OpenTelemetry. Wire it on the Open WebUI app (env), not on Langfuse:
```
ENABLE_OTEL=true
ENABLE_OTEL_TRACES=true
OTEL_OTLP_SPAN_EXPORTER=http          # REQUIRED: the default is grpc, which sends cleartext to :443
OTEL_SERVICE_NAME=open-webui
OTEL_EXPORTER_OTLP_ENDPOINT=https://langfuse.example.com/api/public/otel/v1/traces
OTEL_BASIC_AUTH_USERNAME=<public-key>
OTEL_BASIC_AUTH_PASSWORD=<secret-key>   # Open WebUI builds Basic base64(public:secret) itself
```
What lands: **infrastructure/APM spans** (HTTP, Redis, DB) with `service.name=open-webui` — *not* LLM
generations, and verbose (a trace per span). It proves the pipe and validates ingestion, but for rich
per-generation tracing Open WebUI needs its **Pipelines** Langfuse filter, which is a separate service
(`open-webui/pipelines`) that upstream now brands "legacy". There is no native `LANGFUSE_*` integration
in Open WebUI core.

### agentgateway — BLOCKED upstream (cleartext export)
agentgateway 1.3.1's `config.tracing` OTLP/HTTP exporter sends **cleartext HTTP/2** to the `https://`
endpoint — it ignores the scheme and never does a TLS handshake — so Cloudron's TLS-terminating nginx
returns `400 "plain HTTP request was sent to HTTPS port"` and every span is dropped. There is no
tracing-TLS field and no `OTEL_EXPORTER_OTLP_TRACES_INSECURE` override in 1.3.1; both `config.tracing`
and the env-var endpoint route through the same normalize that requires a port and emits cleartext.
Everything else is correct (payload, `Basic` auth, path all return 200 when sent over real TLS by any
standard client). Filed upstream: https://github.com/agentgateway/agentgateway/issues/2343. Until a
release honours `https://` (or adds a TLS toggle), agentgateway tracing cannot reach a TLS-only OTLP
receiver.

## Maintainer notes (someone investigate later)

- **`langfuse.openai` against a CPU-only ollama drops the call intermittently.** During the RAG example
  on a CPU-only box, the wrapped LLM call hit `APIConnectionError` ("Server disconnected") when ollama
  was busy cold-loading or generating near the ~60s reverse-proxy cut-off; plain `openai`/`curl`
  succeeded when the box was calm. The generation observation still lands (type, model, prompt) but with
  an empty completion. This is an ollama-on-CPU + proxy-timeout artifact, **not** a Langfuse issue —
  Langfuse stored exactly what was sent. Worth a look from anyone with a warm/GPU ollama.
- **Diagnose silent export failures from the emitter, not the receiver.** When an app's traces don't
  appear, read that app's own debug log first (`RUST_LOG=...,h2=debug` is what surfaced agentgateway's
  literal nginx rejection body). It beats reproducing from the Langfuse side.
