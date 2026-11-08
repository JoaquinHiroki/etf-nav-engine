# etf-nav-engine

A single-process OCaml service that keeps ETF net asset value current from a Kafka event
stream, recomputing only what each event changes. After every event the incremental result
must equal a full recompute exactly.

Status: stage 1 of 10. See [docs/roadmap.md](docs/roadmap.md).

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
| `make up` / `make down` | Start or stop Redpanda and Postgres |
| `make check` | Connect to both services from OCaml |
| `make fmt` | Format the code |

## Layout

```
bin/          entry points
lib/domain/   events, compositions, NAV formulas
lib/source/   replayable event sources
test/         expect and property tests
docs/         roadmap and architecture decisions
```
