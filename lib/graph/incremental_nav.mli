open! Core
open Nav_domain

(** Market state as an [Incremental] graph. Each symbol has one variable shared by every
    ETF that holds it. Each ETF binds on its composition, so a new composition replaces
    the ETF's subgraph. Positions are summed with {!Balanced.reduce}, the same tree as
    {!Full_recompute}, so both produce bit-identical NAVs.

    Every float node is cut off when its new value has the same bits as the old one. *)
type t

module Recomputes : sig
  (** Node functions run since the graph was created or last reset. *)
  type t =
    { positions : int (** [units *. price] leaves *)
    ; sums : int (** interior nodes of the summation tree *)
    ; navs : int
    ; premiums : int
    ; subgraphs : int (** compositions bound, each building a new subgraph *)
    }
  [@@deriving compare, sexp]
end

(** Each graph has its own [Incremental] state. *)
val create : unit -> t

module Affected : sig
  (** An ETF affected since the last {!take_affected}, with the offset and timestamp of
      the last event that affected it. *)
  type t =
    { etf : string
    ; offset : int
    ; ts : Timestamp.t
    }
  [@@deriving compare, sexp]
end

(** Records [event], read at [offset], without recomputing anything. Compositions only
    replace a lower version, and rebalance steps go through {!Rebalance.step}, as in
    {!Full_recompute}.

    Marks as affected each ETF that {!Full_recompute.apply} would return for the same
    event, and returns the outcome of a rebalance step. *)
val apply : t -> offset:int -> Event.t -> Rebalance.Outcome.t option

(** Recomputes the nodes affected by the events applied since the last call. *)
val stabilize : t -> unit

val etfs : t -> string list

(** The ETFs whose NAV or premium changed, by bits, in the stabilizations since the last
    call, sorted. An ETF's first stabilization counts as a change. *)
val take_changed : t -> string list

(** The ETFs marked by {!apply} since the last call, sorted. *)
val take_affected : t -> Affected.t list

(** [nav] and [premium] raise if events were applied since the last [stabilize]. They
    return [None] in the same cases as {!Full_recompute}. *)
val nav : t -> etf:string -> float option

val premium : t -> etf:string -> float option
val etf_price : t -> etf:string -> float option
val rebalances : t -> Rebalance.Book.t
val recomputes : t -> Recomputes.t
val reset_recomputes : t -> unit
