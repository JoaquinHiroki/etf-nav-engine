# Development

Status: stage 10 of 10. See [roadmap.md](roadmap.md).

## Requirements

- opam 2.1+
- Docker
- librdkafka and libpq

## Setup

```sh
brew install librdkafka libpq
export PATH="$(brew --prefix libpq)/bin:$PATH"
export PKG_CONFIG_PATH="$(brew --prefix libpq)/lib/pkgconfig:$PKG_CONFIG_PATH"
make setup
```

## Commands

| Command | What it does |
|---------|--------------|
| `make build` | Build everything |
| `make test` | Run unit and property tests |
| `make up` / `make down` | Start or stop Redpanda and Postgres, create topics and apply the schema |
| `make integration` | Kafka round trip; baseline and optimized writers give equal tables, with and without compaction; kill-and-restart test with compaction while running |
| `make check` | Connect to both services from OCaml |
| `make data` | Generate `data/generated/synthetic.events` (`EVENTS=10000000` by default) |
| `make replay` | Publish the generated file to `etf.events.v1` at full speed, or at `RATE=N` events per second |
| `make engine ARGS="..."` | Run the engine; see the examples below |
| `make compact` | Compact the log of settled and rejected rebalances and print rows and bytes before and after |
| `make oracle` | Check the incremental engine against full recompute over the generated file at batch sizes 1, 100 and 1000 (`MAX_EVENTS=N` to shorten) |
| `make bench` | Run the microbenchmarks and five rounds of engine runs, and write `bench/results.md` (`RUNS`, `SCALE`, `QUOTA` to change; about an hour) |
| `make fmt` | Format the code |

## Services

| Service | Address | Notes |
|---------|---------|-------|
| Redpanda | `localhost:9092` | Topics `etf.events.v1` and `etf.events.test`, one partition each |
| Postgres | `localhost:55432` | User, password and database `nav`; tests use `nav_test` |

## Synthetic data

`make data` writes the event file and a `.settings` file next to it with the generator
configuration and a summary. Publish both with any benchmark that uses the data.

The same seed and settings always produce the same events. The stream starts with a
composition per ETF, a price per symbol and a price per ETF, then interleaves price ticks
(about 97%), ETF prices, composition updates and rebalances. Each rebalance is announced,
then either rejected or validated, applied one holding at a time, applied and settled.

With `RATE`, `replay` sends event *i* at *start + i/RATE* and stamps it with that scheduled
time, so latency can be measured from when the event was due rather than when it was
sent. It busy-waits between events, which keeps one CPU core busy.

## Running the engine

```sh
make engine ARGS="-writer none -input data/generated/synthetic.events -batch 1000"
make engine ARGS="-model full -writer none -input data/generated/synthetic.events -batch 1000"
make engine ARGS="-model full -writer baseline -reset -batch 1 -max-events 20000"
make engine ARGS="-reset -batch 1000"
```

`-model` chooses the computation ([ADR 0005](adr/0005-batched-engine.md)): `incremental`
(the default) stabilizes the graph once per batch, `full` recomputes every affected ETF
after each event as in stage 5, and `checked` runs both and compares them after every
batch, exiting with status 1 on any mismatch.

`-writer none` measures computation only. `-writer optimized` (the default) writes one
transaction per batch without reads ([ADR 0006](adr/0006-write-path-and-recovery.md)), and
`-writer baseline` writes one transaction per event, reading before every write. Both
give the same tables. Only one engine at a time can consume a topic or file: a second
one exits with status 2. Without `-input` the engine reads `etf.events.v1`. `-reset`
truncates the tables and starts from offset 0; without it the engine restores state from
Postgres and continues from the stored offset. Add `-scheduled` when the topic was filled
with `make replay RATE=N` to report latency since each event's scheduled send time.

Rebalance steps go through the state machine of
[ADR 0007](adr/0007-rebalance-state-machine.md). An applied rebalance makes its target
the live composition, every accepted step is stored in `rebalance_transition` and
restored on restart, and rejected steps are counted and ignored. `make compact` can run
while the engine is running.

The engine prints a report with throughput, latency percentiles, node recompute counts,
oracle checks, accepted and invalid rebalance steps, and database reads, writes and
transactions.

## Benchmarks

`make bench` generates the event file if it is missing, then writes `bench/results.md`:
the machine, Docker and Postgres settings, the generator settings, the `Core_bench`
microbenchmarks in `bench/micro.ml`, and the engine runs in `bench/macro.ml`. Each engine
run is a separate process; rounds are interleaved, and each measure is reported as the
median and range over the rounds. Runs with a writer truncate the `nav` database. No
benchmark reads Kafka, so `make bench` stops Redpanda and starts only Postgres; `make up`
brings Redpanda back.

`SCALE=0.1` divides every event count by ten and `RUNS=1` runs one round, for a quick
check. Comparing a new `bench/results.md` with the committed one with `git diff` shows
how far a rerun moved. Close other applications first: the runs are CPU bound, and the
writer runs also depend on Docker's disk. On a laptop, `caffeinate -i make bench` keeps
macOS from sleeping. A failed engine run does not stop the others: its row shows how many
rounds succeeded, and `make bench` exits non-zero after writing the file.

## Layout

```
bin/          entry points
bench/        microbenchmarks, engine benchmark driver and published results
lib/config/   connection settings, overridable by environment
lib/domain/   events, compositions, NAV formulas, rebalance state machine
lib/graph/    summation tree, full recompute and incremental graph
lib/data/     event file format and synthetic generator
lib/source/   replayable event source interface and in-memory source
lib/kafka/    Kafka consumer (a Source) and producer
lib/store/    Postgres persistence
lib/engine/   engine loop, writers, recovery and compaction
sql/          schema
scripts/      topic and database setup
test/         unit, expect and property tests
test/integration/  tests against Redpanda and Postgres
docs/         roadmap and architecture decisions
```
