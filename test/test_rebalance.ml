open! Core
open Nav_data
open Nav_domain

let ts_of_int i = Time_ns.of_int_ns_since_epoch (i * 1_000)

let target ?(version = 2) ~etf symbols =
  let holdings =
    Array.of_list_map symbols ~f:(fun symbol -> { Holding.symbol; units = 1. })
  in
  Composition.create ~etf ~version ~holdings ~cash:0. ~shares_outstanding:1. |> ok_exn
;;

let%expect_test "transition table" =
  let name = function
    | None -> "(new)"
    | Some phase -> Rebalance.Phase.to_string phase
  in
  let kind k = String.lowercase (Sexp.to_string [%sexp (k : Rebalance.Kind.t)]) in
  printf "%-10s" "";
  List.iter Rebalance.Kind.all ~f:(fun k -> printf " %-15s" (kind k));
  print_endline "";
  List.iter (None :: List.map Rebalance.Phase.all ~f:Option.some) ~f:(fun from ->
    printf "%-10s" (name from);
    List.iter Rebalance.Kind.all ~f:(fun k ->
      printf
        " %-15s"
        (Option.value_map (Rebalance.next from k) ~default:"-" ~f:(fun phase ->
           name (Some phase))));
    print_endline "");
  [%expect
    {|
               announce        validate        reject          begin_applying  progress        apply           settle
    (new)      announced       -               -               -               -               -               -
    announced  -               validated       rejected        -               -               -               -
    validated  -               -               rejected        applying        -               -               -
    rejected   -               -               -               -               -               -               -
    applying   -               -               -               -               applying        applied         -
    applied    -               -               -               -               -               -               settled
    settled    -               -               -               -               -               -               - |}]
;;

let%expect_test "guards beyond the table" =
  let book = ref Rebalance.Book.empty in
  let step ?(etf = "X") ?(id = 1) step =
    let next, outcome = Rebalance.step !book ~etf ~id step ~ts:Time_ns.epoch in
    book := next;
    match outcome with
    | Invalid reason -> print_s [%message "invalid" ~_:(reason : Sexp.t)]
    | Accepted { phase; applied } ->
      print_s
        [%message
          ""
            ~_:(phase : Rebalance.Phase.t)
            ~applied_version:
              (Option.map applied ~f:(fun c -> c.version) : (int option[@sexp.option]))]
  in
  let x = target ~etf:"X" [ "A"; "B" ] in
  step Validate;
  step (Announce (target ~etf:"Y" [ "A" ]));
  step (Announce x);
  step ~id:2 (Announce x);
  step Validate;
  step (Progress { symbol = "A"; units = 1. });
  step Begin_applying;
  step (Progress { symbol = "Z"; units = 1. });
  step (Progress { symbol = "A"; units = 1. });
  step (Progress { symbol = "A"; units = 1. });
  step Apply;
  step (Progress { symbol = "B"; units = 1. });
  step Apply;
  step Settle;
  step Settle;
  step (Announce x);
  step ~id:2 (Announce x);
  [%expect
    {|
    (invalid ("no transition" (from ()) (kind Validate)))
    (invalid ("target is for another ETF" (target Y)))
    Announced
    (invalid ("ETF has an active rebalance" (id 1)))
    Validated
    (invalid ("no transition" (from (Validated)) (kind Progress)))
    Applying
    (invalid ("not a target holding" (symbol Z)))
    Applying
    (invalid ("already filled" (symbol A)))
    (invalid ("target holdings not filled" (unfilled 1)))
    Applying
    (Applied (applied_version 2))
    Settled
    (invalid ("no transition" (from (Settled)) (kind Settle)))
    (invalid ("no transition" (from (Settled)) (kind Announce)))
    Announced |}]
;;

