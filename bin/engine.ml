open! Core
open Nav_config
open Nav_data
open Nav_engine
open Nav_kafka
open Nav_store

let run
  ~model_name
  ~writer_name
  ~input
  ~topic
  ~batch_size
  ~max_events
  ~idle_seconds
  ~reset
  ~scheduled
  =
  let model =
    match model_name with
    | `Full -> Model.full ()
    | `Incremental -> Model.incremental ()
    | `Checked -> Model.checked ()
  in
  let offset_key =
    Option.value_map input ~default:topic ~f:(fun path -> "file:" ^ path)
  in
  let store =
    match writer_name with
    | `None -> None
    | `Baseline | `Optimized -> Some (Store.connect (Config.postgres ()))
  in
  let start_offset =
    match store with
    | None -> 0
    | Some store ->
      if not (Store.try_advisory_lock store ~key:offset_key)
      then (
        eprintf "another engine is already consuming %s\n" offset_key;
        Stdlib.exit 2);
      if reset then Store.truncate_all store;
      let events, offset = Recovery.load store ~topic:offset_key in
      model.restore events;
      Store.reset_stats store;
      offset
  in
  let writer =
    match writer_name, store with
    | `Baseline, Some store -> Baseline_writer.create store ~topic:offset_key
    | `Optimized, Some store -> Optimized_writer.create store ~topic:offset_key
    | _, _ -> Writer.none
  in
  let source =
    match input with
    | Some path -> Event_file.source path
    | None -> Consumer.create ~brokers:(Config.kafka_brokers ()) ~topic ()
  in
  let report =
    Engine.run
      ?max_events
      ~scheduled
      ~idle_timeout:(Time_ns.Span.of_sec idle_seconds)
      ~batch_size
      ~start_offset
      ~source
      ~writer
      ~model
      ()
  in
  source.close ();
  let db = Option.map store ~f:Store.stats in
  Option.iter store ~f:Store.close;
  print_s
    [%message (start_offset : int) (report : Engine.Report.t) (db : Store.Stats.t option)];
  match report.model_stats.oracle with
  | Some { Model.Oracle.mismatches; affected_mismatches; _ }
    when mismatches > 0 || affected_mismatches > 0 ->
    eprintf
      "%d mismatches and %d batches with different affected ETFs between incremental and \
       full recompute\n"
      mismatches
      affected_mismatches;
    Stdlib.exit 1
  | _ -> ()
;;

let command =
  Command.basic
    ~summary:"Consume events, keep NAVs current and persist them"
    (let%map_open.Command model_name =
       flag
         "model"
         (optional_with_default
            `Incremental
            (Arg_type.of_alist_exn
               [ "full", `Full; "incremental", `Incremental; "checked", `Checked ]))
         ~doc:
           "MODEL full (recompute every affected ETF per event), incremental (default, \
            one stabilization per batch) or checked (incremental compared with full \
            after every batch)"
     and writer_name =
       flag
         "writer"
         (optional_with_default
            `Optimized
            (Arg_type.of_alist_exn
               [ "none", `None; "baseline", `Baseline; "optimized", `Optimized ]))
         ~doc:
           "WRITER none (engine only), baseline (one transaction per event, reads before \
            writes) or optimized (default, one transaction per batch)"
     and input =
       flag "input" (optional string) ~doc:"FILE read an event file instead of Kafka"
     and topic =
       flag "topic" (optional_with_default Config.topic string) ~doc:"TOPIC Kafka topic"
     and batch_size =
       flag "batch" (optional_with_default 100 int) ~doc:"N events per poll (default 100)"
     and max_events = flag "max-events" (optional int) ~doc:"N stop after N events"
     and idle_seconds =
       flag
         "idle-seconds"
         (optional_with_default 5. float)
         ~doc:"S stop after S seconds without events (default 5)"
     and reset =
       flag "reset" no_arg ~doc:" truncate all tables first and start from offset 0"
     and scheduled =
       flag
         "scheduled"
         no_arg
         ~doc:" events were replayed with -rate; report latency since their timestamps"
     in
     fun () ->
       run
         ~model_name
         ~writer_name
         ~input
         ~topic
         ~batch_size
         ~max_events
         ~idle_seconds
         ~reset
         ~scheduled)
;;

let () = Command_unix.run command
