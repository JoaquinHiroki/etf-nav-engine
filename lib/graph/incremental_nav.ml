open! Core
open Nav_domain
module Var = Incremental.Var
module Observer = Incremental.Observer

module Recomputes = struct
  type t =
    { positions : int
    ; sums : int
    ; navs : int
    ; premiums : int
    ; subgraphs : int
    }
  [@@deriving compare, sexp]
end

type counters =
  { mutable positions : int
  ; mutable sums : int
  ; mutable navs : int
  ; mutable premiums : int
  ; mutable subgraphs : int
  }

let reset_counters c =
  c.positions <- 0;
  c.sums <- 0;
  c.navs <- 0;
  c.premiums <- 0;
  c.subgraphs <- 0
;;

type 'w etf =
  { composition : (Composition.t, 'w) Var.t
  ; nav : (float, 'w) Observer.t
  ; premium : (float option, 'w) Observer.t
  }

type 'w state =
  { incr : 'w Incremental.State.t
  ; prices : (string, (float, 'w) Var.t) Hashtbl.t
  ; etf_prices : (string, (float option, 'w) Var.t) Hashtbl.t
  ; etfs : (string, 'w etf) Hashtbl.t
  ; counters : counters
  ; changed : String.Hash_set.t
  ; mutable stale : bool
  }

type t = T : 'w state -> t

(* Equal bits give equal results downstream, so cutting off on them cannot change any
   NAV. [Float.equal] would not do: it equates 0. with -0. and never equates NaNs. *)
let same_bits a b = Int64.equal (Int64.bits_of_float a) (Int64.bits_of_float b)
let float_cutoff = Incremental.Cutoff.of_equal same_bits
let float_option_cutoff = Incremental.Cutoff.of_equal (Option.equal same_bits)

let with_cutoff cutoff node =
  Incremental.set_cutoff node cutoff;
  node
;;

let create () =
  let module S = (val Incremental.State.create ()) in
  T
    { incr = S.t
    ; prices = Hashtbl.create (module String)
    ; etf_prices = Hashtbl.create (module String)
    ; etfs = Hashtbl.create (module String)
    ; counters = { positions = 0; sums = 0; navs = 0; premiums = 0; subgraphs = 0 }
    ; changed = String.Hash_set.create ()
    ; stale = false
    }
;;

(* A missing price is NaN, as in [Full_recompute]. *)
let price_var s symbol =
  Hashtbl.find_or_add s.prices symbol ~default:(fun () ->
    let var = Var.create s.incr Float.nan in
    ignore (with_cutoff float_cutoff (Var.watch var) : (_, _) Incremental.t);
    var)
;;

let etf_price_var s etf =
  Hashtbl.find_or_add s.etf_prices etf ~default:(fun () ->
    let var = Var.create s.incr None in
    ignore (with_cutoff float_option_cutoff (Var.watch var) : (_, _) Incremental.t);
    var)
;;

let positions_value s (composition : Composition.t) =
  let counters = s.counters in
  let leaves =
    Array.map composition.holdings ~f:(fun { Holding.symbol; units } ->
      Incremental.map
        (Var.watch (Hashtbl.find_exn s.prices symbol))
        ~f:(fun price ->
          counters.positions <- counters.positions + 1;
          units *. price)
      |> with_cutoff float_cutoff)
  in
  Balanced.reduce leaves ~empty:(Incremental.const s.incr 0.) ~combine:(fun left right ->
    Incremental.map2 left right ~f:(fun left right ->
      counters.sums <- counters.sums + 1;
      left +. right)
    |> with_cutoff float_cutoff)
;;

let nav_node s composition_var =
  let counters = s.counters in
  Incremental.bind (Var.watch composition_var) ~f:(fun (composition : Composition.t) ->
    counters.subgraphs <- counters.subgraphs + 1;
    let { Composition.cash; shares_outstanding; _ } = composition in
    Incremental.map (positions_value s composition) ~f:(fun positions_value ->
      counters.navs <- counters.navs + 1;
      Nav.nav ~cash ~positions_value ~shares_outstanding)
    |> with_cutoff float_cutoff)
  |> with_cutoff float_cutoff
;;

let premium_node s nav etf_price_var =
  let counters = s.counters in
  Incremental.map2 nav (Var.watch etf_price_var) ~f:(fun nav etf_price ->
    counters.premiums <- counters.premiums + 1;
    if Float.is_nan nav
    then None
    else Option.map etf_price ~f:(fun etf_price -> Nav.premium ~etf_price ~nav))
  |> with_cutoff float_option_cutoff
;;

let add_etf s (composition : Composition.t) =
  let composition_var = Var.create s.incr composition in
  let nav = nav_node s composition_var in
  let premium = premium_node s nav (etf_price_var s composition.etf) in
  let observe node =
    let observer = Incremental.observe ~should_finalize:false node in
    (* Runs once after any stabilization in which the node's value changed. *)
    Observer.on_update_exn observer ~f:(fun (_ : _ Observer.Update.t) ->
      Hash_set.add s.changed composition.etf);
    observer
  in
  Hashtbl.add_exn
    s.etfs
    ~key:composition.etf
    ~data:{ composition = composition_var; nav = observe nav; premium = observe premium }
;;

let set_composition s (composition : Composition.t) =
  (* Variables are created here, outside stabilization, so the bind only looks them up. *)
  Array.iter composition.holdings ~f:(fun h ->
    ignore (price_var s h.symbol : (_, _) Var.t));
  match Hashtbl.find s.etfs composition.etf with
  | None -> add_etf s composition
  | Some etf ->
    if composition.version > (Var.value etf.composition).version
    then Var.set etf.composition composition
;;

let apply (T s) (event : Event.t) =
  s.stale <- true;
  match event with
  | Price { symbol; price; ts = _ } -> Var.set (price_var s symbol) price
  | Etf_price { etf; price; ts = _ } -> Var.set (etf_price_var s etf) (Some price)
  | Composition { composition; ts = _ } -> set_composition s composition
  | Rebalance _ -> ()
;;

let stabilize (T s) =
  Incremental.stabilize s.incr;
  s.stale <- false
;;

let etfs (T s) = Hashtbl.keys s.etfs |> List.sort ~compare:String.compare

let take_changed (T s) =
  let changed = Hash_set.to_list s.changed |> List.sort ~compare:String.compare in
  Hash_set.clear s.changed;
  changed
;;

let observed s ~etf ~f =
  if s.stale
  then raise_s [%message "Incremental_nav: stabilize before reading" (etf : string)];
  Option.map (Hashtbl.find s.etfs etf) ~f:(fun etf -> Observer.value_exn (f etf))
;;

let nav (T s) ~etf =
  Option.bind
    (observed s ~etf ~f:(fun e -> e.nav))
    ~f:(fun nav -> Option.some_if (not (Float.is_nan nav)) nav)
;;

let premium (T s) ~etf = Option.join (observed s ~etf ~f:(fun e -> e.premium))
let etf_price (T s) ~etf = Option.bind (Hashtbl.find s.etf_prices etf) ~f:Var.value

let recomputes (T s) =
  let { positions; sums; navs; premiums; subgraphs } = s.counters in
  { Recomputes.positions; sums; navs; premiums; subgraphs }
;;

let reset_recomputes (T s) = reset_counters s.counters
