open! Core

type t =
  { symbol : string
  ; units : float
  }
[@@deriving bin_io, compare, sexp, quickcheck]
