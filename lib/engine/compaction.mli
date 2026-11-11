open! Core
open Nav_store

module Report : sig
  type t =
    { rebalances : int (** rebalances whose rows were rewritten *)
    ; rows_before : int
    ; rows_after : int
    ; bytes_before : int
    ; bytes_after : int
    }
  [@@deriving sexp]
end

(** Rewrites the log of every settled or rejected rebalance with {!Rebalance.compact}, in
    one transaction. Safe while an engine is writing: no step is accepted for a terminal
    rebalance, so no writer adds rows to the ones it rewrites. Concurrent compactions
    wait for each other. *)
val run : Store.t -> Report.t
