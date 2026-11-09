# 0004: Incremental graph

Date: 2026-11-09
Status: accepted

## Context

A price tick changes one symbol, but `Full_recompute` sums every holding of every ETF
that holds it. The design keeps NAVs in an `Incremental` graph so that only the nodes
that depend on the tick are recomputed. The correctness test requires the graph's
NAVs to equal a full recompute exactly after every event.

## Decision

`Nav_graph.Incremental_nav` builds the graph:

- One variable per symbol, created the first time a price or composition mentions it
  and shared by every ETF that holds the symbol. A missing price is NaN, as in
  `Full_recompute`.
- One variable per ETF composition. The ETF's NAV is a `bind` on it: a new composition
  builds a new subgraph of `units *. price` leaves summed with `Balanced.reduce`, and
  the old subgraph stops being computed.
- One variable per ETF price, holding an option so that a NaN ETF price stays distinct
  from a missing one.
- Observers on each ETF's NAV and premium.

Every float node has a cutoff that compares bits. Equal bits give equal results
downstream, so the cutoff cannot change any value, and it stops propagation when a
tick repeats the last price. `Float.equal` would be wrong here: it treats `0.` and `-0.`
as equal, which can change a later sum's sign, and it never treats two NaNs as equal.

Each graph has its own `Incremental.State`, created with `State.create`, rather than one
global state from `Incremental.Make`. Property tests build thousands of graphs, and
separate states keep them independent.

`apply` only sets variables; `stabilize` recomputes. Counters inside the node
functions record how many leaves, sums, NAVs, premiums and subgraph builds ran.

## Consequences

- Leaves, tree shape and the NAV formula are the same as `Full_recompute`, so equal
  inputs give bit-identical NAVs. A property test checks this after every event on
  random streams that include signed zeros, NaN, infinities and repeated values, and on
  a synthetic stream with composition updates.
- A tick on a symbol in an ETF of *n* holdings recomputes one leaf and about
  log2 *n* sums instead of *n* leaves and *n* - 1 sums.
- Swapping a composition rebuilds the ETF's whole subgraph. Compositions change far less
  often than prices, so this is not optimized.
- Every node allocates a boxed float when it recomputes, and the graph uses more memory
  than the hash tables in `Full_recompute`. Stage 10 measures when that overhead loses
  to a full recompute, for example with small baskets.
