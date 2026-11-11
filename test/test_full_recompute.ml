open! Core
open Nav_domain
open Nav_graph

let ts = Time_ns.epoch
let price symbol price = Event.Price { symbol; price; ts }
let etf_price etf price = Event.Etf_price { etf; price; ts }

let composition ?(version = 1) ?(cash = 100.) holdings =
  let holdings =
    Array.of_list_map holdings ~f:(fun (symbol, units) -> { Holding.symbol; units })
  in
  let composition =
    Composition.create ~etf:"ETF" ~version ~holdings ~cash ~shares_outstanding:10.
    |> ok_exn
  in
  Event.Composition { composition; ts }
;;

let show events =
  let state = Full_recompute.of_events events in
  print_s
    [%message
      ""
        ~nav:(Full_recompute.nav state ~etf:"ETF" : float option)
        ~premium:(Full_recompute.premium state ~etf:"ETF" : float option)]
;;

let%expect_test "nav needs a composition and every price" =
  show [ price "AAA" 10. ];
  show [ composition [ "AAA", 2.; "BBB", 3. ]; price "AAA" 10. ];
  show [ composition [ "AAA", 2.; "BBB", 3. ]; price "AAA" 10.; price "BBB" 20. ];
  [%expect
    {|
    ((nav ()) (premium ()))
    ((nav ()) (premium ()))
    ((nav (18)) (premium ())) |}]
;;

let%expect_test "an empty basket is worth its cash" =
  show [ composition ~cash:250. [] ];
  [%expect {| ((nav (25)) (premium ())) |}]
;;

let%expect_test "premium compares the etf price with nav" =
  let events = [ composition [ "AAA", 9. ]; price "AAA" 10.; etf_price "ETF" 19.38 ] in
  show events;
  [%expect {| ((nav (19)) (premium (0.019999999999999948))) |}]
;;

let%expect_test "after a swap, old holdings no longer affect nav" =
  let before =
    [ composition [ "AAA", 1.; "BBB", 1. ]; price "AAA" 10.; price "BBB" 20. ]
  in
  let swapped = before @ [ composition ~version:2 [ "BBB", 2. ] ] in
  show swapped;
  show (swapped @ [ price "AAA" 1_000. ]);
  [%expect {|
    ((nav (14)) (premium ()))
    ((nav (14)) (premium ())) |}]
;;

let%expect_test "stale or repeated compositions are ignored" =
  let events =
    [ composition ~version:2 [ "AAA", 1. ]
    ; composition ~version:1 [ "AAA", 5. ]
    ; composition ~version:2 [ "AAA", 7. ]
    ; price "AAA" 10.
    ]
  in
  show events;
  [%expect {| ((nav (11)) (premium ())) |}]
;;

let%expect_test "an applied rebalance makes its target the live composition" =
  let target =
    Composition.create
      ~etf:"ETF"
      ~version:2
      ~holdings:[| { symbol = "BBB"; units = 2. } |]
      ~cash:100.
      ~shares_outstanding:10.
    |> ok_exn
  in
  let rebalance step = Event.Rebalance { etf = "ETF"; id = 7; step; ts } in
  let before =
    [ composition [ "AAA", 1.; "BBB", 1. ]
    ; price "AAA" 10.
    ; price "BBB" 20.
    ; rebalance (Announce target)
    ; rebalance Validate
    ; rebalance Begin_applying
    ; rebalance (Progress { symbol = "BBB"; units = 2. })
    ]
  in
  show before;
  let state = Full_recompute.of_events before in
  let affected = Full_recompute.apply state (rebalance Apply) in
  print_s [%sexp (affected : string list)];
  show (before @ [ rebalance Apply ]);
  show (before @ [ rebalance Apply; composition ~version:2 [ "AAA", 5. ] ]);
  [%expect
    {|
    ((nav (13)) (premium ()))
    (ETF)
    ((nav (14)) (premium ()))
    ((nav (14)) (premium ())) |}]
;;
