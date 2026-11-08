open! Core
open Nav_domain

type t = Postgresql.connection

let connect conninfo = new Postgresql.connection ~conninfo ()
let close (t : t) = t#finish

let exec (t : t) ~expect ~params sql =
  try t#exec ~expect ~params sql with
  | Postgresql.Error error ->
    raise_s
      [%message "postgres error" ~error:(Postgresql.string_of_error error) (sql : string)]
;;

let command t ?(params = [||]) sql =
  ignore (exec t ~expect:[ Command_ok ] ~params sql : Postgresql.result)
;;

let query t ?(params = [||]) sql = (exec t ~expect:[ Tuples_ok ] ~params sql)#get_all_lst

let transaction t ~f =
  command t "BEGIN";
  match f () with
  | result ->
    command t "COMMIT";
    result
  | exception exn ->
    command t "ROLLBACK";
    raise exn
;;

let truncate_all t =
  command t "TRUNCATE composition, nav_snapshot, rebalance_transition, consumer_offset"
;;

let float_param x = sprintf "%.17g" x
let ts_param ts = Int.to_string (Time_ns.to_int_ns_since_epoch ts / 1_000)
let ts_of_micros s = Time_ns.of_int_ns_since_epoch (Int.of_string s * 1_000)
let ts_sql column = sprintf "(extract(epoch from %s) * 1000000)::bigint" column

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
    {|INSERT INTO composition
        (etf, version, effective_ts, holdings, cash, shares_outstanding)
      VALUES ($1, $2, timestamptz 'epoch' + $3::bigint * interval '1 microsecond', $4, $5, $6)
      ON CONFLICT (etf, version) DO NOTHING|}
    ~params:
      [| c.etf
       ; Int.to_string c.version
       ; ts_param effective_ts
       ; holdings_to_json c.holdings
       ; float_param c.cash
       ; float_param c.shares_outstanding
      |]
;;

let latest_compositions t =
  query
    t
    (sprintf
       {|SELECT DISTINCT ON (etf) etf, version, %s, holdings, cash, shares_outstanding
         FROM composition
         ORDER BY etf, version DESC|}
       (ts_sql "effective_ts"))
  |> List.map ~f:(function
    | [ etf; version; ts; holdings; cash; shares_outstanding ] ->
      ( { Composition.etf
        ; version = Int.of_string version
        ; holdings = holdings_of_json holdings
        ; cash = Float.of_string cash
        ; shares_outstanding = Float.of_string shares_outstanding
        }
      , ts_of_micros ts )
    | row -> raise_s [%message "unexpected composition row" (row : string list)])
;;

let set_next_offset t ~topic offset =
  command
    t
    {|INSERT INTO consumer_offset (topic, next_offset) VALUES ($1, $2)
      ON CONFLICT (topic) DO UPDATE SET next_offset = EXCLUDED.next_offset|}
    ~params:[| topic; Int.to_string offset |]
;;

let next_offset t ~topic =
  match
    query t "SELECT next_offset FROM consumer_offset WHERE topic = $1" ~params:[| topic |]
  with
  | [] -> None
  | [ [ offset ] ] -> Some (Int.of_string offset)
  | rows -> raise_s [%message "unexpected offset rows" (rows : string list list)]
;;
