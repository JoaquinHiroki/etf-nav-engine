open! Core
open Nav_domain

let%test_unit "every event survives a bin_prot round trip" =
  Quickcheck.test Event.quickcheck_generator ~sexp_of:Event.sexp_of_t ~f:(fun event ->
    [%test_result: Event.t] (Event.of_string (Event.to_string event)) ~expect:event)
;;

let%expect_test "a price tick is small on the wire" =
  let event = Event.Price { symbol = "BTCUSDT"; price = 68_000.5; ts = Time_ns.epoch } in
  print_s [%sexp (event : Event.t)];
  printf "%d bytes\n" (String.length (Event.to_string event));
  [%expect
    {|
    (Price (symbol BTCUSDT) (price 68000.5) (ts "1970-01-01 00:00:00Z"))
    18 bytes |}]
;;
