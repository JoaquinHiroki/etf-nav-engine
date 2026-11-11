open! Core

(** The rebalance state machine. A rebalance announces a target composition, is
    validated or rejected, reports each target holding as it is filled, applies the
    target as the live composition and settles. *)

module Phase : sig
  type t =
    | Announced
    | Validated
    | Rejected
    | Applying
    | Applied
    | Settled
  [@@deriving compare, enumerate, equal, sexp]

  (** [Rejected] and [Settled]: no step is accepted after them. *)
  val is_terminal : t -> bool

  val to_string : t -> string
  val of_string : string -> t
end

module Kind : sig
  type t =
    | Announce
    | Validate
    | Reject
    | Begin_applying
    | Progress
    | Apply
    | Settle
  [@@deriving compare, enumerate, equal, sexp]

  val of_step : Rebalance_step.t -> t
end

(** Every allowed transition, as (phase before, step, phase after). [None] is a
    rebalance not yet announced. Any other pair is rejected. *)
val transitions : (Phase.t option * Kind.t * Phase.t) list

val next : Phase.t option -> Kind.t -> Phase.t option

type t =
  { etf : string
  ; id : int
  ; target : Composition.t
  ; phase : Phase.t
  ; filled : String.Set.t (** target symbols reported by [Progress] *)
  ; reason : string option (** set by [Reject] *)
  ; announced : Timestamp.t
  ; updated : Timestamp.t (** timestamp of the last accepted step *)
  ; steps : int (** accepted steps *)
  }
[@@deriving compare, sexp]

(** Every rebalance seen, keyed by ETF and id, terminal ones included. *)
module Book : sig
  type rebalance := t
  type t [@@deriving compare, sexp]

  val empty : t
  val find : t -> etf:string -> id:int -> rebalance option

  (** The ETF's rebalance that is not yet terminal, if any. *)
  val active : t -> etf:string -> rebalance option

  val to_list : t -> rebalance list
end

module Outcome : sig
  type t =
    | Invalid of Sexp.t (** ignored: the book is unchanged *)
    | Accepted of
        { phase : Phase.t
        ; applied : Composition.t option
        (** on [Apply], the target to make live, unless a newer version already is *)
        }
  [@@deriving compare, sexp]
end

(** Besides the transition table: an announced target must be for the same ETF, and the
    ETF must have no active rebalance; [Progress] must name a target symbol not yet
    filled; [Apply] needs every target symbol filled. *)
val step
  :  Book.t
  -> etf:string
  -> id:int
  -> Rebalance_step.t
  -> ts:Timestamp.t
  -> Book.t * Outcome.t

(** A row of the rebalance log: consecutive accepted steps of one rebalance that end in
    the same phase. [seq] is the source offset of the first step. Only [compact] makes
    rows with more than one step. *)
module Transition : sig
  type t =
    { etf : string
    ; id : int
    ; seq : int
    ; phase : Phase.t
    ; steps : Rebalance_step.t list
    ; first_ts : Timestamp.t
    ; last_ts : Timestamp.t
    }
  [@@deriving compare, sexp]

  val create
    :  seq:int
    -> etf:string
    -> id:int
    -> phase:Phase.t
    -> Rebalance_step.t
    -> ts:Timestamp.t
    -> t

  val merged_count : t -> int
end

(** The log's steps as events, in [seq] order. Steps merged into one row all get the
    row's [last_ts], which leaves the folded state unchanged. *)
val events : Transition.t list -> Event.t list

(** Steps every event of [events] into an empty book. Raises if the log holds a step
    the state machine rejects. *)
val fold : Transition.t list -> Book.t

(** For each settled or rejected rebalance, merges consecutive rows with the same phase.
    Rows of other rebalances are left as they are. Returns rows sorted by ETF, id and
    [seq]. [fold (compact log)] equals [fold log], and [compact] is idempotent. *)
val compact : Transition.t list -> Transition.t list
