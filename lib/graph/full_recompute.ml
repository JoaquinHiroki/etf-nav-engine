open! Core
open Nav_domain

type t =
  { prices : (string, float) Hashtbl.t
  ; etf_prices : (string, float) Hashtbl.t
  ; compositions : (string, Composition.t) Hashtbl.t
  ; holders : (string, String.Set.t) Hashtbl.t
  ; mutable rebalances : Rebalance.Book.t
  }

let create () =
  { prices = Hashtbl.create (module String)
  ; etf_prices = Hashtbl.create (module String)
  ; compositions = Hashtbl.create (module String)
  ; holders = Hashtbl.create (module String)
  ; rebalances = Rebalance.Book.empty
  }
;;

let set_composition t (composition : Composition.t) =
  Option.iter (Hashtbl.find t.compositions composition.etf) ~f:(fun old ->
    Array.iter old.holdings ~f:(fun h ->
      Hashtbl.change t.holders h.symbol ~f:(Option.map ~f:(Fn.flip Set.remove old.etf))));
  Array.iter composition.holdings ~f:(fun h ->
    Hashtbl.update t.holders h.symbol ~f:(function
      | None -> String.Set.singleton composition.etf
      | Some holders -> Set.add holders composition.etf));
  Hashtbl.set t.compositions ~key:composition.etf ~data:composition
;;

let is_newer t (composition : Composition.t) =
  match Hashtbl.find t.compositions composition.etf with
  | None -> true
  | Some current -> composition.version > current.version
;;

let set_if_newer t (composition : Composition.t) =
  if is_newer t composition
  then (
    set_composition t composition;
    [ composition.etf ])
  else []
;;

let apply ?(rebalance = ignore) t (event : Event.t) =
  match event with
  | Price { symbol; price; ts = _ } ->
    Hashtbl.set t.prices ~key:symbol ~data:price;
    Option.value_map (Hashtbl.find t.holders symbol) ~default:[] ~f:Set.to_list
  | Etf_price { etf; price; ts = _ } ->
    Hashtbl.set t.etf_prices ~key:etf ~data:price;
    [ etf ]
  | Composition { composition; ts = _ } -> set_if_newer t composition
  | Rebalance { etf; id; step; ts } ->
    let book, outcome = Rebalance.step t.rebalances ~etf ~id step ~ts in
    t.rebalances <- book;
    rebalance outcome;
    (match outcome with
     | Accepted { applied = Some target; _ } -> set_if_newer t target
     | Accepted { applied = None; _ } | Invalid _ -> [])
;;

let of_events events =
  let t = create () in
  List.iter events ~f:(fun event -> ignore (apply t event : string list));
  t
;;

let etfs t = Hashtbl.keys t.compositions |> List.sort ~compare:String.compare

let position_value t (holding : Holding.t) =
  match Hashtbl.find t.prices holding.symbol with
  | Some price -> holding.units *. price
  | None -> Float.nan
;;

let nav t ~etf =
  let%bind.Option (c : Composition.t) = Hashtbl.find t.compositions etf in
  let positions_value = Balanced.sum (Array.map c.holdings ~f:(position_value t)) in
  let nav =
    Nav.nav ~cash:c.cash ~positions_value ~shares_outstanding:c.shares_outstanding
  in
  Option.some_if (not (Float.is_nan nav)) nav
;;

let etf_price t ~etf = Hashtbl.find t.etf_prices etf
let rebalances t = t.rebalances

let premium_of t ~etf nav =
  let%bind.Option nav = nav in
  let%map.Option etf_price = etf_price t ~etf in
  Nav.premium ~etf_price ~nav
;;

let premium t ~etf = premium_of t ~etf (nav t ~etf)

let nav_and_premium t ~etf =
  let nav = nav t ~etf in
  nav, premium_of t ~etf nav
;;
