# 7. Langfuse v3 to v4 major upgrade

Date: 2026-06-30

## Status

**Placeholder, reserved.** No decision has been taken. This number is held open so the v4 work lands as a
first-class ADR rather than as an amendment to an unrelated one, and so the numbering around it stays
contiguous.

## Context

`AGENTS.md` records the expectation of a **v3 to v4 major** upstream release: v4 work is already visible in
the 3.199 release notes. The package's future-compat design assumes point releases auto-migrate on boot
behind a single `LANGFUSE_VERSION` build ARG, which is true within v3 and cannot be assumed across a major.

## What this ADR will have to decide, when there is something to decide

- Whether the single-ARG bump still holds, or whether v4 needs a distinct build shape.
- The upgrade path for installed v3 data, and whether it is one-way.
- Whether v4 changes the ClickHouse schema in ways that affect the dump-and-restore mechanism adopted in
  [ADR 0006](0006-clickhouse-backup-persistentdirs-triplet.md), which restores with
  `allow_different_table_def=1` and is therefore sensitive to view and dictionary changes.
- Whether the MIT and EE boundary moves, given golden rule 7.

## Notes

Nothing here is a commitment. Delete this file and write the real ADR when upstream ships v4.
