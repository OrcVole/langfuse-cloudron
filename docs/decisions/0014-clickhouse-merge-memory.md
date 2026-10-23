# 14. ClickHouse merge memory: a 4 GiB cap, four merge threads, an 8 GiB app

Date: 2026-10-23

## Status

Accepted. Ships in v0.13.2. Revises the ClickHouse cap of [ADR 0005](0005-memory-sizing.md) (2 GiB, raised to
2.5 GiB in v0.3.0) and the app's `memoryLimit` (5 GiB, then 6 GiB).

## Context

After a production install moved from 0.11.0 to 0.13.1 (404,000 events, ClickHouse RSS 1.40 GiB at rest), one
background merge of `events_full` failed with `MEMORY_LIMIT_EXCEEDED` in a loop, about 1.4 times a second
("would use 2.51 GiB ... maximum: 2.50 GiB ... while reading column metadata_values"). Health stayed 200 and
queries worked, but the partition's parts climbed, the 30-day retention could not drop old rows, and the log
filled with stack traces. A small canary showed nothing.

Two facts explain it:

1. Langfuse creates `events_full` with full-text indexes on `input`, `output`, `metadata_values` and
   `metadata_names` at `GRANULARITY 100000000`, which is one index granule per part. Every insert and every
   merge builds the index for the whole resulting part in memory, so merge memory grows with the merged part.
   The table also sets `index_granularity_bytes` and `merge_max_block_size_bytes` to 64 MiB, six times the
   ClickHouse default. Neither is ours to change: they are upstream's schema, and its migrations own them.
2. ClickHouse runs up to 32 merges at once by default (`background_pool_size` 16 times the concurrency ratio
   of 2), and its cap is enforced against RSS, which includes allocator memory not yet returned.

## Decision

- `max_server_memory_usage` **4 GiB** (was 2.5 GiB). Still absolute, never a ratio (ADR 0005).
- `background_pool_size` **4**, so at most 8 merges run at once. The three `merge_tree` thresholds
  `number_of_free_entries_in_pool_to_execute_mutation`, `..._to_lower_max_size_of_merge` and
  `..._to_execute_optimize_entire_partition` go to **4**: above the pool ClickHouse refuses to start (Code 36),
  which a first test of this change hit.
- `memoryLimit` **8 GiB** (was 6 GiB), so the web and worker processes (about 1.3 GiB at rest) keep their
  headroom beside the larger cap.

## Evidence

Measured 2026-10-23 on the 0.13.1 image with this change mounted as a `config.d` override, under a 12-CPU quota
(production has 12 cores; ClickHouse sizes its pools by cores), filling `events_full` with 800 inserts of 500
production-shaped rows (input about 10 KB per row, compressing about 9 to 1; metadata about 900 bytes,
compressing about 175 to 1), one insert every half second, then watching four minutes:

| | 0.13.1 as shipped | this change |
|---|---|---|
| merge failures (`MemoryLimitExceeded` from `MergeTreeBackgroundExecutor`) | 763 | 30 |
| active parts at the end | 75 | 8 |
| failed inserts, of 800 | 518 | 56 |
| container memory peak, page cache included | 3.8 GiB (limit 6) | 6.3 GiB (limit 8) |
| OOM kills | 0 | 0 |

The synthetic load is harsher than production's: on 0.13.1 it fails inserts within the first 4,000 rows,
where the production install ingests normally. A variant with the cap at 3.5 GiB inside 6 GiB still failed 249
of 800 inserts and peaked at 5.4 GiB, which is why the app limit rises with the cap.

## Consequences

- An install on the default memory limit gets 8 GiB with the update. One whose limit was changed by hand
  should be raised to at least 8 GiB (the CHANGELOG says so).
- Merges are slower to start under bursts, by design. With the data sizes this package targets, 8 concurrent
  merges is ample.
- If upstream changes the text indexes (granularity or columns), revisit: the cap is sized for their merge cost.
- Not proven on the Proving Ground: its apps run with no memory limit (`memoryLimit -1`), so the 8 GiB limit is
  confirmed on production after the update, by `docker stats` and the merge errors stopping.
