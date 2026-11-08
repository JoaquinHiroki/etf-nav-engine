open! Core
open Nav_data
open Nav_domain

let with_temp_file f =
  let path = Filename_unix.temp_file "events" ".bin" in
  Exn.protect ~f:(fun () -> f path) ~finally:(fun () -> Core_unix.unlink path)
;;

let%test_unit "events read back exactly as written" =
  with_temp_file (fun path ->
    Quickcheck.test
      (List.quickcheck_generator Event.quickcheck_generator)
      ~sexp_of:[%sexp_of: Event.t list]
      ~trials:50
      ~f:(fun events ->
        Event_file.with_writer path ~f:(fun write -> List.iter events ~f:write);
        [%test_result: Event.t array]
          (Event_file.read_all path)
          ~expect:(Array.of_list events)))
;;

let%expect_test "limit stops early and other files are rejected" =
  with_temp_file (fun path ->
    let price i =
      Event.Price { symbol = "AAA"; price = Float.of_int i; ts = Time_ns.epoch }
    in
    Event_file.with_writer path ~f:(fun write ->
      List.iter (List.init 10 ~f:price) ~f:write);
    print_s [%sexp (Array.length (Event_file.read_all ~limit:3 path) : int)];
    Out_channel.write_all path ~data:"not events";
    print_s
      [%sexp
        (Or_error.try_with (fun () -> Event_file.read_all path) |> Or_error.is_error
         : bool)]);
  [%expect {|
    3
    true |}]
;;
