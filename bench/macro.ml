open! Core
open Nav_engine
open Nav_store

(* Runs [engine.exe] once per configuration and round, each in its own process, and
   prints the median and range of each measure as a Markdown table. Rounds are
   interleaved so that drift in the machine spreads over every configuration. *)

module Config = struct
  type t =
    { name : string
    ; args : string list
    ; events : int
    ; writer : bool
    }

  let engine_only ~model ~batch ~events =
    { name = sprintf "%s, no writer, batch %d" model batch
    ; args = [ "-model"; model; "-writer"; "none"; "-batch"; Int.to_string batch ]
    ; events
    ; writer = false
    }
  ;;

  let with_writer ~writer ~batch ~events =
    { name = sprintf "incremental, %s writer, batch %d" writer batch
    ; args = [ "-writer"; writer; "-reset"; "-batch"; Int.to_string batch ]
    ; events
    ; writer = true
    }
  ;;

  let all ~scale =
    let n events = Int.max 1 (Float.iround_nearest_exn (Float.of_int events *. scale)) in
    List.concat_map [ "full"; "incremental" ] ~f:(fun model ->
      List.map [ 1; 100; 1000 ] ~f:(fun batch ->
        engine_only ~model ~batch ~events:(n 10_000_000)))
    @ [ with_writer ~writer:"baseline" ~batch:1 ~events:(n 2_000)
      ; with_writer ~writer:"optimized" ~batch:1 ~events:(n 2_000)
      ; with_writer ~writer:"optimized" ~batch:100 ~events:(n 200_000)
      ; with_writer ~writer:"optimized" ~batch:1000 ~events:(n 1_000_000)
      ]
  ;;
end

module Run = struct
  type t =
    { report : Engine.Report.t
    ; db : Store.Stats.t option
    }

  let parse output =
    match Sexp.of_string (String.strip output) with
    | List
        [ List [ Atom "start_offset"; _ ]
        ; List [ Atom "report"; report ]
        ; List [ Atom "db"; db ]
        ] ->
      { report = Engine.Report.t_of_sexp report
      ; db = [%of_sexp: Store.Stats.t option] db
      }
    | sexp -> raise_s [%message "unexpected engine output" (sexp : Sexp.t)]
  ;;

  let exec ~engine ~input (config : Config.t) =
    let args =
      config.args
      @ [ "-input"
        ; input
        ; "-max-events"
        ; Int.to_string config.events
        ; "-idle-seconds"
        ; "0"
        ]
    in
    let process = Core_unix.create_process ~prog:engine ~args in
    Core_unix.close process.stdin;
    let output = In_channel.input_all (Core_unix.in_channel_of_descr process.stdout) in
    let errors = In_channel.input_all (Core_unix.in_channel_of_descr process.stderr) in
    match Core_unix.waitpid process.pid with
    | Ok () -> parse output
    | Error error ->
      raise_s
        [%message
          "engine failed"
            ~config:config.name
            (error : Core_unix.Exit_or_signal.error)
            (errors : string)]
  ;;
end

let count n = Int.to_string_hum ~delimiter:',' n

let median xs =
  let sorted = List.sort xs ~compare:Float.compare |> Array.of_list in
  let n = Array.length sorted in
  if n % 2 = 1 then sorted.(n / 2) else (sorted.((n / 2) - 1) +. sorted.(n / 2)) /. 2.
;;

let rate x =
  if Float.( >= ) x 1_000. then sprintf "%.1fk" (x /. 1_000.) else sprintf "%.0f" x
;;

let duration_us x =
  if Float.( >= ) x 1_000_000.
  then sprintf "%.2f s" (x /. 1_000_000.)
  else if Float.( >= ) x 1_000.
  then sprintf "%.2f ms" (x /. 1_000.)
  else sprintf "%.0f µs" x
;;

let spread format xs =
  let lo = List.reduce_exn xs ~f:Float.min in
  let hi = List.reduce_exn xs ~f:Float.max in
  sprintf "%s (%s–%s)" (format (median xs)) (format lo) (format hi)
;;

let latency (run : Run.t) f =
  Option.value_map run.report.processing_latency ~default:Float.nan ~f
;;

let row (config : Config.t) ~rounds (runs : Run.t list) =
  let name =
    if List.length runs = rounds
    then config.name
    else sprintf "%s (%d of %d runs)" config.name (List.length runs) rounds
  in
  match runs with
  | [] -> printf "| %s | %s | failed | | | | | |\n" name (count config.events)
  | first :: _ ->
    let statements =
      Option.value_map first.db ~default:"–" ~f:(fun db ->
        sprintf "%.3f" (Float.of_int (db.reads + db.writes) /. Float.of_int config.events))
    in
    let recomputes =
      Option.value_map first.report.model_stats.recomputes ~default:"–" ~f:(fun r ->
        count (r.positions + r.sums))
    in
    printf
      "| %s | %s | %s | %s | %s | %s | %s | %s |\n"
      name
      (count config.events)
      (spread rate (List.map runs ~f:(fun r -> r.report.events_per_second)))
      (spread duration_us (List.map runs ~f:(fun r -> latency r (fun l -> l.p50_us))))
      (spread duration_us (List.map runs ~f:(fun r -> latency r (fun l -> l.p99_us))))
      (count first.report.nav_updates)
      recomputes
      statements
;;

let command =
  Command.basic
    ~summary:"Run the engine benchmarks and print a Markdown table"
    (let%map_open.Command engine = flag "engine" (required string) ~doc:"PATH engine.exe"
     and input = flag "input" (required string) ~doc:"FILE event file"
     and runs =
       flag "runs" (optional_with_default 5 int) ~doc:"N runs of each (default 5)"
     and scale =
       flag
         "scale"
         (optional_with_default 1. float)
         ~doc:"F multiply every event count by F (default 1)"
     and skip_writers =
       flag "skip-writers" no_arg ~doc:" only the runs without Postgres"
     in
     fun () ->
       let configs =
         List.filter (Config.all ~scale) ~f:(fun c -> not (skip_writers && c.writer))
       in
       let results = Hashtbl.create (module String) in
       let failures = ref 0 in
       for round = 1 to runs do
         List.iter configs ~f:(fun config ->
           eprintf "round %d/%d: %s\n%!" round runs config.name;
           match Or_error.try_with (fun () -> Run.exec ~engine ~input config) with
           | Ok run -> Hashtbl.add_multi results ~key:config.name ~data:run
           | Error error ->
             incr failures;
             eprintf "%s\n%!" (Error.to_string_hum error))
       done;
       printf
         "%d runs of each, interleaved; median (min–max). Latency is per batch, from \
          poll to write. Recomputes are position and sum nodes evaluated by the graph.\n\n"
         runs;
       printf
         "| Run | Events | Events/s | p50 | p99 | NAV updates | Recomputes | \
          Statements/event |\n";
       printf
         "|-----|--------|----------|-----|-----|-------------|------------|------------------|\n";
       List.iter configs ~f:(fun config ->
         row config ~rounds:runs (List.rev (Hashtbl.find_multi results config.name)));
       if !failures > 0
       then (
         eprintf "%d engine runs failed\n%!" !failures;
         exit 1))
;;

let () = Command_unix.run command
