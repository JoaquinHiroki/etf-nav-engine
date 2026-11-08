open! Core

type t =
  { etf : string
  ; version : int
  ; holdings : Holding.t array
  ; cash : float
  ; shares_outstanding : float
  }
[@@deriving bin_io, compare, sexp, quickcheck]

(** Sorts holdings by symbol and rejects duplicate symbols or non-positive shares. *)
val create
  :  etf:string
  -> version:int
  -> holdings:Holding.t array
  -> cash:float
  -> shares_outstanding:float
  -> t Or_error.t
