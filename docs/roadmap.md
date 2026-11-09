# Roadmap

Ten stages derived from the technical design's six milestones. Each stage ends with its
exit test passing and a commit.

| # | Stage | Design milestone | Exit test |
|---|-------|------------------|-----------|
| 1 | Skeleton and toolchain | 0 | `make test` passes; `make check` reaches Redpanda and Postgres from OCaml |
| 2 | Event round trip | 0 | CI publishes one `bin_prot` event, consumes it and reads it back from Postgres |
| 3 | Full recompute | 1 | Expect tests for balanced-tree NAV; folding events gives known NAVs |
| 4 | Data at scale | 1 | Seeded generator and PITLake export produce 10M+ events; `replay` sends them at full speed or a fixed rate |
| 5 | Baseline service | 1 | Read-modify-write engine processes a full replay; baseline throughput and latency recorded |
| 6 | Incremental graph | 2 | Property test: incremental NAV is bitwise equal to full recompute after every event |
| 7 | Batched engine | 2 | Batch sizes 1, 100, 1000 give 0 mismatches over a multi-million event replay; recompute counts reported |
| 8 | Optimized write path and recovery | 3 | Crash at random points, restart, final tables equal an uninterrupted run; baseline tables equal optimized |
| 9 | Rebalance state machine | 4 | Transition table test; folding full and compacted logs gives equal state |
| 10 | Benchmarks and report | 5 | `make bench` on a fresh clone reproduces the published numbers |

## 1. Skeleton and toolchain

- Pin OCaml 4.14.2, Jane Street v0.16, `kafka` 0.5, `postgresql` 5.2.0 ([ADR 0001](adr/0001-toolchain.md)).
- Domain types with `bin_prot` encoding: `Event`, `Composition`, `Holding`, `Rebalance_step`.
- `Source` interface with an in-memory implementation.
- Docker Compose with Redpanda and Postgres, Makefile, CI.

## 2. Event round trip

- Kafka `Source` and a minimal producer.
- First migration with the schema from the design.
- Integration test: produce, consume, write, read back.

## 3. Full recompute

- Balanced-tree sum with a fixed shape ([ADR 0002](adr/0002-summation-tree.md)).
- Pure `Full_recompute`: state is a fold over events, NAV and premium per ETF.
- This becomes the test oracle and the computational baseline.
- Rebalance events are ignored until stage 9.

## 4. Data at scale

- Seeded synthetic generator: ETF count, basket size, symbol overlap, rebalance progress events.
- Event file format: length-prefixed `bin_prot` records.
- `replay` tool: file to topic at full speed or a fixed rate.
- Exporter from PITLake Binance trades and Gold minute bars into the event file format (pending).

Measured on the development laptop (Intel MacBook, Redpanda in Docker), 2026-11-08:
generating 10M events takes 12 s and 278 MB on disk; full-speed replay publishes about
715k events/s; fixed-rate replay at 20k/s holds 19,985/s while busy-waiting one core.

## 5. Baseline service

- Engine loop over a `Source`, using full recompute of every affected ETF.
- Baseline Postgres writer: read before write, one transaction per event, readback check
  ([ADR 0003](adr/0003-baseline-and-price-tables.md)).
- `price` and `etf_price` tables so state can be restored after a restart.
- `bin/engine.exe` reports throughput, latency percentiles and database operations.

First numbers, 2026-11-08, on the development laptop (Intel MacBook, Redpanda and
Postgres 16.4 in Docker Desktop, default Postgres settings, `synchronous_commit` on),
synthetic data from `make data` (seed 42, 2,000 symbols, 100 ETFs of 50 holdings):

| Run | Events | Events/s | p50 | p99 |
|-----|--------|----------|-----|-----|
| Engine only, file, batch 1000 | 10M | 81,000 | 11.4 ms | 22.0 ms |
| Engine only, Kafka, batch 1000 | 10M | 38,700 | 21.7 ms | 82.6 ms |
| Baseline writer, Kafka, batch 1 | 20k | 63 | 13.9 ms | 42.6 ms |
| Baseline writer, Kafka, batch 100 | 20k | 83 | 1.16 s | 2.54 s |

Latency is measured per batch, from the poll that returned it to the end of its write.
Each event recomputes 2.5 ETFs on average. The baseline makes 8.4 statements per event
plus BEGIN/COMMIT, 2.0 reads per write. Single runs, not yet the five-run median.

## 6. Incremental graph

- One `Incremental` variable per symbol, shared across ETFs
  ([ADR 0004](adr/0004-incremental-graph.md)).
- `bind` on composition so swaps replace the ETF subgraph.
- Bitwise cutoff on every float node.
- Recompute counter inside node functions.
- Property test: after every event, NAV, premium and ETF price equal `Full_recompute` bit
  for bit, on random streams with edge-case floats and on a synthetic stream.

Node recomputations over the test's synthetic stream (30,000 events, 120 symbols, 8 ETFs
of 32 holdings, stabilizing after every event), compared with the work `Full_recompute`
does for the same events:

| Nodes | Full recompute | Incremental | Ratio |
|-------|----------------|-------------|-------|
| Positions (`units *. price`) | 1,926,912 | 63,711 | 30.2x |
| Sums | 1,866,696 | 300,614 | 6.2x |

A tick recomputes one leaf instead of 32 and five sums (log2 32) instead of 31. These
are node counts, not time; stage 7 measures throughput with batched stabilization.

## 7. Batched engine

- Apply a batch, stabilize once; observers per ETF NAV and premium.
- Per-event latency measured against scheduled send time.
- Oracle check running alongside multi-million event replays.

## 8. Optimized write path and recovery

- State held in memory, multi-row upserts, one transaction per batch.
- `next_offset` committed with state; advisory lock at startup.
- Recovery: load state, rebuild graph, seek, replay. Kill-and-restart test harness.

## 9. Rebalance state machine

- `step`, `fold`, `compact` with an explicit transition table.
- `Apply` swaps the live composition.
- Compaction only on settled or rejected rebalances; storage measured.

## 10. Benchmarks and report

- `Core_bench` microbenchmarks by basket size and overlap.
- Five runs, median and range, machine and Postgres settings recorded.
- README with results, including the cases where incremental loses.
