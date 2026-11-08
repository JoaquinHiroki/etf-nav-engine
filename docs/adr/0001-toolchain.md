# 0001: Toolchain

Date: 2026-11-08
Status: accepted

## Context

The engine needs Jane Street's `core`, `incremental` and `bin_prot`, a Kafka client and a
Postgres client in one opam switch. Constraints checked against the opam repository:

| Package | Versions | OCaml |
|---------|----------|-------|
| `kafka` (librdkafka bindings) | 0.5, latest | `>= 4.02.3 & < 5.0.0` |
| `kafka-eio` | 0.1.1, only release | `>= 5.4.0`, requires Eio |
| `core`, `incremental`, `ppx_jane` | v0.16 | `>= 4.14.0` |
| `core`, `incremental`, `ppx_jane` | v0.17 | `>= 5.1.0` |
| `postgresql` | 5.2.0 | `>= 4.12` |
| `postgresql` | 5.3.x | `>= 5.00` |

## Decision

- OCaml 4.14.2, Jane Street v0.16, `kafka` 0.5, `postgresql` 5.2.0.
- Redpanda v24.2.7 as the broker and Postgres 16.4, both through Docker Compose.
- A local opam switch (`_opam/`) per checkout, created by `make setup`.

`kafka` 0.5 exposes librdkafka's simple consumer, which takes an explicit partition and
start offset. That matches the design: offsets live in Postgres and recovery seeks to
`next_offset`.

`postgresql` is synchronous, which fits the single-threaded blocking loop.

## Consequences

- The Jane Street API in use is v0.16, so v0.17 documentation can differ in places.
- `kafka-eio` on OCaml 5 is the fallback. It would force a move to v0.17 and Eio, so it
  is only worth doing if `kafka` 0.5 fails against current librdkafka.
- System libraries are required: librdkafka and libpq (`brew install librdkafka libpq`,
  or `librdkafka-dev libpq-dev` on Debian).
