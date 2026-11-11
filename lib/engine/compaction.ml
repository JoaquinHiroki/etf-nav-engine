open! Core
open Nav_domain
open Nav_store

module Report = struct
  type t =
    { rebalances : int
    ; rows_before : int
    ; rows_after : int
    ; bytes_before : int
    ; bytes_after : int
    }
  [@@deriving sexp]
end

let by_rebalance transitions =
  List.group transitions ~break:(fun (a : Rebalance.Transition.t) b ->
    not ([%equal: string * int] (a.etf, a.id) (b.etf, b.id)))
;;

let run store =
  Store.transaction store ~f:(fun () ->
    Store.advisory_xact_lock store ~key:"compact rebalance_transition";
    let rows_before, bytes_before = Store.transition_storage store in
    let rewritten =
      by_rebalance (Store.transitions store)
      |> List.filter_map ~f:(fun rows ->
        let compacted = Rebalance.compact rows in
        if [%compare.equal: Rebalance.Transition.t list] rows compacted
        then None
        else (
          let { Rebalance.Transition.etf; id; _ } = List.hd_exn rows in
          Store.delete_transitions store ~etf ~id;
          Store.insert_transitions store compacted;
          Some ()))
    in
    let rows_after, bytes_after = Store.transition_storage store in
    { Report.rebalances = List.length rewritten
    ; rows_before
    ; rows_after
    ; bytes_before
    ; bytes_after
    })
;;
