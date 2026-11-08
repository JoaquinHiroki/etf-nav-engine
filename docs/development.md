# Development

Status: stage 4 of 10. See [roadmap.md](roadmap.md).

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
| `make integration` | Publish an event, consume it and persist it through Postgres |
| `make check` | Connect to both services from OCaml |
| `make data` | Generate `data/generated/synthetic.events` (`EVENTS=10000000` by default) |
| `make replay` | Publish the generated file to `etf.events.v1` at full speed, or at `RATE=N` events per second |
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

## Layout

```
bin/          entry points
lib/config/   connection settings, overridable by environment
lib/domain/   events, compositions, NAV formulas
lib/graph/    summation tree and full recompute
lib/data/     event file format and synthetic generator
lib/source/   replayable event source interface and in-memory source
lib/kafka/    Kafka consumer (a Source) and producer
lib/store/    Postgres persistence
sql/          schema
scripts/      topic and database setup
test/         unit, expect and property tests
test/integration/  tests against Redpanda and Postgres
docs/         roadmap and architecture decisions
```
