open! Core
open Nav_source

(** Reads partition 0 of [topic]. Polling before any [seek] starts at offset 0.
    [poll] waits up to [poll_timeout_ms] to fill a batch. *)
val create : ?poll_timeout_ms:int -> brokers:string -> topic:string -> unit -> Source.t
