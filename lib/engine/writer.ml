open! Core

type t =
  { name : string
  ; write : Change.t list -> unit
  }

let none = { name = "none"; write = ignore }
