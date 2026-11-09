open! Core
open Nav_domain
open Nav_store

(** The events that rebuild the stored compositions and prices, and the next offset to
    read. *)
val load : Store.t -> topic:string -> Event.t list * int
