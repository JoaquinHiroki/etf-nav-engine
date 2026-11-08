open! Core
open Nav_domain
open Nav_engine
open Nav_graph
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

let%expect_test "each change carries the navs of the etfs the event affects" =
  let events =
    [| composition "A" [ "X", 1.; "Y", 1. ]
     ; composition "B" [ "Y", 2. ]
     ; price "X" 10.
     ; price "Y" 20.
     ; price "Z" 30.
     ; Event.Etf_price { etf = "B"; price = 41.; ts }
     ; price "X" 11.
    |]
  in
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
      (Full_recompute.create ())
  in
  print_s [%message (report.events : int) (report.nav_updates : int)];
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
