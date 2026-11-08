open! Core
open Nav_domain

type record =
  { offset : int
  ; event : Event.t
  }
[@@deriving compare, sexp_of]

type t =
  { seek : int -> unit
  ; poll : max:int -> record list
  }

let in_memory events =
  let next = ref 0 in
  let seek offset = next := offset in
  let poll ~max =
    let first = !next in
    let count = Int.max 0 (Int.min (Array.length events) (first + max) - first) in
    next := first + count;
    List.init count ~f:(fun i -> { offset = first + i; event = events.(first + i) })
  in
  { seek; poll }
;;
