open! Core
open Nav_config
open Nav_data
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

(* The stage 5 service: full recompute and the baseline writer. *)
let baseline = Model.full, Baseline_writer.create
let optimized = Model.incremental, Optimized_writer.create

(* Restores from [store], then runs until [max_events] or the end of [events]. *)
let run_engine store (model, writer) ~batch_size ?max_events () =
  let model : Model.t = model () in
  let restored, start_offset = Recovery.load store ~topic in
  model.restore restored;
  ignore
    (Engine.run
       ?max_events
       ~idle_timeout:Time_ns.Span.zero
       ~batch_size
       ~start_offset
       ~source:(Source.in_memory events)
       ~writer:(writer store ~topic)
       ~model
       ()
     : Engine.Report.t)
;;

let check_against_oracle (tables : Tables.t) =
  let oracle = Full_recompute.of_events (Array.to_list events) in
  let expected =
    List.map (Full_recompute.etfs oracle) ~f:(fun etf ->
      etf, Full_recompute.nav oracle ~etf, Full_recompute.premium oracle ~etf)
  in
  let actual = List.map tables.snapshots ~f:(fun s -> s.etf, s.nav, s.premium) in
  [%test_result: (string * float option * float option) list] actual ~expect:expected;
  [%test_result: int option] tables.next_offset ~expect:(Some (Array.length events))
;;

(* Truncates, runs [f] and returns the tables and the statements per event. *)
let fresh store ~f =
  Store.truncate_all store;
  Store.reset_stats store;
  f ();
  let { Store.Stats.reads; writes; transactions } = Store.stats store in
  let per_event n = Float.of_int n /. Float.of_int (Array.length events) in
  ( Tables.read store ~topic
  , sprintf
      "%.2f reads, %.2f writes, %.3f transactions per event"
      (per_event reads)
      (per_event writes)
      (per_event transactions) )
;;

let () =
  let store = Store.connect (Config.postgres_test ()) in
  let reference, baseline_cost =
    fresh store ~f:(fun () -> run_engine store baseline ~batch_size:50 ())
  in
  check_against_oracle reference;
  printf "baseline, batch 50: %s\n" baseline_cost;
  let restarted, _ =
    fresh store ~f:(fun () ->
      run_engine store baseline ~batch_size:50 ~max_events:1_234 ();
      run_engine store baseline ~batch_size:50 ())
  in
  Tables.check ~expect:reference restarted;
  List.iter [ 1; 50; 1000 ] ~f:(fun batch_size ->
    let tables, cost =
      fresh store ~f:(fun () -> run_engine store optimized ~batch_size ())
    in
    Tables.check ~expect:reference tables;
    printf "optimized, batch %d: %s\n" batch_size cost);
  (* Restarting with another batch size, or another writer, changes nothing. *)
  let mixed, _ =
    fresh store ~f:(fun () ->
      run_engine store optimized ~batch_size:50 ~max_events:1_234 ();
      run_engine store baseline ~batch_size:7 ~max_events:500 ();
      run_engine store optimized ~batch_size:1000 ())
  in
  Tables.check ~expect:reference mixed;
  Store.close store;
  printf
    "baseline ok: %d events, %d snapshots; restarted, optimized and mixed runs give \
     equal tables\n"
    (Array.length events)
    (List.length reference.snapshots)
;;
