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
    ; nav : float option
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

let advisory_xact_lock t ~key =
  ignore
    (query t "SELECT pg_advisory_xact_lock(hashtext($1))" ~params:[| key |]
     : string option list list)
;;

let try_advisory_lock t ~key =
  match query t "SELECT pg_try_advisory_lock(hashtext($1))" ~params:[| key |] with
  | [ [ Some "t" ] ] -> true
  | [ [ Some "f" ] ] -> false
  | rows -> raise_s [%message "unexpected lock result" (rows : string option list list)]
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

let holding_json { Holding.symbol; units } =
  `Assoc [ "symbol", `String symbol; "units", `Float units ]
;;

let holdings_json holdings = `List (Array.to_list holdings |> List.map ~f:holding_json)
let holdings_to_json holdings = Yojson.Safe.to_string (holdings_json holdings)

let number = function
  | `Float x -> x
  | `Int x -> Float.of_int x
  | `Intlit s -> Float.of_string s
  | json -> raise_s [%message "expected a number" (Yojson.Safe.to_string json)]
;;

let holding_of_json json =
  { Holding.symbol = Yojson.Safe.Util.(member "symbol" json |> to_string)
  ; units = number (Yojson.Safe.Util.member "units" json)
  }
;;

let holdings_of_json_value json =
  Yojson.Safe.Util.to_list json |> List.map ~f:holding_of_json |> Array.of_list
;;

let holdings_of_json json = holdings_of_json_value (Yojson.Safe.from_string json)

let composition_json (c : Composition.t) =
  `Assoc
    [ "etf", `String c.etf
    ; "version", `Int c.version
    ; "holdings", holdings_json c.holdings
    ; "cash", `Float c.cash
    ; "shares_outstanding", `Float c.shares_outstanding
    ]
;;

let composition_of_json json =
  let member name = Yojson.Safe.Util.member name json in
  { Composition.etf = Yojson.Safe.Util.to_string (member "etf")
  ; version = Yojson.Safe.Util.to_int (member "version")
  ; holdings = holdings_of_json_value (member "holdings")
  ; cash = number (member "cash")
  ; shares_outstanding = number (member "shares_outstanding")
  }
;;

let step_json (step : Rebalance_step.t) =
  let kind name rest = `Assoc (("step", `String name) :: rest) in
  match step with
  | Announce c -> kind "announce" [ "target", composition_json c ]
  | Validate -> kind "validate" []
  | Reject reason -> kind "reject" [ "reason", `String reason ]
  | Begin_applying -> kind "begin_applying" []
  | Progress h -> kind "progress" [ "holding", holding_json h ]
  | Apply -> kind "apply" []
  | Settle -> kind "settle" []
;;

let step_of_json json : Rebalance_step.t =
  let member name = Yojson.Safe.Util.member name json in
  match Yojson.Safe.Util.to_string (member "step") with
  | "announce" -> Announce (composition_of_json (member "target"))
  | "validate" -> Validate
  | "reject" -> Reject (Yojson.Safe.Util.to_string (member "reason"))
  | "begin_applying" -> Begin_applying
  | "progress" -> Progress (holding_of_json (member "holding"))
  | "apply" -> Apply
  | "settle" -> Settle
  | step -> raise_s [%message "unknown rebalance step" step]
;;

let steps_to_json steps = Yojson.Safe.to_string (`List (List.map steps ~f:step_json))

let steps_of_json json =
  Yojson.Safe.from_string json |> Yojson.Safe.Util.to_list |> List.map ~f:step_of_json
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

