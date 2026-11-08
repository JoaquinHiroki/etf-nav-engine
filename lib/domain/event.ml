open! Core

module T = struct
  type t =
    | Price of
        { symbol : string
        ; price : float
        ; ts : Timestamp.t
        }
    | Etf_price of
        { etf : string
        ; price : float
        ; ts : Timestamp.t
        }
    | Composition of
        { composition : Composition.t
        ; ts : Timestamp.t
        }
    | Rebalance of
        { etf : string
        ; id : int
        ; step : Rebalance_step.t
        ; ts : Timestamp.t
        }
  [@@deriving bin_io, compare, sexp, quickcheck]
end

include T

let to_string = Binable.to_string (module T)
let of_string = Binable.of_string (module T)

let key = function
  | Price { symbol; _ } -> symbol
  | Etf_price { etf; _ } | Rebalance { etf; _ } -> etf
  | Composition { composition; _ } -> composition.etf
;;

let with_ts t ts =
  match t with
  | Price p -> Price { p with ts }
  | Etf_price p -> Etf_price { p with ts }
  | Composition c -> Composition { c with ts }
  | Rebalance r -> Rebalance { r with ts }
;;

let ts = function
  | Price { ts; _ } | Etf_price { ts; _ } | Composition { ts; _ } | Rebalance { ts; _ } ->
    ts
;;
