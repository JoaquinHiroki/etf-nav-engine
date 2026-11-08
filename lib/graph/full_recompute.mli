open! Core
open Nav_domain

(** Market state as a pure fold over events, with NAV recomputed from every holding on
    each query. This is the test oracle and the computational baseline. *)
type t

val empty : t

(** Compositions only replace a lower version. Rebalance events are not applied yet. *)
val apply : t -> Event.t -> t

val of_events : Event.t list -> t
val etfs : t -> string list

(** [None] until the ETF has a composition and every holding has a price. *)
val nav : t -> etf:string -> float option

(** [None] until both the NAV and the ETF's own price are known. *)
val premium : t -> etf:string -> float option
