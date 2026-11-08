open! Core
open Nav_graph
open Nav_store

(** Loads compositions and prices into [state] and returns the next offset to read. *)
val restore : Store.t -> Full_recompute.t -> topic:string -> int
