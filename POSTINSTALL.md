## Langfuse is installed 🎉

**This is a full web app with its own login.** Open the app and create your account.

<sso>
You can sign in with your Cloudron account (single sign-on via OIDC), or create a Langfuse-native
email/password account. The first user to sign up becomes the owner.
</sso>
<nosso>
Create the first Langfuse account by signing up at the app's URL. The first user to sign up becomes
the owner.
</nosso>

### Sending traces (integrations)

Trace ingestion does **not** use Cloudron login — it uses **Langfuse project API keys**:

1. In Langfuse, create an Organization → Project.
2. In **Project settings → API keys**, create a key pair (public `pk-…` + secret `sk-…`).
3. Point your SDK / OpenTelemetry exporter at this app's URL with that key pair. The OTLP endpoint is
   `…/api/public/otel/v1/traces`.

The public API (`/api/public/*`) is intentionally reachable without Cloudron SSO so that integrations
can ingest with their API keys.

### Media (multimodal traces)

Image / audio / file attachments on traces are stored in the bundled object storage and served to your
browser from a separate **media subdomain** (you assign it at install). That subdomain is public by
design and secured by signed, expiring URLs over a private bucket — it has no browseable listing and no
Cloudron login in front of it (a login wall would break the signed-URL flow).
