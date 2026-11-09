open! Core
open Nav_data
open Nav_domain
open Nav_graph

let ts = Time_ns.epoch
let bits = Option.map ~f:Int64.bits_of_float

(* Compares every value bit for bit. Floats are printed too, since bits alone are hard
   to read in a failure. *)
let check ~etfs ~full ~incr =
  [%test_result: string list]
    (Incremental_nav.etfs incr)
    ~expect:(Full_recompute.etfs full);
  List.iter etfs ~f:(fun etf ->
    let compare what ~incremental ~full =
      if not ([%equal: Int64.t option] (bits incremental) (bits full))
      then
        raise_s
          [%message
            "incremental differs from full recompute"
              (etf : string)
              (what : string)
              (incremental : float option)
              (full : float option)]
    in
    compare
      "nav"
      ~incremental:(Incremental_nav.nav incr ~etf)
      ~full:(Full_recompute.nav full ~etf);
    compare
      "premium"
      ~incremental:(Incremental_nav.premium incr ~etf)
      ~full:(Full_recompute.premium full ~etf);
    compare
      "etf_price"
      ~incremental:(Incremental_nav.etf_price incr ~etf)
      ~full:(Full_recompute.etf_price full ~etf))
;;

(* Applies [events] one at a time to both implementations, stabilizing and comparing
   after each. Returns the full recompute's affected ETFs per event, for counting. *)
let run_both ~etfs events ~f =
  let full = Full_recompute.create () in
  let incr = Incremental_nav.create () in
  List.iter events ~f:(fun event ->
    let affected = Full_recompute.apply full event in
    Incremental_nav.apply incr event;
    Incremental_nav.stabilize incr;
    check ~etfs:(etfs full) ~full ~incr;
    f full affected);
  incr
;;

module Gen = struct
  open Quickcheck.Generator.Let_syntax

  let symbols = [ "A"; "B"; "C"; "D"; "E" ]
  let etfs = [ "X"; "Y"; "Z" ]

  (* Repeated values exercise the cutoffs, values like 0.1, 0.2, 0.3 make association
     visible, and the rest are edge cases both implementations must agree on. *)
  let value =
    Quickcheck.Generator.weighted_union
      [ 6., Quickcheck.Generator.of_list [ 0.1; 0.2; 0.3; 1.; 3.; 10.; 1e16 ]
      ; 3., Float.gen_finite
      ; ( 1.
        , Quickcheck.Generator.of_list
            [ 0.; -0.; -1.; 5e-324; Float.nan; Float.infinity; Float.neg_infinity ] )
      ]
  ;;

  let composition =
    let%bind etf = Quickcheck.Generator.of_list etfs
    and version = Int.gen_incl 0 4
    and symbols = List.gen_filtered symbols
    and cash = value
    and shares_outstanding = Quickcheck.Generator.of_list [ 1.; 3.; 0.7; 1e-3; 1e9 ] in
    let%map units = List.gen_with_length (List.length symbols) value in
    let holdings =
      List.map2_exn symbols units ~f:(fun symbol units -> { Holding.symbol; units })
    in
    Composition.create
      ~etf
      ~version
      ~holdings:(Array.of_list holdings)
      ~cash
      ~shares_outstanding
    |> ok_exn
  ;;

  let event =
    Quickcheck.Generator.weighted_union
      [ ( 6.
        , let%map symbol = Quickcheck.Generator.of_list symbols
          and price = value in
          Event.Price { symbol; price; ts } )
      ; ( 2.
        , let%map etf = Quickcheck.Generator.of_list etfs
          and price = value in
          Event.Etf_price { etf; price; ts } )
      ; ( 2.
        , let%map composition = composition in
          Event.Composition { composition; ts } )
      ; ( 0.5
        , let%map etf = Quickcheck.Generator.of_list etfs in
          Event.Rebalance { etf; id = 1; step = Rebalance_step.Validate; ts } )
      ]
  ;;

  let events =
    let%bind length = Int.gen_incl 0 60 in
    List.gen_with_length length event
  ;;
end

let%test_unit "incremental equals full recompute bit for bit after every event" =
  Quickcheck.test
    Gen.events
    ~sexp_of:[%sexp_of: Event.t list]
    ~shrinker:(List.quickcheck_shrinker Event.quickcheck_shrinker)
    ~f:(fun events ->
      ignore
        (run_both ~etfs:(Fn.const Gen.etfs) events ~f:(fun _ _ -> ()) : Incremental_nav.t))
;;

let%expect_test "synthetic stream: equal after every event, with far fewer recomputes" =
  let config =
    { Synthetic.Config.default with
      events = 30_000
    ; symbols = 120
    ; etfs = 8
    ; basket_size = 32
    ; composition_ratio = 0.005
    ; rebalance_ratio = 0.002
    ; rebalance_step_ratio = 0.05
    }
  in
  let events = Queue.create () in
  ignore (Synthetic.generate config ~f:(Queue.enqueue events) : Synthetic.Summary.t);
  (* [Full_recompute] sums every holding of each affected ETF with a composition. The
     generator gives every composition [basket_size] holdings. *)
  let full_positions = ref 0 in
  let full_sums = ref 0 in
  let incr =
    run_both ~etfs:Full_recompute.etfs (Queue.to_list events) ~f:(fun full affected ->
      let with_composition = Full_recompute.etfs full in
      List.iter affected ~f:(fun etf ->
        if List.mem with_composition etf ~equal:String.equal
        then (
          full_positions := !full_positions + config.basket_size;
          full_sums := !full_sums + config.basket_size - 1)))
  in
  let r = Incremental_nav.recomputes incr in
  printf
    "positions: full %d, incremental %d\nsums: full %d, incremental %d\n"
    !full_positions
    r.positions
    !full_sums
    r.sums;
  [%expect
    {|
    positions: full 1926912, incremental 63711
    sums: full 1866696, incremental 300614 |}]
;;

let%expect_test "a tick recomputes one path through the tree" =
  let incr = Incremental_nav.create () in
  let composition ?(version = 1) etf symbols =
    let holdings =
      Array.of_list_map symbols ~f:(fun symbol -> { Holding.symbol; units = 1. })
    in
    let composition =
      Composition.create ~etf ~version ~holdings ~cash:0. ~shares_outstanding:1. |> ok_exn
    in
    Event.Composition { composition; ts }
  in
  let price symbol price = Event.Price { symbol; price; ts } in
  let step label events =
    List.iter events ~f:(Incremental_nav.apply incr);
    Incremental_nav.stabilize incr;
    let r = Incremental_nav.recomputes incr in
    printf
      "%s: positions %d, sums %d, navs %d, premiums %d, subgraphs %d\n"
      label
      r.positions
      r.sums
      r.navs
      r.premiums
      r.subgraphs;
    Incremental_nav.reset_recomputes incr
  in
  let a_symbols = List.init 8 ~f:(sprintf "S%d") in
  step
    "setup"
    ([ composition "A" a_symbols; composition "B" [ "S7"; "T" ] ]
     @ List.map a_symbols ~f:(fun s -> price s 10.)
     @ [ price "T" 20.; Event.Etf_price { etf = "A"; price = 81.; ts } ]);
  step "tick S0" [ price "S0" 11. ];
  step "same price again" [ price "S0" 11. ];
  step "tick S7, held by both" [ price "S7" 12. ];
  step "etf price" [ Event.Etf_price { etf = "A"; price = 82.; ts } ];
  step "swap A to 3 holdings" [ composition ~version:2 "A" [ "S0"; "S1"; "S2" ] ];
  step "tick S7, now only B" [ price "S7" 13. ];
  step "tick S5, held by none" [ price "S5" 14. ];
  step "stale composition" [ composition ~version:1 "A" a_symbols ];
  [%expect
    {|
    setup: positions 10, sums 8, navs 2, premiums 2, subgraphs 2
    tick S0: positions 1, sums 3, navs 1, premiums 1, subgraphs 0
    same price again: positions 0, sums 0, navs 0, premiums 0, subgraphs 0
    tick S7, held by both: positions 2, sums 4, navs 2, premiums 2, subgraphs 0
    etf price: positions 0, sums 0, navs 0, premiums 1, subgraphs 0
    swap A to 3 holdings: positions 3, sums 2, navs 1, premiums 1, subgraphs 1
    tick S7, now only B: positions 1, sums 1, navs 1, premiums 1, subgraphs 0
    tick S5, held by none: positions 0, sums 0, navs 0, premiums 0, subgraphs 0
    stale composition: positions 0, sums 0, navs 0, premiums 0, subgraphs 0 |}]
;;

let%test_unit "reading before stabilize raises" =
  let incr = Incremental_nav.create () in
  Incremental_nav.apply incr (Event.Price { symbol = "A"; price = 1.; ts });
  [%test_pred: float option Or_error.t]
    Result.is_error
    (Or_error.try_with (fun () -> Incremental_nav.nav incr ~etf:"X"))
;;
