open! Core
open Nav_config
open Nav_data
open Nav_engine
open Nav_store

(* Usage: crash.exe ENGINE. Set CRASH_SEED to repeat a run's choices; kill timing still
   varies with the machine. *)

let engine = (Sys.get_argv ()).(1)
let conninfo = Config.postgres_test ()
let max_kills = 8
let batch_sizes = [ 50; 333; 1000 ]

let seed =
  match Sys.getenv "CRASH_SEED" with
  | Some seed -> Int.of_string seed
  | None -> Time_ns.to_int_ns_since_epoch (Time_ns.now ()) % 1_000_000
;;

let random = Random.State.make [| seed |]

let spawn args =
  Out_channel.flush stdout;
  match Core_unix.fork () with
  | `In_the_child ->
    let devnull = Core_unix.openfile ~mode:[ Core_unix.O_WRONLY ] "/dev/null" in
    Core_unix.dup2 ~src:devnull ~dst:Core_unix.stdout ();
    never_returns
      (Core_unix.exec
         ~prog:engine
         ~argv:(engine :: args)
         ~env:(`Extend [ "NAV_POSTGRES", conninfo ])
         ())
  | `In_the_parent pid -> pid
;;

let wait_until pid ~deadline =
  let rec loop () =
    match Core_unix.wait_nohang (`Pid pid) with
    | Some (_, status) -> `Exited status
    | None ->
      if Time_ns.( >= ) (Time_ns.now ()) deadline
      then `Running
      else (
        ignore (Core_unix.nanosleep 0.005 : float);
        loop ())
  in
  loop ()
;;

let expect_success what (status : Core_unix.Exit_or_signal.t) =
  match status with
  | Ok () -> ()
  | Error error ->
    raise_s
      [%message "engine failed" (what : string) (error : Core_unix.Exit_or_signal.error)]
;;

(* Exit status 2 means another session still holds the lock. A closed or killed
   session's lock is released shortly after, so retry. *)
let lock_busy : Core_unix.Exit_or_signal.t -> bool = function
  | Error (`Exit_non_zero 2) -> true
  | _ -> false
;;

let rec run_to_completion what args =
  let status = Core_unix.waitpid (spawn args) in
  if lock_busy status
  then (
    ignore (Core_unix.nanosleep 0.1 : float);
    run_to_completion what args)
  else expect_success what status
;;

let () =
  let path = Filename_unix.temp_file "nav-crash" ".events" in
  let config = { Synthetic.Config.default with events = 200_000 } in
  ignore
    (Event_file.with_writer path ~f:(fun write -> Synthetic.generate config ~f:write)
     : Synthetic.Summary.t);
  let topic = "file:" ^ path in
  let args ~batch =
    [ "-model"; "incremental"; "-writer"; "optimized"; "-input"; path ]
    @ [ "-batch"; Int.to_string batch; "-idle-seconds"; "0" ]
  in
  let store = Store.connect conninfo in
  (* A second engine on the same input must refuse to start. *)
  let holder = Store.connect conninfo in
  assert (Store.try_advisory_lock holder ~key:topic);
  (match Core_unix.waitpid (spawn (args ~batch:100)) with
   | Error (`Exit_non_zero 2) -> ()
   | status ->
     raise_s
       [%message
         "engine ran while the lock was held" (status : Core_unix.Exit_or_signal.t)]);
  Store.close holder;
  (* The uninterrupted run. *)
  Store.truncate_all store;
  let started = Time_ns.now () in
  run_to_completion "uninterrupted run" (args ~batch:250);
  let seconds = Time_ns.Span.to_sec (Time_ns.diff (Time_ns.now ()) started) in
  let final_compaction = Compaction.run store in
  let reference = Tables.read store ~topic in
  [%test_result: int option] reference.next_offset ~expect:(Some config.events);
  (* Kill at random points, restarting each time with a random batch size. *)
  Store.truncate_all store;
  let kills = Queue.create () in
  let live_compactions = ref 0 in
  let rec run () =
    let batch = List.random_element_exn ~random_state:random batch_sizes in
    let pid = spawn (args ~batch) in
    if Queue.length kills >= max_kills
    then (
      let status = Core_unix.waitpid pid in
      if lock_busy status
      then (
        ignore (Core_unix.nanosleep 0.1 : float);
        run ())
      else expect_success "final run" status)
    else (
      (* Within the time the remaining events should take, so that later kills still
         land before the engine finishes. *)
      let remaining =
        let committed = Store.next_offset store ~topic |> Option.value ~default:0 in
        seconds *. Float.of_int (config.events - committed) /. Float.of_int config.events
      in
      let delay = 0.05 +. Random.State.float random (0.8 *. remaining) in
      let deadline = Time_ns.add (Time_ns.now ()) (Time_ns.Span.of_sec delay) in
      match wait_until pid ~deadline with
      | `Exited (Ok ()) -> ()
      | `Exited status when lock_busy status ->
        ignore (Core_unix.nanosleep 0.1 : float);
        run ()
      | `Exited status -> expect_success "restarted run" status
      | `Running ->
        (* Terminal rebalances can be compacted while the engine writes. *)
        if Random.State.bool random
        then (
          ignore (Compaction.run store : Compaction.Report.t);
          incr live_compactions);
        Signal_unix.send_exn Signal.kill (`Pid pid);
        ignore (Core_unix.waitpid pid : Core_unix.Exit_or_signal.t);
        Queue.enqueue kills (Store.next_offset store ~topic |> Option.value ~default:0);
        run ())
  in
  run ();
  ignore (Compaction.run store : Compaction.Report.t);
  Tables.check ~expect:reference (Tables.read store ~topic);
  Store.close store;
  Core_unix.unlink path;
  printf
    "crash ok (CRASH_SEED=%d): %d events, killed %d times with next_offset at [%s], %d \
     compactions while running; tables equal the uninterrupted run\n"
    seed
    config.events
    (Queue.length kills)
    (Queue.to_list kills |> List.map ~f:Int.to_string |> String.concat ~sep:", ")
    !live_compactions;
  print_s
    [%message
      "compaction of the uninterrupted run" (final_compaction : Compaction.Report.t)]
;;
