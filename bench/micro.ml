open! Core
open Core_bench
open Nav_domain
open Nav_graph

(* Each market has [etfs] ETFs of [basket] holdings over [etfs * basket / overlap]
   symbols. ETF [e] holds a window of consecutive symbols starting at [e * basket /
   overlap], so every symbol is held by exactly [overlap] ETFs. *)

let etfs = 16
let ts = Time_ns.epoch
let symbol i = sprintf "S%06d" i
let etf e = sprintf "E%03d" e

module Market = struct
  type t =
    { basket : int
    ; overlap : int
    ; symbols : int
    }

  let create ~basket ~overlap = { basket; overlap; symbols = etfs * basket / overlap }

  let composition t ~etf:e ~version ~shift =
    let stride = t.basket / t.overlap in
    let holdings =
      Array.init t.basket ~f:(fun j ->
        { Holding.symbol = symbol (((e * stride) + j + shift) % t.symbols)
        ; units = 1. +. Float.of_int j
        })
    in
    Composition.create ~etf:(etf e) ~version ~holdings ~cash:100. ~shares_outstanding:1e6
    |> ok_exn
  ;;

  let events t =
    List.init etfs ~f:(fun e ->
      Event.Composition { composition = composition t ~etf:e ~version:1 ~shift:0; ts })
    @ List.init t.symbols ~f:(fun i ->
      Event.Price { symbol = symbol i; price = 10. +. Float.of_int (i % 97); ts })
  ;;

  (* The [i]th tick moves symbol [i mod symbols] to a price it did not have before. *)
  let tick t i =
    Event.Price
      { symbol = symbol (i % t.symbols); price = 10. +. Float.of_int (i % 89); ts }
  ;;
end

module type Model = sig
  type t

  val name : string
  val create : Event.t list -> t

  (** Applies [events] and returns the NAVs of the ETFs they affected. *)
  val step : t -> Event.t list -> float option list
end

module Full : Model = struct
  type t = Full_recompute.t

  let name = "full"
  let create = Full_recompute.of_events

  let step t events =
    let affected = String.Hash_set.create () in
    List.iter events ~f:(fun event ->
      List.iter (Full_recompute.apply t event) ~f:(Hash_set.add affected));
    Hash_set.to_list affected |> List.map ~f:(fun etf -> Full_recompute.nav t ~etf)
  ;;
end

module Incr : Model = struct
  type t = Incremental_nav.t

  let name = "incremental"

  let apply t events =
    List.iter events ~f:(fun event ->
      ignore (Incremental_nav.apply t ~offset:0 event : Rebalance.Outcome.t option))
  ;;

  let create events =
    let t = Incremental_nav.create () in
    apply t events;
    Incremental_nav.stabilize t;
    ignore (Incremental_nav.take_affected t : Incremental_nav.Affected.t list);
    t
  ;;

  let step t events =
    apply t events;
    Incremental_nav.stabilize t;
    Incremental_nav.take_affected t
    |> List.map ~f:(fun { Incremental_nav.Affected.etf; _ } -> Incremental_nav.nav t ~etf)
  ;;
end

let models : (module Model) list = [ (module Full); (module Incr) ]

let test ~name (module M : Model) market ~next =
  Bench.Test.create_with_initialization ~name:(sprintf "%s %s" name M.name) (fun `init ->
    let t = M.create (Market.events market) in
    let i = ref 0 in
    fun () ->
      incr i;
      M.step t (next !i))
;;

let label (m : Market.t) = sprintf "basket:%d overlap:%d" m.basket m.overlap
let baskets = [ 8; 32; 128; 512 ]
let overlaps = [ 1; 4; 16 ]

(* One price tick, then the NAVs of the ETFs holding it. *)
let ticks =
  List.concat_map baskets ~f:(fun basket ->
    List.filter_map overlaps ~f:(fun overlap ->
      Option.some_if (overlap <= basket) (Market.create ~basket ~overlap)))
  |> List.concat_map ~f:(fun market ->
    List.map models ~f:(fun model ->
      test
        ~name:(sprintf "tick %s" (label market))
        model
        market
        ~next:(fun i -> [ Market.tick market i ])))
;;

(* A new composition for one ETF, a tenth of its holdings moved, then its NAV. The
   incremental graph builds a new subgraph for it. *)
let swaps =
  List.concat_map baskets ~f:(fun basket ->
    let market = Market.create ~basket ~overlap:1 in
    List.map models ~f:(fun model ->
      test
        ~name:(sprintf "swap %s" (label market))
        model
        market
        ~next:(fun i ->
          let shift = if i % 2 = 0 then 0 else Int.max 1 (basket / 10) in
          [ Event.Composition
              { composition = Market.composition market ~etf:0 ~version:(i + 1) ~shift
              ; ts
              }
          ])))
;;

(* Every symbol ticks once, then every NAV is read: no part of any tree is shared
   with the previous step. *)
let dense =
  List.concat_map baskets ~f:(fun basket ->
    let market = Market.create ~basket ~overlap:4 in
    List.map models ~f:(fun model ->
      test
        ~name:(sprintf "all ticks %s" (label market))
        model
        market
        ~next:(fun i ->
          List.init market.symbols ~f:(fun s ->
            Market.tick market ((i * market.symbols) + s)))))
;;

let () = Command_unix.run (Bench.make_command (ticks @ swaps @ dense))
