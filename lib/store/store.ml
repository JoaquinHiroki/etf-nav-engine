open! Core
open Nav_domain

module Stats = struct
  type t =
    { reads : int
    ; writes : int
    ; transactions : int
    }
  [@@deriving sexp]
end

module Snapshot = struct
  type t =
    { etf : string
    ; nav : float
    ; premium : float option
    ; source_offset : int
    ; ts : Time_ns.Alternate_sexp.t
    }
  [@@deriving compare, sexp]
end

module Price = struct
  type t =
    { symbol : string
    ; price : float
    ; source_offset : int
    ; ts : Time_ns.Alternate_sexp.t
    }
  [@@deriving compare, sexp]
end

type price_table =
  | Holding_prices
  | Etf_prices

type t =
  { conn : Postgresql.connection
  ; mutable reads : int
  ; mutable writes : int
  ; mutable transactions : int
  }

let connect conninfo =
  { conn = new Postgresql.connection ~conninfo ()
  ; reads = 0
  ; writes = 0
  ; transactions = 0
  }
;;

let close t = t.conn#finish
let stats t = { Stats.reads = t.reads; writes = t.writes; transactions = t.transactions }

let reset_stats t =
  t.reads <- 0;
  t.writes <- 0;
  t.transactions <- 0
;;

let exec t ~expect ~params sql =
  try t.conn#exec ~expect ~params sql with
  | Postgresql.Error error ->
    raise_s
      [%message "postgres error" ~error:(Postgresql.string_of_error error) (sql : string)]
;;

let control t sql =
  ignore (exec t ~expect:[ Command_ok ] ~params:[||] sql : Postgresql.result)
;;

let command t ?(params = [||]) sql =
  t.writes <- t.writes + 1;
  ignore (exec t ~expect:[ Command_ok ] ~params sql : Postgresql.result)
;;

let query t ?(params = [||]) sql =
  t.reads <- t.reads + 1;
  let result = exec t ~expect:[ Tuples_ok ] ~params sql in
  List.init result#ntuples ~f:(fun row ->
    List.init result#nfields ~f:(fun col ->
      Option.some_if (not (result#getisnull row col)) (result#getvalue row col)))
;;

let unexpected_row row = raise_s [%message "unexpected row" (row : string option list)]

let transaction t ~f =
  t.transactions <- t.transactions + 1;
  control t "BEGIN";
  match f () with
  | result ->
    control t "COMMIT";
    result
  | exception exn ->
    control t "ROLLBACK";
    raise exn
;;

let truncate_all t =
  command
    t
    "TRUNCATE composition, nav_snapshot, rebalance_transition, consumer_offset, price, \
     etf_price"
;;

let float_param x = sprintf "%.17g" x
let int_param = Int.to_string
let ts_param ts = Int.to_string (Time_ns.to_int_ns_since_epoch ts / 1_000)
let ts_of_micros s = Time_ns.of_int_ns_since_epoch (Int.of_string s * 1_000)

let ts_value param =
  sprintf {|timestamptz 'epoch' + $%d::bigint * interval '1 microsecond'|} param
;;

let ts_column column = sprintf "(extract(epoch from %s) * 1000000)::bigint" column

let single_int t ?params sql =
  match query t ?params sql with
  | [] -> None
  | [ [ Some value ] ] -> Some (Int.of_string value)
  | rows -> raise_s [%message "expected one value" (rows : string option list list)]
;;

let holdings_to_json holdings =
  `List
    (Array.to_list holdings
     |> List.map ~f:(fun { Holding.symbol; units } ->
       `Assoc [ "symbol", `String symbol; "units", `Float units ]))
  |> Yojson.Safe.to_string
;;

