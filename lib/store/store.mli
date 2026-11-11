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
    ; nav : float option
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

(** Takes a session-level advisory lock on [key] without waiting. Returns [false] if
    another session holds it. The lock is released when the connection closes. *)
val try_advisory_lock : t -> key:string -> bool

val insert_composition : t -> Composition.t -> effective_ts:Time_ns.t -> unit

(** Inserts unless the ETF already has this version or a later one, without a read. *)
val insert_composition_if_newer : t -> Composition.t -> effective_ts:Time_ns.t -> unit

(** Takes a transaction-level advisory lock on [key], waiting for it. Must run inside
    [transaction]. *)
val advisory_xact_lock : t -> key:string -> unit

val composition_version : t -> etf:string -> int option
val latest_compositions : t -> (Composition.t * Time_ns.t) list
val upsert_price : t -> price_table -> Price.t -> unit
val price_offset : t -> price_table -> symbol:string -> int option
val prices : t -> price_table -> Price.t list

(** One statement for all rows; a row is only replaced by a higher [source_offset].
    Keys must be distinct. *)
val upsert_prices : t -> price_table -> Price.t list -> unit

val upsert_snapshot : t -> Snapshot.t -> unit

(** As [upsert_prices], for snapshots. *)
val upsert_snapshots : t -> Snapshot.t list -> unit

val snapshot_offset : t -> etf:string -> int option

(** The rebalance log. [state] holds the phase after the row's steps, [detail] the steps
    as JSON and [seq] the source offset of the first step. *)
val insert_transition : t -> Rebalance.Transition.t -> unit

(** One statement for all rows. *)
val insert_transitions : t -> Rebalance.Transition.t list -> unit

val last_transition_seq : t -> etf:string -> id:int -> int option
val delete_transitions : t -> etf:string -> id:int -> unit

(** Sorted by ETF, rebalance id and [seq]. *)
val transitions : t -> Rebalance.Transition.t list

(** Rows and bytes of row data in [rebalance_transition], by [pg_column_size]. *)
val transition_storage : t -> int * int

val snapshots : t -> Snapshot.t list
val set_next_offset : t -> topic:string -> int -> unit
val next_offset : t -> topic:string -> int option
