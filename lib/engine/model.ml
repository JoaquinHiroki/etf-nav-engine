open! Core
open Nav_domain
open Nav_graph
open Nav_source

module Mismatch = struct
  type t =
    { offset : int
    ; etf : string
    ; incremental_nav : float option
    ; full_nav : float option
    ; incremental_premium : float option
    ; full_premium : float option
    }
  [@@deriving sexp]
end

module Oracle = struct
  type t =
    { batches : int
    ; etf_checks : int
    ; mismatches : int
    ; affected_mismatches : int
    ; first_mismatches : Mismatch.t list
    }
  [@@deriving sexp]
end

module Stats = struct
  type t =
    { recomputes : Incremental_nav.Recomputes.t option
    ; oracle : Oracle.t option
    }
  [@@deriving sexp]
end

type t =
  { name : string
  ; restore : Event.t list -> unit
  ; compute : Source.record list -> Change.t list
  ; stats : unit -> Stats.t
  }

let full () =
  let state = Full_recompute.create () in
  { name = "full"
  ; restore =
      List.iter ~f:(fun event -> ignore (Full_recompute.apply state event : string list))
  ; compute = List.map ~f:(Change.compute state)
  ; stats = (fun () -> { Stats.recomputes = None; oracle = None })
  }
;;

module Step = struct
  type t =
    { reversed : Change.t list
    ; affected : Incremental_nav.Affected.t list
    ; changed : string list
    }
end

(* Applies [records] and stabilizes. Returns the records' changes, last first and without
   NAV updates, the ETFs the batch affected, and the ETFs whose values changed. *)
let step graph (records : Source.record list) =
  let reversed =
    List.fold records ~init:[] ~f:(fun reversed { Source.offset; event } ->
      let rebalance = Incremental_nav.apply graph ~offset event in
      { Change.offset; event; navs = []; rebalance } :: reversed)
  in
  Incremental_nav.stabilize graph;
  { Step.reversed
  ; affected = Incremental_nav.take_affected graph
  ; changed = Incremental_nav.take_changed graph
  }
;;

(* The batch's NAV updates all go on its last change, with the offsets of the events that
   affected each ETF, so the stored snapshots do not depend on where batches start. *)
let changes graph { Step.reversed; affected; _ } =
  match reversed with
  | [] -> []
  | last :: rest ->
    let navs =
      List.map affected ~f:(fun { Incremental_nav.Affected.etf; offset; ts } ->
        { Change.Nav_update.etf
        ; nav = Incremental_nav.nav graph ~etf
        ; premium = Incremental_nav.premium graph ~etf
        ; source_offset = offset
        ; ts
        })
    in
    List.rev ({ last with navs } :: rest)
;;

let restore_incremental graph events =
  List.iter events ~f:(fun event ->
    ignore (Incremental_nav.apply graph ~offset:0 event : Rebalance.Outcome.t option));
  Incremental_nav.stabilize graph;
  ignore (Incremental_nav.take_affected graph : Incremental_nav.Affected.t list);
  ignore (Incremental_nav.take_changed graph : string list);
  Incremental_nav.reset_recomputes graph
;;

let incremental () =
  let graph = Incremental_nav.create () in
  { name = "incremental"
  ; restore = restore_incremental graph
  ; compute = (fun records -> changes graph (step graph records))
  ; stats =
      (fun () ->
        { Stats.recomputes = Some (Incremental_nav.recomputes graph); oracle = None })
  }
;;

let max_reported_mismatches = 10
let bits = Option.map ~f:Int64.bits_of_float

let checked () =
  let graph = Incremental_nav.create () in
  let full = Full_recompute.create () in
  let batches = ref 0 in
  let etf_checks = ref 0 in
  let mismatches = ref 0 in
  let affected_mismatches = ref 0 in
  let first_mismatches = Queue.create () in
  let check ~offset etf =
    incr etf_checks;
    let full_nav, full_premium = Full_recompute.nav_and_premium full ~etf in
    let mismatch =
      { Mismatch.offset
      ; etf
      ; incremental_nav = Incremental_nav.nav graph ~etf
      ; full_nav
      ; incremental_premium = Incremental_nav.premium graph ~etf
      ; full_premium
      }
    in
    if not
         ([%equal: Int64.t option]
            (bits mismatch.incremental_nav)
            (bits mismatch.full_nav)
          && [%equal: Int64.t option]
               (bits mismatch.incremental_premium)
               (bits mismatch.full_premium))
    then (
      incr mismatches;
      if Queue.length first_mismatches < max_reported_mismatches
      then Queue.enqueue first_mismatches mismatch)
  in
  let compute (records : Source.record list) =
    let full_affected = Hashtbl.create (module String) in
    List.iter records ~f:(fun { Source.offset; event } ->
      List.iter (Full_recompute.apply full event) ~f:(fun etf ->
        Hashtbl.set full_affected ~key:etf ~data:offset));
    let step = step graph records in
    let graph_affected =
      List.map step.affected ~f:(fun { Incremental_nav.Affected.etf; offset; ts = _ } ->
        etf, offset)
      |> Hashtbl.of_alist_exn (module String)
    in
    if not (Hashtbl.equal Int.equal full_affected graph_affected)
    then incr affected_mismatches;
    let to_check = String.Hash_set.of_list (Hashtbl.keys full_affected) in
    List.iter (Hashtbl.keys graph_affected) ~f:(Hash_set.add to_check);
    List.iter step.changed ~f:(Hash_set.add to_check);
    Option.iter (List.last records) ~f:(fun last ->
      incr batches;
      Hash_set.iter to_check ~f:(check ~offset:last.offset));
    changes graph step
  in
  { name = "checked"
  ; restore =
      (fun events ->
        List.iter events ~f:(fun event ->
          ignore (Full_recompute.apply full event : string list));
        restore_incremental graph events)
  ; compute
  ; stats =
      (fun () ->
        { Stats.recomputes = Some (Incremental_nav.recomputes graph)
        ; oracle =
            Some
              { Oracle.batches = !batches
              ; etf_checks = !etf_checks
              ; mismatches = !mismatches
              ; affected_mismatches = !affected_mismatches
              ; first_mismatches = Queue.to_list first_mismatches
              }
        })
  }
;;
