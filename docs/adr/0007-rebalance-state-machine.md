# 0007: Rebalance state machine and log compaction

Date: 2026-11-11
Status: accepted

## Context

Until stage 9 both models ignored rebalance events, so a rebalance's target never became
the live composition. ADR 0006 also left a gap: recovery rebuilds the models only from
what is stored, and nothing about rebalances was stored. Most of a rebalance's log is
`Progress` steps, one per target holding, which matter only until the rebalance ends.

## Decision

**State machine.** `Rebalance` in `nav_domain` is pure. Its `transitions` table lists
every allowed (phase, step, phase) triple; any other pair is rejected:

| Phase | Step | Next phase |
|-------|------|------------|
| (new) | `Announce` | announced |
| announced | `Validate` | validated |
| announced, validated | `Reject` | rejected |
| validated | `Begin_applying` | applying |
| applying | `Progress` | applying |
| applying | `Apply` | applied |
| applied | `Settle` | settled |

Guards beyond the table: an announced target must be for the same ETF, and the ETF must
have no rebalance that is not yet rejected or settled; `Progress` must name a target
symbol not yet filled; `Apply` needs every target symbol filled. Rebalances are keyed by
ETF and id, and an id is never reused. A rejected step leaves the state unchanged and is
counted (`invalid_rebalance_steps` in the engine report), since a step read from the
topic cannot be refused.

**Applying.** Both `Full_recompute` and `Incremental_nav` keep a `Rebalance.Book` and
step it on every rebalance event. An accepted `Apply` sets the target composition under
the existing version rule, and the ETF counts as affected when the target is newer.
This extends ADR 0006's snapshot rule. Keeping the state machine in both models keeps
the oracle a fold over every event, and the property test compares them on streams that
include rebalances.

**Log.** Every accepted step is a row of `rebalance_transition`: `seq` is the step's
source offset, `state` the phase after it, `detail` the steps as JSON and
`merged_count` their number. Both writers add the rows and insert an applied target into
`composition`, under the version rule, in the transaction of the step's event. Recovery
replays the log after the stored compositions and prices. A replayed `Apply` changes
nothing, because its target, or a newer version, is already stored.

Ordering the log by `seq` is a valid replay order even after compaction. Rebalances of
different ETFs are independent, and one ETF's rebalances do not overlap, so a
rebalance's rows, even merged ones, come before the next rebalance's announcement.

**Compaction.** `Rebalance.compact` merges consecutive rows with the same phase, only
for rebalances that are settled or rejected. In practice that merges `Begin_applying`
and every `Progress` into one `applying` row. Merged steps all get the row's `last_ts`.
A rebalance keeps only its announcement and last-step timestamps, so `fold` of the
compacted log equals `fold` of the full log. `make compact` rewrites the stored log in one
transaction, under an advisory lock that serializes compactions. It can run while an
engine writes: no step is accepted for a terminal rebalance, so no writer adds rows to
the ones being rewritten.

## Consequences

- `test/test_rebalance.ml` prints the transition table, checks each guard, and checks
  that folding the full and compacted logs gives the state built step by step, on 2,000
  generated streams with dropped, repeated and stray steps and on a synthetic stream.
- The integration tests compact between restarts, and the crash test compacts while an
  engine runs before killing it. Final tables equal an uninterrupted run that is then
  compacted.
- A settled rebalance of *n* holdings takes 5 rows instead of *n* + 5. Rejected ones
  have nothing to merge.
- Terminal rebalances stay in the log and in memory, so the log grows by about 5 rows per
  rebalance and recovery replays all of them. Dropping settled rebalances would need the
  id-reuse rule to be kept some other way.
- NAVs differ from stages 5 to 8 wherever a rebalance was applied, since those stages
  never swapped to the target.
