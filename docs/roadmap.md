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

- Apply a batch, stabilize once; observers per ETF NAV and premium
  ([ADR 0005](adr/0005-batched-engine.md)).
- Only ETFs whose NAV or premium changed are reported, on the batch's last change.
- Per-event latency measured against scheduled send time (`-scheduled`, from stage 5).
- Oracle check running alongside multi-million event replays: `-model checked` and
  `make oracle`.

Measured 2026-11-09 on the development laptop (Intel MacBook), reading the 10M-event
file from `make data` (seed 42, 2,000 symbols, 100 ETFs of 50 holdings) with
`-writer none`. Single runs.

`make oracle`: 0 mismatches at batch sizes 1, 100 and 1000, over 24.6M, 9.2M and 1.0M
ETF checks.

| Model | Batch | Events/s | p50 | p99 | NAV updates |
|-------|-------|----------|-----|-----|-------------|
| full | 1 | 102,900 | 8 µs | 31 µs | 24,570,397 |
| full | 100 | 105,700 | 867 µs | 1.70 ms | 24,570,397 |
| full | 1000 | 99,400 | 9.27 ms | 15.9 ms | 24,570,397 |
| incremental | 1 | 190,000 | 4 µs | 17 µs | 24,570,397 |
| incremental | 100 | 258,900 | 282 µs | 1.10 ms | 9,167,591 |
| incremental | 1000 | 418,100 | 1.66 ms | 4.21 ms | 999,807 |
| checked | 1 | 37,900 | 20 µs | 99 µs | 24,570,397 |
| checked | 100 | 88,800 | 1.06 ms | 1.68 ms | 9,167,591 |
| checked | 1000 | 282,800 | 3.07 ms | 4.86 ms | 999,807 |

Latency is per batch, from poll to write. The stage 5 run of `full` at batch 1000 gave
81,000 events/s; single runs vary, which stage 10's five-run medians will settle.

Node recomputations by the incremental graph. Full recompute evaluates about 1.23
billion positions and 1.20 billion sums for the same stream (50 and 49 per ETF update):

| Batch | Positions | Sums | NAVs |
|-------|-----------|------|------|
| 1 | 24,405,114 | 139,439,790 | 24,370,471 |
| 100 | 23,823,969 | 101,939,907 | 9,150,469 |
| 1000 | 19,311,294 | 38,298,483 | 999,907 |

