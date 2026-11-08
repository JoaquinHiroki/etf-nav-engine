open! Core
open Nav_graph

let%expect_test "tree shape depends only on length" =
  List.iter [ 0; 1; 2; 3; 4; 5; 8 ] ~f:(fun n ->
    Array.init n ~f:(fun i -> Char.to_string (Char.of_int_exn (Char.to_int 'a' + i)))
    |> Balanced.reduce ~empty:"0" ~combine:(sprintf "(%s+%s)")
    |> print_endline);
  [%expect
    {|
    0
    a
    (a+b)
    (a+(b+c))
    ((a+b)+(c+d))
    ((a+b)+(c+(d+e)))
    (((a+b)+(c+d))+((e+f)+(g+h))) |}]
;;

let%expect_test "association changes floating-point results" =
  printf "%.17g\n%.17g\n" (0.1 +. 0.2 +. 0.3) (0.1 +. (0.2 +. 0.3));
  [%expect {|
    0.60000000000000009
    0.59999999999999998 |}]
;;

let%test_unit "sums of small integers are exact" =
  Quickcheck.test
    (List.gen_with_length 50 (Int.gen_incl (-1_000) 1_000))
    ~sexp_of:[%sexp_of: int list]
    ~f:(fun ints ->
      [%test_result: float]
        (Balanced.sum (Array.of_list_map ints ~f:Float.of_int))
        ~expect:(Float.of_int (List.sum (module Int) ints ~f:Fn.id)))
;;
