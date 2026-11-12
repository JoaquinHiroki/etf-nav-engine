# etf-nav-engine

A single-process OCaml service that keeps ETF net asset values current from a Kafka event stream, recomputing only the part of the graph each event affects. After every event the incremental result must equal a full recompute exactly, and state is persisted to Postgres so the engine recovers exactly after a crash.

- Prices, ETF prices, compositions and rebalance steps arrive as `bin_prot` events from
  Redpanda or from a file.
- Two models: `full` recomputes every affected ETF from scratch over a fixed-shape
  summation tree; `incremental` shares one node per symbol across ETFs with Jane Street's
  `Incremental`, stabilizing once per batch. `checked` runs both and compares them bit
  for bit.
- Two Postgres writers: a baseline that reads before writing and commits every event,
  and an optimized one that keeps state in memory and commits once per batch, together
  with the next offset to read.
- Recovery loads state, rebuilds the graph and replays from the committed offset; a
  kill-and-restart test checks that the final tables equal an uninterrupted run.
- Rebalances follow an explicit state machine with a stored transition log that can be
  compacted while the engine runs.

## Results

10M synthetic events (2,000 symbols, 100 ETFs of 50 holdings), on an Intel MacBook Pro
(i5-8257U, 8 GiB) with Postgres 16.4 in Docker Desktop. Median of five rounds; full
output in [bench/results.md](bench/results.md), discussion in
[docs/roadmap.md](docs/roadmap.md#10-benchmarks-and-report).

| Model | Writer | Batch | Events/s | p50 | p99 |
|-------|--------|-------|----------|-----|-----|
| full | none | 1 | 71,400 | 10 µs | 49 µs |
| full | none | 1000 | 64,800 | 12.6 ms | 40.9 ms |
| incremental | none | 1 | 117,100 | 6 µs | 27 µs |
| incremental | none | 1000 | 377,900 | 1.83 ms | 4.85 ms |
| incremental | baseline | 1 | 105 | 8.75 ms | 23.9 ms |
| incremental | optimized | 1 | 259 | 3.44 ms | 9.66 ms |
| incremental | optimized | 1000 | 33,200 | 25.6 ms | 87.2 ms |

Latency is per batch, from poll to write. Over the whole stream the incremental engine
gives 0 mismatches against full recompute at batch sizes 1, 100 and 1000.

- At batch 1000, incremental is 5.8 times faster than full recompute; at batch 1, 1.6
  times, although it evaluates 15 times fewer nodes.
- The optimized writer at batch 1000 is 316 times faster than the baseline and 11 times
  slower than the engine without a writer.
- The laptop throttles under sustained load: a single run varies by up to 40%, and the
  ranges in [bench/results.md](bench/results.md) are wide.

## Where incremental loses

From the microbenchmarks in [bench/micro.ml](bench/micro.ml), on 16 ETFs:

- **Composition swaps**: 1.4 to 2.6 times slower than full recompute at every basket
  size, because the graph builds a new subgraph for the ETF.
- **Every symbol moving between reads**: 1.4 to 2.5 times slower. Nothing is shared with
  the previous step, so Incremental's bookkeeping per node is pure cost.
- **Small baskets held by several ETFs**: at 8 holdings with each symbol in 4 ETFs, a
  tick is 1.1 to 2.3 times slower.
- **Batch size 1 in the engine**: the gain shrinks to 1.6 times, because decoding,
  lookups and the cost of each stabilization outweigh the summation saved.

With baskets of 32 holdings or more, one tick is 1.4 to 29 times faster.

## Reproducing

Requirements and setup are in [docs/development.md](docs/development.md). Then:

```sh
make setup
caffeinate -i make bench    # about 1 h 10 min; writes bench/results.md
```

`make bench` generates the event file if it is missing, stops Redpanda, starts Postgres,
and records the machine, Docker, Postgres and generator settings next to the numbers.
`SCALE=0.1 RUNS=1 make bench` gives a quick check.

## Documentation

- [docs/development.md](docs/development.md): setup, commands, services, layout
- [docs/roadmap.md](docs/roadmap.md): the ten stages, with what each measured
- [docs/adr/](docs/adr/): design decisions
