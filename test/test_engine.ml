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

(* Prints each change's offset and its updates as (etf nav premium source_offset). *)
let print_changes model =
  let writer =
    { Writer.name = "print"
    ; write =
        List.iter ~f:(fun (change : Change.t) ->
          let navs =
            List.map change.navs ~f:(fun (u : Change.Nav_update.t) ->
              u.etf, u.nav, u.premium, u.source_offset)
          in
          print_s
            [%sexp
              (change.offset : int)
              , (navs : (string * float option * float option * int) list)])
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

let%expect_test "full: each change carries the etfs its event affects" =
  print_changes (Model.full ());
  [%expect
    {|
    (0 ((A () () 0)))
    (1 ((B () () 1)))
    (2 ((A () () 2)))
    (3 ((A (30) () 3) (B (40) () 3)))
    (4 ())
    (5 ((B (40) (0.025) 5)))
    (6 ((A (31) () 6)))
    ((report.events 7) (report.nav_updates 7)) |}]
;;

let%expect_test "incremental: a batch's last change carries every etf it affected" =
  print_changes (Model.incremental ());
  [%expect
    {|
    (0 ())
    (1 ())
    (2 ((A () () 2) (B () () 1)))
    (3 ())
    (4 ())
    (5 ((A (30) () 3) (B (40) (0.025) 5)))
    (6 ((A (31) () 6)))
    ((report.events 7) (report.nav_updates 5)) |}]
;;

let synthetic_events () =
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
  Queue.to_array events
;;

let%expect_test "checked: no mismatches at any batch size" =
  let events = synthetic_events () in
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
      "batch %4d: mismatches %d, affected mismatches %d, etf checks %d, nav updates %d, \
       positions %d, sums %d\n"
      batch_size
      oracle.mismatches
      oracle.affected_mismatches
      oracle.etf_checks
      report.nav_updates
      recomputes.positions
      recomputes.sums;
    List.iter oracle.first_mismatches ~f:(fun m -> print_s [%sexp (m : Model.Mismatch.t)]));
  [%expect
    {|
    batch    1: mismatches 0, affected mismatches 0, etf checks 142667, nav updates 142667, positions 148188, sums 623310
    batch  100: mismatches 0, affected mismatches 0, etf checks 29744, nav updates 29744, positions 131288, sums 319842
    batch 1000: mismatches 0, affected mismatches 0, etf checks 3000, nav updates 3000, positions 54957, sums 56816 |}]
;;

let%expect_test "every model gives the writers the same rebalance log at any batch size" =
  let events = synthetic_events () in
  let log (model : Model.t) ~batch_size =
    let transitions = Queue.create () in
    let applied = Queue.create () in
    let writer =
      { Writer.name = "log"
      ; write =
          List.iter ~f:(fun change ->
            Option.iter (Change.transition change) ~f:(Queue.enqueue transitions);
            Option.iter (Change.applied change) ~f:(fun (c, _) ->
              Queue.enqueue applied (c.etf, c.version)))
      }
    in
    let report =
      Engine.run
        ~idle_timeout:Time_ns.Span.zero
        ~batch_size
        ~start_offset:0
        ~source:(Source.in_memory events)
        ~writer
        ~model
        ()
    in
    ( Queue.to_list transitions
    , Queue.to_list applied
    , report.rebalance_transitions
    , report.invalid_rebalance_steps )
  in
  let ((transitions, applied, accepted, invalid) as expect) =
    log (Model.full ()) ~batch_size:1
  in
  List.iter
    [ "incremental", Model.incremental; "checked", Model.checked ]
    ~f:(fun (name, model) ->
      List.iter [ 1; 100; 1000 ] ~f:(fun batch_size ->
        [%test_result: Rebalance.Transition.t list * (string * int) list * int * int]
          ~message:(sprintf "%s, batch %d" name batch_size)
          (log (model ()) ~batch_size)
          ~expect));
  printf
    "%d transitions, %d accepted, %d invalid, %d targets applied\n"
    (List.length transitions)
    accepted
    invalid
    (List.length applied);
  [%expect {| 4225 transitions, 4225 accepted, 0 invalid, 167 targets applied |}]
;;
