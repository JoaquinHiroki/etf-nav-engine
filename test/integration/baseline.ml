open! Core
open Nav_config
open Nav_data
open Nav_domain
open Nav_engine
open Nav_graph
open Nav_source
open Nav_store

let topic = "test:baseline"

let events =
  let events = Queue.create () in
  let config =
    { Synthetic.Config.default with
      events = 3_000
    ; symbols = 40
    ; etfs = 5
    ; basket_size = 8
    ; rebalance_ratio = 0.002
    ; rebalance_step_ratio = 0.05
    ; composition_ratio = 0.002
    }
  in
  ignore (Synthetic.generate config ~f:(Queue.enqueue events) : Synthetic.Summary.t);
  Queue.to_array events
;;

module Tables = struct
  type t =
    { snapshots : Store.Snapshot.t list
    ; prices : Store.Price.t list
    ; etf_prices : Store.Price.t list
    ; compositions : (Composition.t * Timestamp.t) list
    ; next_offset : int option
    }
  [@@deriving compare, sexp]

  let read store =
    { snapshots = Store.snapshots store
    ; prices = Store.prices store Holding_prices
    ; etf_prices = Store.prices store Etf_prices
    ; compositions = Store.latest_compositions store
    ; next_offset = Store.next_offset store ~topic
    }
  ;;
end

let run_engine store ?max_events () =
  let state = Full_recompute.create () in
  let start_offset = Recovery.restore store state ~topic in
  ignore
    (Engine.run
       ?max_events
       ~idle_timeout:Time_ns.Span.zero
       ~batch_size:50
       ~start_offset
       ~source:(Source.in_memory events)
       ~writer:(Baseline_writer.create store ~topic)
       state
     : Engine.Report.t)
;;

let check_against_oracle (tables : Tables.t) =
  let oracle = Full_recompute.of_events (Array.to_list events) in
  let expected =
    List.filter_map (Full_recompute.etfs oracle) ~f:(fun etf ->
      let%map.Option nav = Full_recompute.nav oracle ~etf in
      etf, nav, Full_recompute.premium oracle ~etf)
  in
  let actual = List.map tables.snapshots ~f:(fun s -> s.etf, s.nav, s.premium) in
  [%test_result: (string * float * float option) list] actual ~expect:expected;
  [%test_result: int option] tables.next_offset ~expect:(Some (Array.length events))
;;

let () =
  let store = Store.connect (Config.postgres_test ()) in
  Store.truncate_all store;
  Store.reset_stats store;
  run_engine store ();
  let stats = Store.stats store in
  let uninterrupted = Tables.read store in
  check_against_oracle uninterrupted;
  Store.truncate_all store;
  run_engine store ~max_events:1_234 ();
  run_engine store ();
  [%test_result: Tables.t] (Tables.read store) ~expect:uninterrupted;
  Store.close store;
  printf
    "baseline ok: %d events, %d snapshots, %.2f reads per write\n"
    (Array.length events)
    (List.length uninterrupted.snapshots)
    (Float.of_int stats.reads /. Float.of_int stats.writes)
;;
