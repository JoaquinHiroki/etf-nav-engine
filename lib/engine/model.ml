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

(* Applies [records], stabilizes and returns the ETFs that changed. *)
let step graph (records : Source.record list) =
  List.iter records ~f:(fun record -> Incremental_nav.apply graph record.event);
  Incremental_nav.stabilize graph;
  Incremental_nav.take_changed graph
;;

let changes graph (records : Source.record list) ~changed =
  let navs =
    List.filter_map changed ~f:(fun etf ->
      let%map.Option nav = Incremental_nav.nav graph ~etf in
      { Change.Nav_update.etf; nav; premium = Incremental_nav.premium graph ~etf })
  in
  let last = List.length records - 1 in
  List.mapi records ~f:(fun i { Source.offset; event } ->
    { Change.offset; event; navs = (if i = last then navs else []) })
;;

let restore_incremental graph events =
  List.iter events ~f:(Incremental_nav.apply graph);
  Incremental_nav.stabilize graph;
  ignore (Incremental_nav.take_changed graph : string list);
  Incremental_nav.reset_recomputes graph
;;

let incremental () =
  let graph = Incremental_nav.create () in
  { name = "incremental"
  ; restore = restore_incremental graph
  ; compute = (fun records -> changes graph records ~changed:(step graph records))
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
  let first_mismatches = Queue.create () in
  let check ~offset etf =
    incr etf_checks;
    let mismatch =
      { Mismatch.offset
      ; etf
      ; incremental_nav = Incremental_nav.nav graph ~etf
      ; full_nav = Full_recompute.nav full ~etf
      ; incremental_premium = Incremental_nav.premium graph ~etf
      ; full_premium = Full_recompute.premium full ~etf
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
    let affected = String.Hash_set.create () in
    List.iter records ~f:(fun record ->
      List.iter (Full_recompute.apply full record.event) ~f:(Hash_set.add affected));
    let changed = step graph records in
    List.iter changed ~f:(Hash_set.add affected);
    Option.iter (List.last records) ~f:(fun last ->
      incr batches;
      Hash_set.iter affected ~f:(check ~offset:last.offset));
    changes graph records ~changed
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
              ; first_mismatches = Queue.to_list first_mismatches
              }
        })
  }
;;
