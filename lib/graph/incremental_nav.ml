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

module Affected = struct
  type t =
    { etf : string
    ; offset : int
    ; ts : Timestamp.t
    }
  [@@deriving compare, sexp]
end

(* One per ETF, reused across batches so marking a holder allocates nothing. It is in
   the current batch when [epoch] is the state's. *)
type mark =
  { etf : string
  ; mutable epoch : int
  ; mutable offset : int
  ; mutable ts : Timestamp.t
  }

type 'w price =
  { var : (float, 'w) Var.t
  ; mutable holders : mark list
  }

type 'w state =
  { incr : 'w Incremental.State.t
  ; prices : (string, 'w price) Hashtbl.t
  ; etf_prices : (string, (float option, 'w) Var.t) Hashtbl.t
  ; etfs : (string, 'w etf) Hashtbl.t
  ; marks : (string, mark) Hashtbl.t
  ; counters : counters
  ; changed : String.Hash_set.t
  ; mutable epoch : int
  ; mutable marked : mark list
  ; mutable rebalances : Rebalance.Book.t
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
    ; marks = Hashtbl.create (module String)
    ; counters = { positions = 0; sums = 0; navs = 0; premiums = 0; subgraphs = 0 }
    ; changed = String.Hash_set.create ()
    ; epoch = 0
    ; marked = []
    ; rebalances = Rebalance.Book.empty
    ; stale = false
    }
;;

(* A missing price is NaN, as in [Full_recompute]. *)
let price s symbol =
  match Hashtbl.find s.prices symbol with
  | Some price -> price
  | None ->
    let var = Var.create s.incr Float.nan in
    ignore (with_cutoff float_cutoff (Var.watch var) : (_, _) Incremental.t);
    let price = { var; holders = [] } in
    Hashtbl.add_exn s.prices ~key:symbol ~data:price;
    price
;;

let mark_of s etf =
  match Hashtbl.find s.marks etf with
  | Some mark -> mark
  | None ->
    let mark = { etf; epoch = -1; offset = 0; ts = Time_ns.epoch } in
    Hashtbl.add_exn s.marks ~key:etf ~data:mark;
    mark
;;

let mark s (m : mark) ~offset ~ts =
  if m.epoch <> s.epoch
  then (
    m.epoch <- s.epoch;
    s.marked <- m :: s.marked);
  m.offset <- offset;
  m.ts <- ts
;;

let rec mark_all s marks ~offset ~ts =
  match marks with
  | [] -> ()
  | m :: rest ->
    mark s m ~offset ~ts;
    mark_all s rest ~offset ~ts
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
      Incremental.map (Var.watch (Hashtbl.find_exn s.prices symbol).var) ~f:(fun price ->
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

(* Same bookkeeping as [Full_recompute.set_composition], so both report the same
   affected ETFs. *)
let set_holders s ~old (composition : Composition.t) =
  let m = mark_of s composition.etf in
  Option.iter old ~f:(fun (old : Composition.t) ->
    Array.iter old.holdings ~f:(fun h ->
      let price = price s h.symbol in
      price.holders <- List.filter price.holders ~f:(fun held -> not (phys_equal held m))));
  Array.iter composition.holdings ~f:(fun h ->
    let price = price s h.symbol in
    if not (List.mem price.holders m ~equal:phys_equal)
    then price.holders <- m :: price.holders)
;;

(* Returns whether the composition was applied. *)
let set_composition s (composition : Composition.t) =
  (* Variables are created here, outside stabilization, so the bind only looks them up. *)
  Array.iter composition.holdings ~f:(fun h -> ignore (price s h.symbol : _ price));
  match Hashtbl.find s.etfs composition.etf with
  | None ->
    set_holders s ~old:None composition;
    add_etf s composition;
    true
  | Some etf ->
    let current = Var.value etf.composition in
    if composition.version > current.version
    then (
      set_holders s ~old:(Some current) composition;
      Var.set etf.composition composition;
      true)
    else false
;;

let apply (T s) ~offset (event : Event.t) =
  s.stale <- true;
  match event with
  | Price { symbol; price = value; ts } ->
    let price = price s symbol in
    Var.set price.var value;
    mark_all s price.holders ~offset ~ts;
    None
  | Etf_price { etf; price; ts } ->
    Var.set (etf_price_var s etf) (Some price);
    mark s (mark_of s etf) ~offset ~ts;
    None
  | Composition { composition; ts } ->
    if set_composition s composition then mark s (mark_of s composition.etf) ~offset ~ts;
    None
  | Rebalance { etf; id; step; ts } ->
    let book, outcome = Rebalance.step s.rebalances ~etf ~id step ~ts in
    s.rebalances <- book;
    (match outcome with
     | Accepted { applied = Some target; _ } ->
       if set_composition s target then mark s (mark_of s target.etf) ~offset ~ts
     | Accepted { applied = None; _ } | Invalid _ -> ());
    Some outcome
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

let take_affected (T s) =
  let marked = s.marked in
  s.marked <- [];
  s.epoch <- s.epoch + 1;
  List.map marked ~f:(fun { etf; offset; ts; epoch = _ } -> { Affected.etf; offset; ts })
  |> List.sort ~compare:(fun (a : Affected.t) b -> String.compare a.etf b.etf)
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
let rebalances (T s) = s.rebalances

let recomputes (T s) =
  let { positions; sums; navs; premiums; subgraphs } = s.counters in
  { Recomputes.positions; sums; navs; premiums; subgraphs }
;;

let reset_recomputes (T s) = reset_counters s.counters
