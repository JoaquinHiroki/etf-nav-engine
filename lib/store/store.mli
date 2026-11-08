open! Core
open Nav_domain

type t

val connect : string -> t
val close : t -> unit

(** Runs [f] inside BEGIN/COMMIT, rolling back if it raises. *)
val transaction : t -> f:(unit -> 'a) -> 'a

val truncate_all : t -> unit

(** Timestamps are stored with microsecond precision. *)
val insert_composition : t -> Composition.t -> effective_ts:Time_ns.t -> unit

val latest_compositions : t -> (Composition.t * Time_ns.t) list
val set_next_offset : t -> topic:string -> int -> unit
val next_offset : t -> topic:string -> int option
