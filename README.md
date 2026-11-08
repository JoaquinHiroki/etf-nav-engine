# etf-nav-engine

A single-process OCaml service that keeps ETF net asset values current from a Kafka event stream, recomputing only the part of the graph each event affects. After every event the incremental result must equal a full recompute exactly, and state is persisted to Postgres so the engine recovers exactly after a crash.
