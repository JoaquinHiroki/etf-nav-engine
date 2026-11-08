open! Core

type t =
  | Announce of Composition.t
  | Validate
  | Reject of string
  | Begin_applying
  | Progress of Holding.t
  | Apply
  | Settle
[@@deriving bin_io, compare, sexp, quickcheck]
