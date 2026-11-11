open! Core
open Nav_config
open Nav_engine
open Nav_store

let command =
  Command.basic
    ~summary:"Compact the log of settled and rejected rebalances"
    (let%map_open.Command () = return () in
     fun () ->
       let store = Store.connect (Config.postgres ()) in
       let report = Compaction.run store in
       Store.close store;
       print_s [%sexp (report : Compaction.Report.t)])
;;

let () = Command_unix.run command
