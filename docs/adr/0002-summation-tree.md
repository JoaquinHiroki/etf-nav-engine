# 0002: Own the summation tree shape

Date: 2026-11-08
Status: accepted

## Context

The correctness test compares incremental NAV with a full recompute using exact equality.
Floating-point addition is not associative, so both must add positions in the same
order:

```
(0.1 + 0.2) + 0.3 = 0.60000000000000009
0.1 + (0.2 + 0.3) = 0.59999999999999998
```

`Incremental.reduce_balanced` documents that its `reduce` must be associative and does
not specify a tree shape. A full recompute that tried to match its internal shape could
break silently on a library upgrade.

## Decision

`Nav_graph.Balanced.reduce` defines the shape: every range splits at its midpoint, so the
shape depends only on the number of holdings. The full recompute sums leaf values with
it, and the incremental graph builds its nodes with the same function, combining child
nodes with `map2`.

A missing price is a NaN leaf. NaN propagates through the sum, and NAV is reported as
`None`. This keeps the hot path free of option allocations.

## Consequences

- Equal inputs give bit-identical NAVs in both paths by construction.
- The incremental graph does not use `reduce_balanced`, so the node layout is ours to
  benchmark and explain.
- A price that is itself NaN would be indistinguishable from a missing price. Event
  sources must reject non-finite prices.
