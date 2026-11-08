open! Core
open Nav_domain

(** Typed access to the Postgres tables. Every statement that returns rows counts as a
    read and every other statement as a write; BEGIN/COMMIT count as one transaction.
    Timestamps are stored with microsecond precision. *)
type t

module Stats : sig
  type t =
    { reads : int
    ; writes : int
    ; transactions : int
    }
  [@@deriving sexp]
end

module Snapshot : sig
  type t =
    { etf : string
    ; nav : float
    ; premium : float option
    ; source_offset : int
    ; ts : Time_ns.Alternate_sexp.t
    }
  [@@deriving compare, sexp]
end

module Price : sig
  type t =
    { symbol : string
    ; price : float
    ; source_offset : int
    ; ts : Time_ns.Alternate_sexp.t
    }
  [@@deriving compare, sexp]
end

type price_table =
  | Holding_prices
  | Etf_prices

val connect : string -> t
val close : t -> unit
val stats : t -> Stats.t
val reset_stats : t -> unit

(** Runs [f] inside BEGIN/COMMIT, rolling back if it raises. *)
val transaction : t -> f:(unit -> 'a) -> 'a

val truncate_all : t -> unit
val insert_composition : t -> Composition.t -> effective_ts:Time_ns.t -> unit
val composition_version : t -> etf:string -> int option
val latest_compositions : t -> (Composition.t * Time_ns.t) list
val upsert_price : t -> price_table -> Price.t -> unit
val price_offset : t -> price_table -> symbol:string -> int option
val prices : t -> price_table -> Price.t list
val upsert_snapshot : t -> Snapshot.t -> unit
val snapshot_offset : t -> etf:string -> int option
val snapshots : t -> Snapshot.t list
val set_next_offset : t -> topic:string -> int -> unit
val next_offset : t -> topic:string -> int option
