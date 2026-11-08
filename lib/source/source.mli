open! Core
open Nav_domain

type record =
  { offset : int
  ; event : Event.t
  }
[@@deriving compare, sexp_of]

(** A totally ordered, replayable event stream. [seek] sets the next offset to read.
    [poll] returns at most [max] records in offset order, or [] when none are
    available. *)
type t =
  { seek : int -> unit
  ; poll : max:int -> record list
  ; close : unit -> unit
  }

val in_memory : Event.t array -> t