let holdings_of_json json =
  let number = function
    | `Float x -> x
    | `Int x -> Float.of_int x
    | `Intlit s -> Float.of_string s
    | json -> raise_s [%message "expected a number" (Yojson.Safe.to_string json)]
  in
  Yojson.Safe.from_string json
  |> Yojson.Safe.Util.to_list
  |> List.map ~f:(fun holding ->
    { Holding.symbol = Yojson.Safe.Util.(member "symbol" holding |> to_string)
    ; units = number (Yojson.Safe.Util.member "units" holding)
    })
  |> Array.of_list
;;

let insert_composition t (c : Composition.t) ~effective_ts =
  command
    t
    (sprintf
       {|INSERT INTO composition
           (etf, version, effective_ts, holdings, cash, shares_outstanding)
         VALUES ($1, $2, %s, $4, $5, $6)
         ON CONFLICT (etf, version) DO NOTHING|}
       (ts_value 3))
    ~params:
      [| c.etf
       ; int_param c.version
       ; ts_param effective_ts
       ; holdings_to_json c.holdings
       ; float_param c.cash
       ; float_param c.shares_outstanding
      |]
;;

let composition_version t ~etf =
  single_int
    t
    "SELECT version FROM composition WHERE etf = $1 ORDER BY version DESC LIMIT 1"
    ~params:[| etf |]
;;

let latest_compositions t =
  query
    t
    (sprintf
       {|SELECT DISTINCT ON (etf) etf, version, %s, holdings, cash, shares_outstanding
         FROM composition
         ORDER BY etf, version DESC|}
       (ts_column "effective_ts"))
  |> List.map ~f:(function
    | [ Some etf; Some version; Some ts; Some holdings; Some cash; Some shares ] ->
      ( { Composition.etf
        ; version = Int.of_string version
        ; holdings = holdings_of_json holdings
        ; cash = Float.of_string cash
        ; shares_outstanding = Float.of_string shares
        }
      , ts_of_micros ts )
    | row -> unexpected_row row)
;;

let price_table = function
  | Holding_prices -> "price", "symbol"
  | Etf_prices -> "etf_price", "etf"
;;

let upsert_price t table (p : Price.t) =
  let table, key = price_table table in
  command
    t
    (sprintf
       {|INSERT INTO %s (%s, price, source_offset, ts) VALUES ($1, $2, $3, %s)
         ON CONFLICT (%s) DO UPDATE
         SET price = EXCLUDED.price, source_offset = EXCLUDED.source_offset, ts = EXCLUDED.ts|}
       table
       key
       (ts_value 4)
       key)
    ~params:[| p.symbol; float_param p.price; int_param p.source_offset; ts_param p.ts |]
;;

let price_offset t table ~symbol =
  let table, key = price_table table in
  single_int
    t
    (sprintf "SELECT source_offset FROM %s WHERE %s = $1" table key)
    ~params:[| symbol |]
;;

let prices t table =
  let table, key = price_table table in
  query
    t
    (sprintf
       "SELECT %s, price, source_offset, %s FROM %s ORDER BY %s"
       key
       (ts_column "ts")
       table
       key)
  |> List.map ~f:(function
    | [ Some symbol; Some price; Some offset; Some ts ] ->
      { Price.symbol
      ; price = Float.of_string price
      ; source_offset = Int.of_string offset
      ; ts = ts_of_micros ts
      }
    | row -> unexpected_row row)
;;

let upsert_snapshot t (s : Snapshot.t) =
  command
    t
    (sprintf
       {|INSERT INTO nav_snapshot (etf, nav, premium, source_offset, ts)
         VALUES ($1, $2, $3, $4, %s)
         ON CONFLICT (etf) DO UPDATE
         SET nav = EXCLUDED.nav, premium = EXCLUDED.premium,
             source_offset = EXCLUDED.source_offset, ts = EXCLUDED.ts|}
       (ts_value 5))
    ~params:
      [| s.etf
       ; float_param s.nav
       ; Option.value_map s.premium ~default:Postgresql.null ~f:float_param
       ; int_param s.source_offset
       ; ts_param s.ts
      |]
;;

let snapshot_offset t ~etf =
  single_int t "SELECT source_offset FROM nav_snapshot WHERE etf = $1" ~params:[| etf |]
;;

let snapshots t =
  query
    t
    (sprintf
       "SELECT etf, nav, premium, source_offset, %s FROM nav_snapshot ORDER BY etf"
       (ts_column "ts"))
  |> List.map ~f:(function
    | [ Some etf; Some nav; premium; Some offset; Some ts ] ->
      { Snapshot.etf
      ; nav = Float.of_string nav
      ; premium = Option.map premium ~f:Float.of_string
      ; source_offset = Int.of_string offset
      ; ts = ts_of_micros ts
      }
    | row -> unexpected_row row)
;;

let set_next_offset t ~topic offset =
  command
    t
    {|INSERT INTO consumer_offset (topic, next_offset) VALUES ($1, $2)
      ON CONFLICT (topic) DO UPDATE SET next_offset = EXCLUDED.next_offset|}
    ~params:[| topic; int_param offset |]
;;

let next_offset t ~topic =
  single_int
    t
    "SELECT next_offset FROM consumer_offset WHERE topic = $1"
    ~params:[| topic |]
;;
