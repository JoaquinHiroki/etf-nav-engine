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

(* Applies [records] and stabilizes. Returns, for each ETF the batch affected, the
   offset and timestamp of the last event that affected it, and the ETFs whose values
   changed. *)
let step graph (records : Source.record list) =
  let last_affected = Hashtbl.create (module String) in
  List.iter records ~f:(fun { Source.offset; event } ->
    let ts = Event.ts event in
    Incremental_nav.apply graph event ~affected:(fun etf ->
      Hashtbl.set last_affected ~key:etf ~data:(offset, ts)));
  Incremental_nav.stabilize graph;
  last_affected, Incremental_nav.take_changed graph
;;

(* The batch's NAV updates all go on its last change, with the offsets of the events that
   affected each ETF, so the stored snapshots do not depend on where batches start. *)
let changes graph (records : Source.record list) ~last_affected =
  let navs =
    Hashtbl.to_alist last_affected
    |> List.sort ~compare:(fun (a, _) (b, _) -> String.compare a b)
    |> List.map ~f:(fun (etf, (source_offset, ts)) ->
      { Change.Nav_update.etf
      ; nav = Incremental_nav.nav graph ~etf
      ; premium = Incremental_nav.premium graph ~etf
      ; source_offset
      ; ts
      })
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
  ; compute =
      (fun records ->
        let last_affected, (_ : string list) = step graph records in
        changes graph records ~last_affected)
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
    let full_affected = Hashtbl.create (module String) in
    List.iter records ~f:(fun { Source.offset; event } ->
      List.iter (Full_recompute.apply full event) ~f:(fun etf ->
        Hashtbl.set full_affected ~key:etf ~data:offset));
    let last_affected, changed = step graph records in
    let graph_affected = Hashtbl.map last_affected ~f:fst in
    if not (Hashtbl.equal Int.equal full_affected graph_affected)
    then incr affected_mismatches;
    let to_check = String.Hash_set.of_list (Hashtbl.keys full_affected) in
    List.iter (Hashtbl.keys graph_affected) ~f:(Hash_set.add to_check);
    List.iter changed ~f:(Hash_set.add to_check);
    Option.iter (List.last records) ~f:(fun last ->
      incr batches;
      Hash_set.iter to_check ~f:(check ~offset:last.offset));
    changes graph records ~last_affected
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