At batch 1 the graph evaluates 50 times fewer positions and 8.6 times fewer sums, but
runs only 1.85 times faster: per-event costs outside the summation (decoding, lookups,
Incremental's bookkeeping) dominate and are not yet profiled. Larger batches share the
upper levels of each tree and report each ETF once per batch; at 1000 the incremental
engine runs 4.2 times faster than full recompute. At batch 1 it reports exactly as many
NAV updates as full recompute, since every tick in this data moves the NAV.

## 8. Optimized write path and recovery

- Snapshots hold the values after the last event that affected each ETF, with its
  offset, so tables do not depend on batching ([ADR 0006](adr/0006-write-path-and-recovery.md)).
- State held in memory, multi-row upserts, one transaction per batch.
- `next_offset` committed with state; advisory lock at startup.
- Recovery: load state, rebuild graph, seek, replay. Kill-and-restart test harness.

Measured 2026-11-11 on the development laptop (Intel MacBook, Postgres 16.4 in Docker
Desktop, default settings, `synchronous_commit` on). Single runs.

`make integration`: on 3,000 events, restarted baseline runs, optimized runs at batch
sizes 1, 50 and 1000, and a run that switches writer and batch size twice all give the
baseline's tables. The crash test killed the engine 3 times on 200,000 events
(`CRASH_SEED=84000`, at `next_offset` 16,200, 101,448 and 187,362) and the final tables
equal the uninterrupted run.

`make oracle`: 0 mismatches and 0 batches with different affected ETFs at batch sizes
1, 100 and 1000, over 24.6M, 9.2M and 1.0M ETF checks. Recompute counts equal stage 7's.
Throughput was 20,500, 54,100 and 138,900 events/s, about half of stage 7's runs; these
ran with Redpanda and Postgres up, and the model now tracks the last affecting offset per
ETF. The two have not been separated.

Writers, reading the 10M-event file from `make data` with the incremental model.
Statements count each multi-row upsert once:

| Writer | Batch | Events | Events/s | p50 | p99 | Reads/event | Writes/event | Transactions |
|--------|-------|--------|----------|-----|-----|-------------|--------------|--------------|
| baseline | 1 | 20k | 60 | 12.3 ms | 70.4 ms | 8.91 | 4.45 | 20,000 |
| baseline | 100 | 20k | 64 | 1.46 s | 4.81 s | 5.83 | 2.92 | 20,000 |
| optimized | 1 | 20k | 109 | 7.6 ms | 40.2 ms | 0 | 2.92 | 20,000 |
| optimized | 100 | 1M | 3,340 | 21.3 ms | 183 ms | 0 | 0.039 | 10,000 |
| optimized | 1000 | 10M | 32,000 | 24.3 ms | 117 ms | 0 | 0.0041 | 10,000 |

The baseline stays near 60 events/s at any batch size, because it still commits once per
event. Without reads, the optimized writer at batch 1 is 1.8 times faster. Above that,
a transaction costs about 30 ms whether it holds 100 events or 1000, so throughput grows
with batch size: at 1000 it writes 530 times faster than the baseline at batch 1. Postgres
now limits the service: the same computation runs at 418,100 events/s with `-writer none`
(stage 7).

## 9. Rebalance state machine

- `step`, `fold`, `compact` with an explicit transition table
  ([ADR 0007](adr/0007-rebalance-state-machine.md)).
- `Apply` swaps the live composition, in both models.
- Every accepted step stored in `rebalance_transition` and replayed on recovery.
- Compaction only on settled or rejected rebalances, safe while the engine runs;
  storage measured.

`make test`: over 2,000 generated streams with dropped, repeated and stray steps (17,921
log rows, 23,241 rejected steps, every phase reached), folding the full and compacted
logs gives the state built step by step. On a 100,000-event synthetic stream, 3,936 steps
give 0 invalid steps and 3,936 rows, 816 after compaction (156 settled rebalances of 20
holdings, 18 rejected). The random-stream property test applies a rebalance in 2,909 of
its 10,000 streams and stays bit for bit equal to full recompute.

Measured 2026-11-11 on the development laptop (Intel MacBook, Postgres 16.4 in Docker
Desktop, default settings), reading the 10M-event file from `make data`. Single runs.

`make integration`: restarted, optimized, mixed and compacted runs give the baseline's
tables, and folding each stored log gives `Full_recompute`'s rebalances. The crash test
killed the engine 8 times on 200,000 events (`CRASH_SEED=767000`), twice after compacting
while it ran, and the final tables equal the uninterrupted run once both are compacted.

`-model checked` at batch 1000: 0 mismatches and 0 batches with different affected
ETFs over 1.0M ETF checks, with 51,675 accepted rebalance steps and 0 invalid ones.
Applied rebalances raise the subgraphs built from 607 to 1,543.

With the optimized writer at batch 1000 the engine ran at 26,400 events/s (p50 29.2 ms,
p99 149 ms), against 32,000 in stage 8, making 4.7 statements per batch instead of 4.1.
Compaction of the resulting log:

| | Rows | Bytes |
|-|------|-------|
| Before | 51,675 | 10,159,300 |
| After | 4,925 | 2,755,476 |

Compaction rewrote 935 rebalances: 10.5 times fewer rows and 3.7 times fewer bytes. Bytes
fall less than rows because the holdings stay in the merged `applying` rows' detail; what
goes is each row's header and repeated columns. A second `make compact` rewrote nothing.

## 10. Benchmarks and report

- `Core_bench` microbenchmarks by basket size and overlap.
- Five runs, median and range, machine and Postgres settings recorded.
- README with results, including the cases where incremental loses.
