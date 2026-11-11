open! Core
open Nav_domain
open Nav_store

type t =
  { snapshots : Store.Snapshot.t list
  ; prices : Store.Price.t list
  ; etf_prices : Store.Price.t list
  ; compositions : (Composition.t * Timestamp.t) list
  ; next_offset : int option
  }
[@@deriving compare, sexp]

let read store ~topic =
  { snapshots = Store.snapshots store
  ; prices = Store.prices store Holding_prices
  ; etf_prices = Store.prices store Etf_prices
  ; compositions = Store.latest_compositions store
  ; next_offset = Store.next_offset store ~topic
  }
;;

(* Reports the first row that differs rather than both tables in full. *)
let check_rows ~what ~compare ~sexp_of ~expect actual =
  let rec go i = function
    | [], [] -> ()
    | e :: expected_rest, a :: actual_rest ->
      if compare e a = 0
      then go (i + 1) (expected_rest, actual_rest)
      else
        raise_s
          [%message
            "tables differ"
              (what : string)
              ~row:(i : int)
              ~expected:(sexp_of e : Sexp.t)
              ~actual:(sexp_of a : Sexp.t)]
    | _, _ ->
      raise_s
        [%message
          "tables differ in length"
            (what : string)
            ~expected:(List.length expect : int)
            ~actual:(List.length actual : int)]
  in
  go 0 (expect, actual)
;;

let check ~expect actual =
  check_rows
    ~what:"nav_snapshot"
    ~compare:Store.Snapshot.compare
    ~sexp_of:Store.Snapshot.sexp_of_t
    ~expect:expect.snapshots
    actual.snapshots;
  check_rows
    ~what:"price"
    ~compare:Store.Price.compare
    ~sexp_of:Store.Price.sexp_of_t
    ~expect:expect.prices
    actual.prices;
  check_rows
    ~what:"etf_price"
    ~compare:Store.Price.compare
    ~sexp_of:Store.Price.sexp_of_t
    ~expect:expect.etf_prices
    actual.etf_prices;
  check_rows
    ~what:"composition"
    ~compare:[%compare: Composition.t * Timestamp.t]
    ~sexp_of:[%sexp_of: Composition.t * Timestamp.t]
    ~expect:expect.compositions
    actual.compositions;
  [%test_result: int option]
    ~message:"next_offset"
    actual.next_offset
    ~expect:expect.next_offset
;;
