open! Core
open Nav_domain

(** An 8-byte magic header followed by records: a 4-byte big-endian length and a
    bin_prot encoded [Event.t]. *)

val with_writer : string -> f:((Event.t -> unit) -> 'a) -> 'a
val fold : ?limit:int -> string -> init:'acc -> f:('acc -> Event.t -> 'acc) -> 'acc
val iter : ?limit:int -> string -> f:(Event.t -> unit) -> unit
val read_all : ?limit:int -> string -> Event.t array
