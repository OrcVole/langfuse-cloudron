# 10. Successor for the bundled MinIO object store

Date: 2026-07-31

## Status

**Open question, deliberately NOT scoped into v0.2.0.** Raised by the operator during the v0.2.0
backup work. Recorded now so the constraints are written down while they are fresh; no decision is
taken here.

## Context

Langfuse v3 requires S3-compatible object storage. It is not optional and there is no filesystem
backend: event blobs (`LANGFUSE_S3_EVENT_UPLOAD`) and media attachments (`LANGFUSE_S3_MEDIA_UPLOAD`)
both go through the S3 API. This package therefore bundles MinIO, which is why MinIO exists in the
image at all.

The concern is MinIO's licensing and product direction: functionality has been moving out of the
freely licensed community build, and the community edition's future is not something this package
should assume. This is a supply-chain and sustainability question rather than a technical fault, and
nothing is broken today.

**The immediate exposure is low.** `Dockerfile` pins MinIO **by digest**, so upstream changes reach
this package only when someone deliberately bumps the pin. There is no auto-drift. That buys time to
choose properly rather than reacting.

## What any successor must satisfy

These are the real constraints, and they are stricter than "speaks S3":

1. **Presigned URLs, SigV4.** [ADR 0004](0004-s3-presigned-media-routing.md) routes media to the
   browser through presigned URLs on a public subdomain, secured by request signatures over a private
   bucket. A candidate that lacks correct presigned GET and PUT is disqualified outright, because the
   alternative is putting a login wall in front of the media path, which breaks the signed-URL flow.
2. **Path-style addressing.** The package sets `..._FORCE_PATH_STYLE=true`; virtual-host-style
   addressing would need a wildcard subdomain per bucket, which Cloudron does not give us.
3. **Single-node, single-drive, small footprint.** This is an embedded store inside one app container,
   not a cluster. On a real install it holds on the order of 100 KB.
4. **Restorable from a plain file copy.** v0.2.0's `backupCommand` copies the store as a file tree
   ([ADR 0006](0006-clickhouse-backup-persistentdirs-triplet.md)). A candidate whose on-disk state is
   not coherent when copied would need its own dump mechanism, which is a materially bigger change.
5. **A permissive or at least stable licence**, since replacing MinIO for licensing reasons only to
   inherit the same risk would be pointless.
6. **Runs as a single static binary on `cloudron/base`**, matching how MinIO is bundled today.

## Candidates named so far

Recorded as leads to evaluate, not as recommendations. None has been tested against this package.

- **SeaweedFS** (Apache 2.0). Mature, actively developed, provides an S3 API layer. Its S3 surface is
  a gateway in front of its own storage model rather than a native object layout, so constraint 4
  needs checking carefully.
- **RustFS** (Apache 2.0). Positions itself as a MinIO-shaped S3 store. Young; maturity and the
  completeness of its presigned-URL support are exactly what would need proving before trusting user
  media to it.
- **Garage** (AGPL-3.0). Built for small self-hosted deployments, which fits constraint 3 well.
- **Staying on the pinned MinIO digest.** The null option, and a legitimate one while the pin holds
  and nothing is broken.

## Why this is not v0.2.0 work

v0.2.0 exists to stop this app aborting the whole rig's backup run. Swapping the object store would
change the data layout, require its own migration for existing installs' blobs, and need its own
backup and restore gate, on top of the ClickHouse migration that is already the riskiest thing in the
release. Bundling the two would put both at risk.

Note also that v0.2.0 makes this decision **easier to act on later**, not harder: MinIO's store is now
behind a `persistentDir` with an explicit copy-out and copy-back path, so a future swap has a defined
seam to work at rather than being tangled into `/app/data`.

## Next step, when someone picks this up

Evaluate candidates against constraint 1 first, with a real presigned round trip through the media
subdomain, because that is the constraint most likely to disqualify one and the cheapest to test. Do
it on a throwaway, not against an install holding media.
