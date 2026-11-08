open! Core

(** Combines [xs] with a binary tree whose shape depends only on [Array.length xs]:
    each range is split at its midpoint. Floating-point addition is not associative, so
    the full recompute and the incremental graph both reduce through this function to
    produce bit-identical sums. *)
val reduce : 'a array -> empty:'a -> combine:('a -> 'a -> 'a) -> 'a

val sum : float array -> float
