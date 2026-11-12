open! Core
open Nav_domain

(** Market state built by applying events in order, with NAV recomputed from every
    holding on each query. This is the test oracle and the computational baseline. *)
type t

val create : unit -> t

(** Applies [event] and returns the ETFs whose NAV or premium may have changed.
    Compositions only replace a lower version. Rebalance steps go through
    {!Rebalance.step}, whose outcome is passed to [rebalance]; an accepted [Apply] sets
    the target composition under the same version rule. *)
val apply : ?rebalance:(Rebalance.Outcome.t -> unit) -> t -> Event.t -> string list

val of_events : Event.t list -> t
val etfs : t -> string list

(** [None] until the ETF has a composition and every holding has a price. *)
val nav : t -> etf:string -> float option

val etf_price : t -> etf:string -> float option
val rebalances : t -> Rebalance.Book.t

(** [None] until both the NAV and the ETF's own price are known. *)
val premium : t -> etf:string -> float option

(** [nav] and [premium] from one pass over the holdings. *)
val nav_and_premium : t -> etf:string -> float option * float option
