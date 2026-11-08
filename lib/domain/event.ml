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
