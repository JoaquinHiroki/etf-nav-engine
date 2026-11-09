open! Core
open Nav_domain
open Nav_graph
open Nav_source

module Mismatch : sig
  type t =
    { offset : int (** last offset of the batch *)
    ; etf : string
    ; incremental_nav : float option
    ; full_nav : float option
    ; incremental_premium : float option
    ; full_premium : float option
    }
  [@@deriving sexp]
end

module Oracle : sig
  type t =
    { batches : int
    ; etf_checks : int
    ; mismatches : int
    ; first_mismatches : Mismatch.t list (** at most 10 *)
    }
  [@@deriving sexp]
end

module Stats : sig
  type t =
    { recomputes : Incremental_nav.Recomputes.t option
    ; oracle : Oracle.t option
    }
  [@@deriving sexp]
end

(** How the engine turns a batch of records into changes. *)
type t =
  { name : string
  ; restore : Event.t list -> unit
  (** Loads recovered state. Nothing it recomputes is reported or counted. *)
  ; compute : Source.record list -> Change.t list (** One change per record, in order. *)
  ; stats : unit -> Stats.t
  }

(** Recomputes every affected ETF from all its holdings after each event, and reports
    each affected ETF with a NAV on that event's change. *)
val full : unit -> t

(** Applies the whole batch to the incremental graph and stabilizes once. ETFs whose NAV
    or premium changed are reported on the batch's last change. *)
val incremental : unit -> t

(** [incremental], with [Full_recompute] applied alongside. After each batch, every ETF
    that either one says may have changed is compared bit for bit. *)
val checked : unit -> t
