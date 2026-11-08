open! Core
open Nav_domain

type t

val create : brokers:string -> topic:string -> t

(** Queues [event] for partition 0, keyed by [Event.key]. *)
val send : t -> Event.t -> unit

(** Blocks until every queued event is acknowledged. Raises if any delivery failed. *)
val flush : t -> unit

val close : t -> unit
