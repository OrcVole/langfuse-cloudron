# 4. S3 presigned media routing (the blob subdomain)

Date: 2026-06-26

## Status

Accepted — expose a public `httpPorts` "blob" subdomain routed to the bundled MinIO; enable media now.

## Context

Langfuse stores multimodal trace attachments (images, audio, files) in S3 and serves them to the
**browser via presigned URLs that hit the object store directly** (the web server does not proxy the
bytes). The bundled MinIO is in-container only. The endpoint Langfuse uses to *generate* those presigned
URLs is therefore the endpoint the **browser** must reach.

**Env-schema finding (reproducible).** Searched the built image
(`podman run --rm --entrypoint sh ghcr.io/.../langfuse:dev -c 'grep -rhoE "LANGFUSE_S3_MEDIA_UPLOAD_[A-Z_]+|LANGFUSE_S3_[A-Z_]*EXTERNAL_ENDPOINT" /app'`).
Result: media exposes a **single** endpoint var, `LANGFUSE_S3_MEDIA_UPLOAD_ENDPOINT` (no
`..._EXTERNAL_ENDPOINT`), used for **both** server-side ops and browser presigning. Only batch-export has
a separate `LANGFUSE_S3_BATCH_EXPORT_EXTERNAL_ENDPOINT`.

**httpPorts contract (box-verified).** From the live `agentgateway` app: a manifest `httpPorts` key
becomes the literal runtime env var holding the **FQDN** of the admin-assigned subdomain
(`DATA_PLANE_DOMAIN=gw-api.example.com`, no scheme), `defaultValue` is the subdomain prefix, and
`containerPort` is the port the app listens on.

## Decision

Add one `httpPorts` entry, **key `LANGFUSE_BLOB_DOMAIN`**, `containerPort` **9100** (the MinIO S3 API —
not the 9101 console), `defaultValue` `langfuse-blob`. At runtime `start.sh` sets
`LANGFUSE_S3_MEDIA_UPLOAD_ENDPOINT=https://${LANGFUSE_BLOB_DOMAIN}` and keeps
`LANGFUSE_S3_MEDIA_UPLOAD_FORCE_PATH_STYLE=true`.

Supporting requirements:

- **Public access on the blob subdomain — NO `proxyAuth`.** The browser performs presigned PUT/GET
  directly; any Cloudron auth interception breaks it. Security here is the S3 SigV4 signature + a private
  bucket, not a Cloudron session. Consistent with the app's overall no-`proxyAuth` model.
- **MinIO binds `0.0.0.0:9100`** (not loopback) so the Cloudron proxy can reach it on the container IP;
  the console stays `127.0.0.1:9101`. Event/batch uploads keep the internal `http://localhost:9100`.
- **Private bucket.** The `langfuse` bucket is created by `mkdir` (private by default); presigned URLs
  are the only grant. Verify no anonymous-read policy is applied.
- **Path-style is mandatory** (`FORCE_PATH_STYLE=true`): one subdomain can't do virtual-host bucket
  addressing without wildcard DNS. Objects live at `https://<blob>/langfuse/<key>`, matching the signed
  canonical request.

## Why not a path proxy on the primary domain

S3 **SigV4 signs the canonical URI**. Routing media under a path (e.g. `/blob/...`) and stripping the
prefix at the proxy changes the path MinIO recomputes the signature over, so every signature fails.
A separate hostname with the path preserved 1:1 is the only clean fix.

## Why enable now (irreversibility)

`httpPorts` cannot be added cleanly after install, and this is a **stateful** app — "add media later"
means a reinstall and a data migration across Postgres + ClickHouse + MinIO. Enabling now and not using
media costs one idle subdomain; shipping without and needing it later costs real data pain. The
asymmetry is one-sided, and multimodal media is core Langfuse surface for a reusable package.

## Must prove on the box (Phase 4) — all signature-critical

1. **Host-header preservation:** the Cloudron proxy forwards `Host: <blob-subdomain>` unmodified to
   MinIO (else the recomputed signature breaks).
2. **End-to-end signature:** a real multimodal upload AND a browser preview/download — not just a 200 on
   the bucket root.
3. **Hairpin:** the container's own processes can reach `https://<blob-subdomain>` (the single endpoint
   forces server + browser onto the same host, so server-side ops loop out to the proxy and back).
   **Fallback held in reserve, not pre-implemented:** a split-horizon `/etc/hosts` entry mapping the
   blob subdomain to local MinIO so server-side stays in-container while the signed `Host` string is
   identical. Prove the hairpin first.

## Consequences

Feeds field guide 0.1.2 as "presigned S3 media behind the Cloudron proxy". If a future Langfuse adds a
dedicated media external-endpoint var, revisit to split server-side (internal) from presign (public) and
avoid the hairpin entirely.
