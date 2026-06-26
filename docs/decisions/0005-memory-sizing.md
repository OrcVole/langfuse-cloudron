# 5. Memory sizing: memoryLimit and the ClickHouse cap

Date: 2026-06-26

## Status

Accepted (Phase-4, operator-confirmed).

## Context

Measured on the box (12-core host) under a heavy sustained burst (7200 events, deep worker backlog,
0 errors). Idle ≈ 1.7 GiB; **peak cgroup high-water ≈ 2.58 GiB**. Breakdown at peak:

| Process | RSS | Threads |
|---|---|---|
| web (`next-server`) | 936 MB | 24 |
| ClickHouse | 826 MB | 742 |
| worker (node-musl) | 537 MB | 24 |
| MinIO | 211 MB | 70 |
| base (CH-watchdog + supervisord + musl) | ~140 MB | — |

The binding constraint is **not** the observed ingestion peak but the **worst case**: a heavy analytical
dashboard query driving ClickHouse toward its **2 GiB cap** (`max_server_memory_usage`) *at the same
time* as active ingestion (two Node procs ~1–1.2 GiB each worst case + MinIO + base) → a **~4.6 GiB**
bound. The cgroup OOM-kills on simultaneous peak, so the limit must clear the worst case with margin.

## Decision

Ship **`memoryLimit` = 5 GiB (`5368709120`)**, keep the **ClickHouse cap at 2 GiB**
(`<max_server_memory_usage>2147483648</max_server_memory_usage>`). 5 GiB clears the 4.6 GiB worst-case
bound with ~800 MB margin, preserves the full 2 GiB ClickHouse budget for dashboards, and still tightens
a full gigabyte off the 6 GiB provisional.

**Why 5 GiB lands above the original 3–4 GiB estimate:** the 2 GiB ClickHouse cap is the term that pushes
the worst-case bound up; the estimate predated that cap being set.

### Rejected / alternatives

- **4.5 GiB** — sits ~100 MB above the 4.6 GiB bound; a rare CH-query-plus-ingest moment would
  OOM→restart. A restart is no data loss here (ENCRYPTION_KEY is safe), but a packaged app others
  install should not ship a known occasional OOM.
- **4 GiB + ClickHouse cap 1.5 GiB** (`max_server_memory_usage=1610612736`) — the right answer for a
  **RAM-constrained** box: it buys headroom by starving heavy analytical queries. **Documented operator
  knob, not the shipped default.**

## CPU / cgroup-awareness (field-guide §8)

**Ship the default.** ClickHouse (737 threads) and MinIO (66 threads) auto-detect cores; on the test box
`nproc=12` with `cpu.max` unlimited → correct for the common case. Node runs JS single-threaded per
process (web + worker split + threadpools give the parallelism). We do **not** add cgroup-CPU-aware
ClickHouse pools to this release (scope creep on a gate-complete package). Caveat: if an operator sets a
Cloudron CPU limit, ClickHouse/Node read `nproc` (not the cgroup quota) and over-subscribe threads →
throttling. Documented as an operator hardening; flagged for field guide 0.1.2.

## Consequences

- Manifest `memoryLimit` = `5368709120`. ClickHouse `config.d` cap unchanged at 2 GiB.
- `docs/PACKAGING-NOTES.md` documents the constrained-box pairing (4 GiB / CH 1.5 GiB) + the CPU caveat.
- Re-measure if a future Langfuse changes the worker's default concurrency or ClickHouse's footprint.
