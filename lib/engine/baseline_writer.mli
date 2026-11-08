open! Core
open Nav_store

(** The write path one would build first: one transaction per event, the stored version
    read before every write and compared in application code, and every write read back
    to confirm it. *)
val create : Store.t -> topic:string -> Writer.t
