open! Core
open Nav_data

let command =
  Command.basic
    ~summary:"Write a seeded synthetic event file"
    (let%map_open.Command output = flag "output" (required string) ~doc:"FILE event file"
     and seed = flag "seed" (optional int) ~doc:"N random seed"
     and events = flag "events" (optional int) ~doc:"N total events"
     and symbols = flag "symbols" (optional int) ~doc:"N symbol universe size"
     and etfs = flag "etfs" (optional int) ~doc:"N number of ETFs"
     and basket_size = flag "basket" (optional int) ~doc:"N holdings per ETF" in
     fun () ->
       let default = Synthetic.Config.default in
       let config =
         { default with
           seed = Option.value seed ~default:default.seed
         ; events = Option.value events ~default:default.events
         ; symbols = Option.value symbols ~default:default.symbols
         ; etfs = Option.value etfs ~default:default.etfs
         ; basket_size = Option.value basket_size ~default:default.basket_size
         }
       in
       let summary =
         Event_file.with_writer output ~f:(fun write ->
           Synthetic.generate config ~f:write)
       in
       let report =
         [%sexp { config : Synthetic.Config.t; summary : Synthetic.Summary.t }]
       in
       Out_channel.write_all
         (output ^ ".settings")
         ~data:(Sexp.to_string_hum report ^ "\n");
       print_s report)
;;

let () = Command_unix.run command
