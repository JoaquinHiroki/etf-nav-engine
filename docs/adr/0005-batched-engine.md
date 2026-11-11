# 0005: Batched engine and checked replays

Date: 2026-11-09
Status: accepted; which ETFs are reported, and with which offsets, is superseded by
[0006](0006-write-path-and-recovery.md)

## Context

Stabilizing the incremental graph once per event repeats work that a batch can share:
two ticks on one symbol, or ticks on symbols in one ETF, recompute overlapping paths.
The engine already polls in batches. The correctness claim also has to hold for the
engine as it runs, over multi-million event replays, not only in unit tests.

## Decision

The engine takes a `Model`, which turns a batch of records into one change per record:

| Model | Computation | NAV updates reported |
|-------|-------------|----------------------|
| `full` | `Full_recompute` after every event, as in stage 5 | Every affected ETF with a NAV, on the change of the event that affected it |
| `incremental` | Apply the batch to `Incremental_nav`, stabilize once | ETFs whose NAV or premium bits changed, on the batch's last change |
| `checked` | `incremental`, plus `Full_recompute` applied alongside | As `incremental` |

`incremental` learns which ETFs changed from on-update handlers on the NAV and premium
observers. A tick that leaves an ETF's NAV and premium bits unchanged, or a stale
composition, reports nothing.

After each batch, `checked` compares the NAV and premium of every ETF that either
`Full_recompute` reports as affected or the graph reports as changed. A mismatch is
any difference in bits. The engine reports how many ETFs it checked, the mismatch count
and the first ten mismatches, and `bin/engine.exe` exits with status 1 if there are any.
`make oracle` runs it over the generated file at batch sizes 1, 100 and 1000, and CI does
the same on 100,000 events.

`incremental` is the engine's default model. Recovery returns the stored state as
events, and the model applies them without reporting or counting what they recompute.

## Consequences

- With `incremental`, a snapshot's `source_offset` is the batch's last offset, so it
  depends on where batches start. A run that stops and restarts batches differently from
  an uninterrupted run and can write different offsets. The baseline integration test
  therefore uses `full`. Stage 8 has to settle this before it can require restarted and
  uninterrupted tables to be equal.
- `checked` runs both computations, so its throughput is not the incremental engine's
  throughput. Benchmarks use `full` and `incremental`.
- Checking only affected and changed ETFs is enough by induction: an ETF that neither
  side touches keeps the values that were last found equal.
