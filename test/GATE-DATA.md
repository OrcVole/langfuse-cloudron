# Gate data: how to put real records in, and count them

Gate 3 means the update is proven over real data: records the application stores, counted before the
update, after it, and after a restore. A health check, a sign-in page or a directory existing is not
data. Use at least three records of each kind you count; a count may grow across the update (the app
or a suite can add records), but a count that falls is data loss.

Every command names the Cloudron you are gating. `CLOUDRON_SERVER` is that Cloudron's API host (for
example `my.example.com`); `APP` is the install's location. Never rely on the CLI's default profile.

## langfuse

**Unproven on a fresh install.** On 2026-09-14 a fresh install from the feed, provisioned with the test
gate keys, accepted traces on `/api/public/ingestion` while `meta.totalItems` stayed at 0 for the whole
gate: ingestion runs asynchronously through the worker into ClickHouse, and a fresh install did not
land them within the gate's time. Gate langfuse on a standing, already populated fixture, or a clone of
one, rather than seeding a fresh install.

With a populated fixture provisioned with the test-only gate keys `test/gate2.sh` expects:

```bash
AUTH=$(printf '%s:%s' pk-lf-gate0000000000000000000000000000 sk-lf-gate1111111111111111111111111111 | base64 -w0)
curl -s -H "Authorization: Basic $AUTH" "https://$APP/api/public/traces?limit=1" | jq .meta.totalItems
test/gate2.sh "$APP" before   # then update, then:
test/gate2.sh "$APP" after
```

The keys are test-only and published in this repository; never provision them on a real install.
