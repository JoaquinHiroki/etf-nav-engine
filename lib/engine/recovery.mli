open! Core
open Nav_domain
open Nav_store

(** The events that rebuild the stored compositions, prices and rebalances, and the
    next offset to read. Rebalance steps come last, replayed from the log; an [Apply]
    among them changes nothing, since its target, or a newer version, is already stored
    as a composition. *)
val load : Store.t -> topic:string -> Event.t list * int
