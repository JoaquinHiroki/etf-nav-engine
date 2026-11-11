# 0006: Optimized write path and recovery

Date: 2026-11-09
Status: accepted

## Context

Stage 8 requires two equalities: tables written by a run that is killed and restarted
must equal those of an uninterrupted run, and tables written by the optimized path must
equal the baseline's. Under ADR 0005 the incremental model stamped every snapshot with
its batch's last offset, so the tables depended on where batches started. It also left
a snapshot untouched when an ETF's NAV became unknown, so which stale row remained
depended on batching too.

## Decision

**Snapshot rule.** An ETF's `nav_snapshot` row holds its NAV and premium after the last
event that affected it, with that event's offset and timestamp. An event affects the
ETFs that hold its symbol, the ETF its price is for, or the ETF of a newer composition,
as `Full_recompute.apply` defines. `nav` is NULL while some holding has no price.

The graph tracks holders the same way `Full_recompute` does and reports affected ETFs
from `apply`. Each `Nav_update` carries its own `source_offset` and `ts`, so every
model works with every writer. The incremental model reports every ETF the batch
affected, on the batch's last change, with the offset of the last event that affected
it. Because no later event affects that ETF, its values at the end of the batch are its
values after that event, wherever the batch boundaries fall.

`checked` also compares, per batch, the ETFs and last offsets the graph reports with
those from `Full_recompute`.

**Optimized writer.** One transaction per batch and no reads:

1. Insert each new composition with `INSERT ... WHERE NOT EXISTS` a version at least as
   high, in event order.
2. Upsert the batch's latest price per symbol, latest ETF price and latest snapshot per
   ETF, each as one statement over `unnest` of array parameters.
3. Set `next_offset` to the batch's last offset plus one.

Each upsert only replaces a row whose `source_offset` is lower. Batches are reduced in
memory first, because a single `ON CONFLICT DO UPDATE` statement cannot touch the same
key twice.

**Single consumer.** At startup the engine takes `pg_try_advisory_lock(hashtext(key))`,
where the key is the topic or `file:PATH`, and exits with status 2 if another session
holds it. The lock is held for the life of the connection, so a killed engine releases
it when Postgres notices the closed connection.

**Recovery.** Load the latest composition per ETF and both price tables, apply them to
the model as events, seek to `next_offset` and continue. State and offset are committed
in one transaction, so a crash loses at most the uncommitted batch, which is replayed.

## Consequences

- Final tables depend only on the events, not on batch sizes, restarts or which writer
  ran. The baseline integration test checks restarted runs, optimized runs at batch
  sizes 1, 50 and 1000, and a run that switches writer and batch size partway, against
  the baseline service's tables.
- `test/integration/crash.ml` starts `engine.exe` on 200,000 events, sends SIGKILL at
  random times up to eight times, restarts with a random batch size, and compares the
  final tables with an uninterrupted run. It also checks that a second engine refuses to
  start while the lock is held.
- A tick that leaves a NAV unchanged still rewrites the row's offset. This replaces
  ADR 0005's rule that only changed ETFs are reported.
- An ETF priced before it has a composition gets a row with NULL NAV and premium.
- Recovery reproduces the graph exactly only while all state lives in those tables.
  Rebalance state, from stage 9, must be stored and restored the same way.
