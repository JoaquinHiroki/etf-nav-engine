open! Core
open Nav_domain
open Nav_graph
open Nav_source
open Nav_store

module Nav_update = struct
  (** An ETF's NAV and premium after the last event that affected it, with that event's
      offset and timestamp. [nav] is [None] while some holding has no price. *)
  type t =
    { etf : string
    ; nav : float option
    ; premium : float option
    ; source_offset : int
    ; ts : Timestamp.t
    }
  [@@deriving compare, sexp]

  let to_snapshot { etf; nav; premium; source_offset; ts } =
    { Store.Snapshot.etf; nav; premium; source_offset; ts }
  ;;
end

type t =
  { offset : int
  ; event : Event.t
  ; navs : Nav_update.t list
  ; rebalance : Rebalance.Outcome.t option
  }
[@@deriving compare, sexp]

let transition t =
  match t.event, t.rebalance with
  | Rebalance { etf; id; step; ts }, Some (Accepted { phase; _ }) ->
    Some (Rebalance.Transition.create ~seq:t.offset ~etf ~id ~phase step ~ts)
  | _, (None | Some (Accepted _ | Invalid _)) -> None
;;

let applied t =
  match t.rebalance with
  | Some (Accepted { applied = Some target; _ }) -> Some (target, Event.ts t.event)
  | None | Some (Accepted { applied = None; _ } | Invalid _) -> None
;;

let compute state (record : Source.record) =
  let ts = Event.ts record.event in
  let rebalance = ref None in
  let affected =
    Full_recompute.apply state record.event ~rebalance:(fun outcome ->
      rebalance := Some outcome)
  in
  let navs =
    List.map affected ~f:(fun etf ->
      { Nav_update.etf
      ; nav = Full_recompute.nav state ~etf
      ; premium = Full_recompute.premium state ~etf
      ; source_offset = record.offset
      ; ts
      })
  in
  { offset = record.offset; event = record.event; navs; rebalance = !rebalance }
;;
