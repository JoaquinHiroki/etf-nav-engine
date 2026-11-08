open! Core

type t =
  { etf : string
  ; version : int
  ; holdings : Holding.t array
  ; cash : float
  ; shares_outstanding : float
  }
[@@deriving bin_io, compare, sexp, quickcheck]

let create ~etf ~version ~holdings ~cash ~shares_outstanding =
  let holdings =
    Array.sorted_copy holdings ~compare:(fun (a : Holding.t) b ->
      String.compare a.symbol b.symbol)
  in
  let duplicate =
    Array.find_consecutive_duplicate holdings ~equal:(fun (a : Holding.t) b ->
      String.equal a.symbol b.symbol)
  in
  match duplicate with
  | Some (holding, _) ->
    Or_error.error_s
      [%message "duplicate holding" (etf : string) ~symbol:(holding.symbol : string)]
  | None when not Float.(shares_outstanding > 0.) ->
    Or_error.error_s
      [%message
        "shares_outstanding must be positive" (etf : string) (shares_outstanding : float)]
  | None -> Ok { etf; version; holdings; cash; shares_outstanding }
;;
