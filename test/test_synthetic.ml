open! Core
open Nav_data
open Nav_domain
open Nav_graph

let config =
  { Synthetic.Config.default with
    events = 20_000
  ; symbols = 60
  ; etfs = 4
  ; basket_size = 10
  ; rebalance_ratio = 0.002
  ; rebalance_step_ratio = 0.05
  ; composition_ratio = 0.001
  }
;;

let generate config =
  let events = Queue.create () in
  let summary = Synthetic.generate config ~f:(Queue.enqueue events) in
  summary, Queue.to_list events
;;

let%expect_test "summary of a small run" =
  let summary, _ = generate config in
  print_s [%sexp (summary : Synthetic.Summary.t)];
  [%expect
    {|
    ((events 20000) (prices 19137) (etf_prices 416) (compositions 23)
     (rebalance_steps 424) (rebalances 30) (rejected_rebalances 2)
     (symbols_held 34) (mean_holders_per_symbol 1.1764705882352942)
     (max_holders_per_symbol 2)) |}]
;;

let%test_unit "the same config produces the same events" =
  [%test_result: Event.t list] (snd (generate config)) ~expect:(snd (generate config))
;;

let%expect_test "every etf has a nav near 101 after setup" =
  let setup = (2 * config.etfs) + config.symbols in
  let state = Full_recompute.of_events (List.take (snd (generate config)) setup) in
  List.iter (Full_recompute.etfs state) ~f:(fun etf ->
    let nav = Full_recompute.nav state ~etf |> Option.value_exn in
    let premium = Full_recompute.premium state ~etf |> Option.value_exn in
    printf "%s nav %.2f premium %+.4f\n" etf nav premium);
  [%expect
    {|
    E0000 nav 101.00 premium -0.0004
    E0001 nav 101.00 premium +0.0008
    E0002 nav 101.00 premium -0.0002
    E0003 nav 101.00 premium +0.0012 |}]
;;

let step_name : Rebalance_step.t -> string = function
  | Announce _ -> "announce"
  | Validate -> "validate"
  | Reject _ -> "reject"
  | Begin_applying -> "begin"
  | Progress _ -> "progress"
  | Apply -> "apply"
  | Settle -> "settle"
;;

let%expect_test "rebalances follow the state machine" =
  let steps = Hashtbl.create (module Int) in
  List.iter
    (snd (generate config))
    ~f:(function
      | Rebalance { id; step; _ } ->
        Hashtbl.add_multi steps ~key:id ~data:(step_name step)
      | Price _ | Etf_price _ | Composition _ -> ());
  let shape steps =
    let collapsed =
      List.rev steps
      |> List.remove_consecutive_duplicates ~equal:String.equal
      |> String.concat ~sep:" "
    in
    if String.is_prefix "announce validate begin progress apply settle" ~prefix:collapsed
       || String.equal collapsed "announce reject"
    then collapsed
    else raise_s [%message "invalid rebalance" collapsed]
  in
  Hashtbl.data steps
  |> List.map ~f:shape
  |> List.sort_and_group ~compare:String.compare
  |> List.iter ~f:(fun group -> printf "%3d %s\n" (List.length group) (List.hd_exn group));
  [%expect
    {|
     2 announce reject
    28 announce validate begin progress apply settle |}]
;;
