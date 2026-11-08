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

- Balanced-tree sum with a fixed shape.
- Pure `Full_recompute`: state is a fold over events, NAV and premium per ETF.
- This becomes the test oracle and the computational baseline.

## 4. Data at scale

- Seeded synthetic generator: ETF count, basket size, symbol overlap, rebalance progress events.
- Exporter from PITLake Binance trades and Gold minute bars into the event file format.
- `replay` tool: file to topic at full speed or a fixed rate.

## 5. Baseline service

- Engine loop over a `Source`, using full recompute.
- Baseline Postgres writer: read before write, one transaction per event, readback check.
- End-to-end harness and first baseline numbers.

## 6. Incremental graph

- One `Incremental` variable per symbol, shared across ETFs.
- `bind` on composition so swaps replace the ETF subgraph.
- Recompute counter inside node functions.

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
