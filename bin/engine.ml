open! Core
open Nav_config
open Nav_data
open Nav_engine
open Nav_graph
open Nav_kafka
open Nav_store

let run ~writer_name ~input ~topic ~batch_size ~max_events ~idle_seconds ~reset ~scheduled
  =
  let state = Full_recompute.create () in
  let offset_key =
    Option.value_map input ~default:topic ~f:(fun path -> "file:" ^ path)
  in
  let store =
    match writer_name with
    | `None -> None
    | `Baseline -> Some (Store.connect (Config.postgres ()))
  in
  let start_offset =
    match store with
    | None -> 0
    | Some store ->
      if reset then Store.truncate_all store;
      let offset = Recovery.restore store state ~topic:offset_key in
      Store.reset_stats store;
      offset
  in
  let writer =
    match store with
    | None -> Writer.none
    | Some store -> Baseline_writer.create store ~topic:offset_key
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
      state
  in
  source.close ();
  let db = Option.map store ~f:Store.stats in
  Option.iter store ~f:Store.close;
  print_s
    [%message (start_offset : int) (report : Engine.Report.t) (db : Store.Stats.t option)]
;;

let command =
  Command.basic
    ~summary:"Consume events, keep NAVs current and persist them"
    (let%map_open.Command writer_name =
       flag
         "writer"
         (optional_with_default
            `Baseline
            (Arg_type.of_alist_exn [ "none", `None; "baseline", `Baseline ]))
         ~doc:"WRITER none (engine only) or baseline (default)"
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
