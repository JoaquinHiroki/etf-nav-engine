open! Core
open Nav_domain
open Nav_source

let events =
  Array.init 5 ~f:(fun i ->
    Event.Price
      { symbol = "AAPL"
      ; price = Float.of_int (100 + i)
      ; ts = Time_ns.of_int_ns_since_epoch i
      })
;;

let print_offsets records =
  List.map records ~f:(fun (r : Source.record) -> r.offset)
  |> [%sexp_of: int list]
  |> print_s
;;

let%expect_test "poll returns batches in order, then nothing" =
  let source = Source.in_memory events in
  print_offsets (source.poll ~max:2);
  print_offsets (source.poll ~max:2);
  print_offsets (source.poll ~max:2);
  print_offsets (source.poll ~max:2);
  [%expect {|
    (0 1)
    (2 3)
    (4)
    () |}]
;;

let%expect_test "seek replays from an offset" =
  let source = Source.in_memory events in
  ignore (source.poll ~max:5 : Source.record list);
  source.seek 3;
  print_offsets (source.poll ~max:10);
  source.seek 99;
  print_offsets (source.poll ~max:10);
  [%expect {|
    (3 4)
    () |}]
;;
