CREATE TABLE IF NOT EXISTS composition (
  etf text NOT NULL,
  version int NOT NULL,
  effective_ts timestamptz NOT NULL,
  holdings jsonb NOT NULL,
  cash double precision NOT NULL,
  shares_outstanding double precision NOT NULL,
  PRIMARY KEY (etf, version)
);

CREATE TABLE IF NOT EXISTS nav_snapshot (
  etf text PRIMARY KEY,
  -- NULL while some holding has no price (ADR 0006).
  nav double precision,
  premium double precision,
  source_offset bigint NOT NULL,
  ts timestamptz NOT NULL
);

CREATE TABLE IF NOT EXISTS rebalance_transition (
  etf text NOT NULL,
  rebalance_id int NOT NULL,
  -- Source offset of the row's first step (ADR 0007).
  seq bigint NOT NULL,
  -- Phase after the row's steps; detail holds the steps.
  state text NOT NULL,
  detail jsonb,
  first_ts timestamptz NOT NULL,
  last_ts timestamptz NOT NULL,
  merged_count int NOT NULL DEFAULT 1,
  PRIMARY KEY (etf, rebalance_id, seq)
);

CREATE TABLE IF NOT EXISTS consumer_offset (
  topic text PRIMARY KEY,
  next_offset bigint NOT NULL
);

CREATE TABLE IF NOT EXISTS price (
  symbol text PRIMARY KEY,
  price double precision NOT NULL,
  source_offset bigint NOT NULL,
  ts timestamptz NOT NULL
);

CREATE TABLE IF NOT EXISTS etf_price (
  etf text PRIMARY KEY,
  price double precision NOT NULL,
  source_offset bigint NOT NULL,
  ts timestamptz NOT NULL
);

-- Databases created before ADR 0006 and 0007.
ALTER TABLE nav_snapshot ALTER COLUMN nav DROP NOT NULL;
ALTER TABLE rebalance_transition ALTER COLUMN seq TYPE bigint;
