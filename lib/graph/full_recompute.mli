open! Core
open Nav_domain

(** Market state built by applying events in order, with NAV recomputed from every
    holding on each query. This is the test oracle and the computational baseline. *)
type t

val create : unit -> t

(** Applies [event] and returns the ETFs whose NAV or premium may have changed.
    Compositions only replace a lower version. Rebalance events are not applied yet. *)
val apply : t -> Event.t -> string list

val of_events : Event.t list -> t
val etfs : t -> string list

(** [None] until the ETF has a composition and every holding has a price. *)
val nav : t -> etf:string -> float option

val etf_price : t -> etf:string -> float option

(** [None] until both the NAV and the ETF's own price are known. *)
val premium : t -> etf:string -> float option