let insert_composition_if_newer t (c : Composition.t) ~effective_ts =
  command
    t
    (sprintf
       {|INSERT INTO composition
           (etf, version, effective_ts, holdings, cash, shares_outstanding)
         SELECT $1::text, $2::int, %s, $4::jsonb, $5::float8, $6::float8
         WHERE NOT EXISTS
           (SELECT 1 FROM composition WHERE etf = $1::text AND version >= $2::int)|}
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

let insert_transition t (tr : Rebalance.Transition.t) =
  command
    t
    (sprintf
       {|INSERT INTO rebalance_transition
           (etf, rebalance_id, seq, state, detail, first_ts, last_ts, merged_count)
         VALUES ($1, $2, $3, $4, $5, %s, %s, $8)|}
       (ts_value 6)
       (ts_value 7))
    ~params:
      [| tr.etf
       ; int_param tr.id
       ; int_param tr.seq
       ; Rebalance.Phase.to_string tr.phase
       ; steps_to_json tr.steps
       ; ts_param tr.first_ts
       ; ts_param tr.last_ts
       ; int_param (Rebalance.Transition.merged_count tr)
      |]
;;

let last_transition_seq t ~etf ~id =
  single_int
    t
    "SELECT max(seq) FROM rebalance_transition WHERE etf = $1 AND rebalance_id = $2 \
     HAVING count(*) > 0"
    ~params:[| etf; int_param id |]
;;

let delete_transitions t ~etf ~id =
  command
    t
    "DELETE FROM rebalance_transition WHERE etf = $1 AND rebalance_id = $2"
    ~params:[| etf; int_param id |]
;;

let transitions t =
  query
    t
    (sprintf
       {|SELECT etf, rebalance_id, seq, state, detail, %s, %s, merged_count
         FROM rebalance_transition
         ORDER BY etf, rebalance_id, seq|}
       (ts_column "first_ts")
       (ts_column "last_ts"))
  |> List.map ~f:(function
    | [ Some etf
      ; Some id
      ; Some seq
      ; Some state
      ; Some detail
      ; Some first_ts
      ; Some last_ts
      ; Some merged_count
      ] ->
      let tr =
        { Rebalance.Transition.etf
        ; id = Int.of_string id
        ; seq = Int.of_string seq
        ; phase = Rebalance.Phase.of_string state
        ; steps = steps_of_json detail
        ; first_ts = ts_of_micros first_ts
        ; last_ts = ts_of_micros last_ts
        }
      in
      if Rebalance.Transition.merged_count tr <> Int.of_string merged_count
      then raise_s [%message "merged_count disagrees with detail" etf id seq merged_count];
      tr
    | row -> unexpected_row row)
;;

let transition_storage t =
  match
    query
      t
      "SELECT count(*), coalesce(sum(pg_column_size(r.*)), 0) FROM rebalance_transition r"
  with
  | [ [ Some rows; Some bytes ] ] -> Int.of_string rows, Int.of_string bytes
  | rows ->
    raise_s [%message "unexpected storage result" (rows : string option list list)]
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

(* Array literals for unnest. Text elements are quoted with backslash escapes; numbers
   and NULL are bare. *)
let array_param elements = "{" ^ String.concat ~sep:"," elements ^ "}"

let quoted s =
  "\""
  ^ String.concat_map s ~f:(function
    | '"' -> "\\\""
    | '\\' -> "\\\\"
    | c -> String.of_char c)
  ^ "\""
;;

let text_array xs = array_param (List.map xs ~f:quoted)
let float_array xs = array_param (List.map xs ~f:float_param)
let int_array xs = array_param (List.map xs ~f:int_param)

let float_option_array xs =
  array_param (List.map xs ~f:(Option.value_map ~default:"NULL" ~f:float_param))
;;

let ts_array xs = array_param (List.map xs ~f:ts_param)

let insert_transitions t (transitions : Rebalance.Transition.t list) =
  if not (List.is_empty transitions)
  then (
    let column f = List.map transitions ~f in
    command
      t
      {|INSERT INTO rebalance_transition
          (etf, rebalance_id, seq, state, detail, first_ts, last_ts, merged_count)
        SELECT etf, rebalance_id, seq, state, detail,
               timestamptz 'epoch' + first_micros * interval '1 microsecond',
               timestamptz 'epoch' + last_micros * interval '1 microsecond',
               merged_count
        FROM unnest($1::text[], $2::int[], $3::bigint[], $4::text[], $5::jsonb[],
                    $6::bigint[], $7::bigint[], $8::int[])
          AS u(etf, rebalance_id, seq, state, detail, first_micros, last_micros,
               merged_count)|}
      ~params:
        [| text_array (column (fun tr -> tr.etf))
         ; int_array (column (fun tr -> tr.id))
         ; int_array (column (fun tr -> tr.seq))
         ; text_array (column (fun tr -> Rebalance.Phase.to_string tr.phase))
         ; text_array (column (fun tr -> steps_to_json tr.steps))
         ; ts_array (column (fun tr -> tr.first_ts))
         ; ts_array (column (fun tr -> tr.last_ts))
         ; int_array (column Rebalance.Transition.merged_count)
        |])
;;

let upsert_prices t table (prices : Price.t list) =
  if not (List.is_empty prices)
  then (
    let table, key = price_table table in
    command
      t
      (sprintf
         {|INSERT INTO %s (%s, price, source_offset, ts)
           SELECT key, price, source_offset,
                  timestamptz 'epoch' + micros * interval '1 microsecond'
           FROM unnest($1::text[], $2::float8[], $3::bigint[], $4::bigint[])
             AS u(key, price, source_offset, micros)
           ON CONFLICT (%s) DO UPDATE
           SET price = EXCLUDED.price, source_offset = EXCLUDED.source_offset,
               ts = EXCLUDED.ts
           WHERE %s.source_offset < EXCLUDED.source_offset|}
         table
         key
         key
         table)
      ~params:
        [| text_array (List.map prices ~f:(fun p -> p.symbol))
         ; float_array (List.map prices ~f:(fun p -> p.price))
         ; int_array (List.map prices ~f:(fun p -> p.source_offset))
         ; ts_array (List.map prices ~f:(fun p -> p.ts))
        |])
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
       ; Option.value_map s.nav ~default:Postgresql.null ~f:float_param
       ; Option.value_map s.premium ~default:Postgresql.null ~f:float_param
       ; int_param s.source_offset
       ; ts_param s.ts
      |]
;;

let upsert_snapshots t (snapshots : Snapshot.t list) =
  if not (List.is_empty snapshots)
  then
    command
      t
      {|INSERT INTO nav_snapshot (etf, nav, premium, source_offset, ts)
        SELECT etf, nav, premium, source_offset,
               timestamptz 'epoch' + micros * interval '1 microsecond'
        FROM unnest($1::text[], $2::float8[], $3::float8[], $4::bigint[], $5::bigint[])
          AS u(etf, nav, premium, source_offset, micros)
        ON CONFLICT (etf) DO UPDATE
        SET nav = EXCLUDED.nav, premium = EXCLUDED.premium,
            source_offset = EXCLUDED.source_offset, ts = EXCLUDED.ts
        WHERE nav_snapshot.source_offset < EXCLUDED.source_offset|}
      ~params:
        [| text_array (List.map snapshots ~f:(fun s -> s.etf))
         ; float_option_array (List.map snapshots ~f:(fun s -> s.nav))
         ; float_option_array (List.map snapshots ~f:(fun s -> s.premium))
         ; int_array (List.map snapshots ~f:(fun s -> s.source_offset))
         ; ts_array (List.map snapshots ~f:(fun s -> s.ts))
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
    | [ Some etf; nav; premium; Some offset; Some ts ] ->
      { Snapshot.etf
      ; nav = Option.map nav ~f:Float.of_string
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
