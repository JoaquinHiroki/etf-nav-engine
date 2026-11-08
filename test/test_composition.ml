open! Core
open Nav_domain

let holding symbol units = { Holding.symbol; units }

let show ~holdings ~shares_outstanding =
  Composition.create ~etf:"SPY" ~version:1 ~holdings ~cash:100. ~shares_outstanding
  |> [%sexp_of: Composition.t Or_error.t]
  |> print_s
;;

let%expect_test "holdings are sorted by symbol" =
  show
    ~holdings:[| holding "MSFT" 2.; holding "AAPL" 3.; holding "NVDA" 1. |]
    ~shares_outstanding:10.;
  [%expect
    {|
    (Ok
     ((etf SPY) (version 1)
      (holdings
       (((symbol AAPL) (units 3)) ((symbol MSFT) (units 2))
        ((symbol NVDA) (units 1))))
      (cash 100) (shares_outstanding 10))) |}]
;;

let%expect_test "duplicate symbols are rejected" =
  show ~holdings:[| holding "AAPL" 1.; holding "AAPL" 2. |] ~shares_outstanding:10.;
  [%expect {| (Error ("duplicate holding" (etf SPY) (symbol AAPL))) |}]
;;

let%expect_test "shares outstanding must be positive" =
  show ~holdings:[||] ~shares_outstanding:0.;
  show ~holdings:[||] ~shares_outstanding:Float.nan;
  [%expect
    {|
    (Error
     ("shares_outstanding must be positive" (etf SPY) (shares_outstanding 0)))
    (Error
     ("shares_outstanding must be positive" (etf SPY) (shares_outstanding NAN))) |}]
;;

let%expect_test "nav and premium" =
  let nav = Nav.nav ~cash:100. ~positions_value:900. ~shares_outstanding:10. in
  let premium = Nav.premium ~etf_price:101. ~nav in
  print_s [%message (nav : float) (premium : float)];
  [%expect {| ((nav 100) (premium 0.01)) |}]
;;
