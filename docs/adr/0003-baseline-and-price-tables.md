# 0003: Baseline service and price tables

Date: 2026-11-08
Status: accepted

## Context

The design compares a baseline write path with an optimized one. The baseline must be
code one would honestly write first, not a deliberately slowed version.

The design's schema stores compositions, NAV snapshots, rebalance transitions and the
consumer offset. NAV depends on the latest price of every holding, so after a restart the
engine cannot recompute NAV from those tables alone.

## Decision

Add two tables, `price` and `etf_price`, each holding the latest price, its source offset
and timestamp. Recovery loads compositions and both price tables, then seeks to
`next_offset`.

The baseline engine computes in memory with `Full_recompute`, recomputing every affected
ETF from all its holdings. Its writer, for each event:

1. Opens a transaction.
2. For the price or composition row and each NAV snapshot: reads the stored version,
   compares it in application code, writes, then reads the row back to confirm.
3. Does the same for `consumer_offset.next_offset`.
4. Commits.

Versions are source offsets for prices and snapshots, and composition versions for
compositions. `Store` counts reads, writes and transactions.

## Consequences

- Restarting from Postgres reproduces an uninterrupted run exactly; the baseline
  integration test checks this.
- The baseline makes about ten round trips per event, with 2.0 reads per write.
- Writing every price makes the price table the hottest table; the optimized path will
  batch these upserts.
