# etf-nav-engine

A single-process OCaml service that keeps ETF net asset value current from a Kafka event
stream, recomputing only what each event changes. After every event the incremental result
must equal a full recompute exactly.

Status: stage 3 of 10. See [docs/roadmap.md](docs/roadmap.md).

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
| `make fmt` | Format the code |

## Services

| Service | Address | Notes |
|---------|---------|-------|
| Redpanda | `localhost:9092` | Topics `etf.events.v1` and `etf.events.test`, one partition each |
| Postgres | `localhost:55432` | User, password and database `nav`; tests use `nav_test` |

## Layout

```
bin/          entry points
lib/config/   connection settings, overridable by environment
lib/domain/   events, compositions, NAV formulas
lib/graph/    summation tree and full recompute
lib/source/   replayable event source interface and in-memory source
lib/kafka/    Kafka consumer (a Source) and producer
lib/store/    Postgres persistence
sql/          schema
scripts/      topic and database setup
test/         unit, expect and property tests
test/integration/  tests against Redpanda and Postgres
docs/         roadmap and architecture decisions
```