(* Steps [events] through an empty book. Returns the book and the log: one row per
   accepted step, with the event's index as its offset. *)
let run_log events =
  let book, rows, invalid =
    List.foldi
      events
      ~init:(Rebalance.Book.empty, [], 0)
      ~f:(fun seq (book, rows, invalid) (etf, id, step, ts) ->
        match Rebalance.step book ~etf ~id step ~ts with
        | book, Accepted { phase; _ } ->
          book, Rebalance.Transition.create ~seq ~etf ~id ~phase step ~ts :: rows, invalid
        | book, Invalid _ -> book, rows, invalid + 1)
  in
  book, List.rev rows, invalid
;;

let sorted = List.sort ~compare:Rebalance.Transition.compare

let terminal book (t : Rebalance.Transition.t) =
  Option.exists (Rebalance.Book.find book ~etf:t.etf ~id:t.id) ~f:(fun r ->
    Rebalance.Phase.is_terminal r.phase)
;;

(* The exit test: folding the full log and the compacted log give the state built
   step by step, and compaction only rewrites terminal rebalances. *)
let check_log events =
  let book, log, invalid = run_log events in
  let compacted = Rebalance.compact log in
  [%test_result: Rebalance.Book.t]
    ~message:"fold of full log"
    (Rebalance.fold log)
    ~expect:book;
  [%test_result: Rebalance.Book.t]
    ~message:"fold of compacted log"
    (Rebalance.fold compacted)
    ~expect:book;
  [%test_result: Rebalance.Transition.t list]
    ~message:"compact is idempotent"
    (Rebalance.compact compacted)
    ~expect:compacted;
  [%test_result: Rebalance.Transition.t list]
    ~message:"rows of active rebalances are kept"
    (List.filter compacted ~f:(Fn.non (terminal book)))
    ~expect:(sorted (List.filter log ~f:(Fn.non (terminal book))));
  [%test_result: int]
    ~message:"steps are kept"
    (List.sum (module Int) compacted ~f:Rebalance.Transition.merged_count)
    ~expect:(List.length log);
  book, log, compacted, invalid
;;

module Stream = struct
  (* Rebalances follow their usual path with steps dropped, repeated or preceded by a
     stray step, and some are cut short, so that invalid steps, id reuse and active
     rebalances at the end all occur. *)
  let symbols = [ "A"; "B"; "C"; "D" ]

  let rebalance random ~etf ~id =
    let held = List.filteri symbols ~f:(fun i _ -> (i + id) % 3 <> 0) in
    let t = target ~version:(id + 2) ~etf held in
    let steps : Rebalance_step.t list =
      if Random.State.int random 4 = 0
      then Rebalance_step.[ Announce t; Validate; Reject "rejected" ]
      else
        Rebalance_step.[ Announce t; Validate; Begin_applying ]
        @ List.map held ~f:(fun symbol -> Rebalance_step.Progress { symbol; units = 1. })
        @ [ Apply; Settle ]
    in
    let stray () : Rebalance_step.t =
      match Random.State.int random 6 with
      | 0 -> Validate
      | 1 -> Apply
      | 2 -> Settle
      | 3 -> Begin_applying
      | 4 ->
        Progress
          { symbol = List.random_element_exn ~random_state:random symbols; units = 1. }
      | _ -> Reject "late"
    in
    let mutated =
      List.concat_map steps ~f:(fun step ->
        match Random.State.int random 20 with
        | 0 -> []
        | 1 -> [ step; step ]
        | 2 -> [ stray (); step ]
        | _ -> [ step ])
    in
    let kept =
      if Random.State.int random 4 = 0
      then List.take mutated (Random.State.int random (List.length mutated + 1))
      else mutated
    in
    List.map kept ~f:(fun step -> etf, id, step)
  ;;

  let interleave random sequences =
    let queues = Array.of_list_map sequences ~f:Queue.of_list in
    let rec loop acc =
      let live = Array.filter queues ~f:(Fn.non Queue.is_empty) in
      if Array.is_empty live
      then List.rev acc
      else (
        let q = live.(Random.State.int random (Array.length live)) in
        loop (Queue.dequeue_exn q :: acc))
    in
    loop []
  ;;

  let create seed =
    let random = Random.State.make [| seed |] in
    let count = 1 + Random.State.int random 6 in
    List.init count ~f:(fun _ ->
      let etf = List.random_element_exn ~random_state:random [ "X"; "Y" ] in
      rebalance random ~etf ~id:(Random.State.int random 5))
    |> interleave random
    |> List.mapi ~f:(fun i (etf, id, step) -> etf, id, step, ts_of_int i)
  ;;
end

let%expect_test "folding full and compacted logs gives equal state" =
  let rows = ref 0 in
  let compacted_rows = ref 0 in
  let invalid = ref 0 in
  let phases = Hashtbl.create (module String) in
  for seed = 0 to 1999 do
    let book, log, compacted, n = check_log (Stream.create seed) in
    rows := !rows + List.length log;
    compacted_rows := !compacted_rows + List.length compacted;
    invalid := !invalid + n;
    List.iter (Rebalance.Book.to_list book) ~f:(fun r ->
      Hashtbl.incr phases (Rebalance.Phase.to_string r.phase))
  done;
  printf
    "2000 streams: %d rows, %d after compaction, %d invalid steps\n"
    !rows
    !compacted_rows
    !invalid;
  Hashtbl.to_alist phases
  |> List.sort ~compare:[%compare: string * int]
  |> List.iter ~f:(fun (phase, n) -> printf "%-9s %d\n" phase n);
  [%expect
    {|
    2000 streams: 17921 rows, 13863 after compaction, 23241 invalid steps
    announced 201
    applied   121
    applying  511
    rejected  773
    settled   1568
    validated 197 |}]
;;

let%expect_test "synthetic stream: no invalid steps, and compaction keeps the state" =
  let config =
    { Synthetic.Config.default with
      events = 100_000
    ; symbols = 200
    ; etfs = 10
    ; basket_size = 20
    ; rebalance_ratio = 0.002
    ; rebalance_step_ratio = 0.05
    }
  in
  let events = Queue.create () in
  ignore
    (Synthetic.generate config ~f:(function
       | Rebalance { etf; id; step; ts } -> Queue.enqueue events (etf, id, step, ts)
       | Price _ | Etf_price _ | Composition _ -> ())
     : Synthetic.Summary.t);
  let book, log, compacted, invalid = check_log (Queue.to_list events) in
  let count phase =
    List.count (Rebalance.Book.to_list book) ~f:(fun r ->
      Rebalance.Phase.equal r.phase phase)
  in
  printf
    "%d steps, %d invalid; %d settled, %d rejected, %d active; %d rows, %d after \
     compaction\n"
    (Queue.length events)
    invalid
    (count Settled)
    (count Rejected)
    (List.length (Rebalance.Book.to_list book) - count Settled - count Rejected)
    (List.length log)
    (List.length compacted);
  [%expect
    {| 3936 steps, 0 invalid; 156 settled, 18 rejected, 0 active; 3936 rows, 816 after compaction |}]
;;
