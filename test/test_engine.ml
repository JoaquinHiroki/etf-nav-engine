open! Core
open Nav_data
open Nav_domain
open Nav_engine
open Nav_source

let ts = Time_ns.epoch

let composition etf holdings =
  let holdings =
    Array.of_list_map holdings ~f:(fun (symbol, units) -> { Holding.symbol; units })
  in
  let composition =
    Composition.create ~etf ~version:1 ~holdings ~cash:0. ~shares_outstanding:1. |> ok_exn
  in
  Event.Composition { composition; ts }
;;

let price symbol price = Event.Price { symbol; price; ts }

let events =
  [| composition "A" [ "X", 1.; "Y", 1. ]
   ; composition "B" [ "Y", 2. ]
   ; price "X" 10.
   ; price "Y" 20.
   ; price "Z" 30.
   ; Event.Etf_price { etf = "B"; price = 41.; ts }
   ; price "X" 11.
  |]
;;

let print_changes model =
  let writer =
    { Writer.name = "print"
    ; write =
        List.iter ~f:(fun (change : Change.t) ->
          print_s [%sexp (change.offset : int), (change.navs : Change.Nav_update.t list)])
    }
  in
  let report =
    Engine.run
      ~idle_timeout:Time_ns.Span.zero
      ~batch_size:3
      ~start_offset:0
      ~source:(Source.in_memory events)
      ~writer
      ~model
      ()
  in
  print_s [%message (report.events : int) (report.nav_updates : int)]
;;

let%expect_test "full: each change carries the navs of the etfs the event affects" =
  print_changes (Model.full ());
  [%expect
    {|
    (0 ())
    (1 ())
    (2 ())
    (3 (((etf A) (nav 30) (premium ())) ((etf B) (nav 40) (premium ()))))
    (4 ())
    (5 (((etf B) (nav 40) (premium (0.025)))))
    (6 (((etf A) (nav 31) (premium ()))))
    ((report.events 7) (report.nav_updates 4)) |}]
;;

let%expect_test "incremental: the last change of each batch carries the etfs that changed"
  =
  print_changes (Model.incremental ());
  [%expect
    {|
    (0 ())
    (1 ())
    (2 ())
    (3 ())
    (4 ())
    (5 (((etf A) (nav 30) (premium ())) ((etf B) (nav 40) (premium (0.025)))))
    (6 (((etf A) (nav 31) (premium ()))))
    ((report.events 7) (report.nav_updates 3)) |}]
;;

let%expect_test "checked: no mismatches at any batch size" =
  let config =
    { Synthetic.Config.default with
      events = 100_000
    ; symbols = 400
    ; etfs = 30
    ; basket_size = 20
    ; composition_ratio = 0.002
    ; rebalance_ratio = 0.002
    ; rebalance_step_ratio = 0.05
    }
  in
  let events = Queue.create () in
  ignore (Synthetic.generate config ~f:(Queue.enqueue events) : Synthetic.Summary.t);
  let events = Queue.to_array events in
  List.iter [ 1; 100; 1000 ] ~f:(fun batch_size ->
    let report =
      Engine.run
        ~idle_timeout:Time_ns.Span.zero
        ~batch_size
        ~start_offset:0
        ~source:(Source.in_memory events)
        ~writer:Writer.none
        ~model:(Model.checked ())
        ()
    in
    let oracle = Option.value_exn report.model_stats.oracle in
    let recomputes = Option.value_exn report.model_stats.recomputes in
    printf
      "batch %4d: mismatches %d, etf checks %d, nav updates %d, positions %d, sums %d\n"
      batch_size
      oracle.mismatches
      oracle.etf_checks
      report.nav_updates
      recomputes.positions
      recomputes.sums;
    List.iter oracle.first_mismatches ~f:(fun m -> print_s [%sexp (m : Model.Mismatch.t)]));
  [%expect
    {|
    batch    1: mismatches 0, etf checks 142197, nav updates 141597, positions 144545, sums 618695
    batch  100: mismatches 0, etf checks 29737, nav updates 29625, positions 128388, sums 317981
    batch 1000: mismatches 0, etf checks 3000, nav updates 3000, positions 54578, sums 56788 |}]
;;
