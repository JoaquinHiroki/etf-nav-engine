open! Core
open Nav_domain

type t =
  { prices : (string, float) Hashtbl.t
  ; etf_prices : (string, float) Hashtbl.t
  ; compositions : (string, Composition.t) Hashtbl.t
  ; holders : (string, String.Hash_set.t) Hashtbl.t
  }

let create () =
  { prices = Hashtbl.create (module String)
  ; etf_prices = Hashtbl.create (module String)
  ; compositions = Hashtbl.create (module String)
  ; holders = Hashtbl.create (module String)
  }
;;

let holders_of t symbol =
  Hashtbl.find_or_add t.holders symbol ~default:String.Hash_set.create
;;

let set_composition t (composition : Composition.t) =
  Option.iter (Hashtbl.find t.compositions composition.etf) ~f:(fun old ->
    Array.iter old.holdings ~f:(fun h -> Hash_set.remove (holders_of t h.symbol) old.etf));
  Array.iter composition.holdings ~f:(fun h ->
    Hash_set.add (holders_of t h.symbol) composition.etf);
  Hashtbl.set t.compositions ~key:composition.etf ~data:composition
;;

let is_newer t (composition : Composition.t) =
  match Hashtbl.find t.compositions composition.etf with
  | None -> true
  | Some current -> composition.version > current.version
;;

let apply t (event : Event.t) =
  match event with
  | Price { symbol; price; ts = _ } ->
    Hashtbl.set t.prices ~key:symbol ~data:price;
    Option.value_map (Hashtbl.find t.holders symbol) ~default:[] ~f:(fun holders ->
      Hash_set.to_list holders |> List.sort ~compare:String.compare)
  | Etf_price { etf; price; ts = _ } ->
    Hashtbl.set t.etf_prices ~key:etf ~data:price;
    [ etf ]
  | Composition { composition; ts = _ } ->
    if is_newer t composition
    then (
      set_composition t composition;
      [ composition.etf ])
    else []
  | Rebalance _ -> []
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

let premium t ~etf =
  let%bind.Option nav = nav t ~etf in
  let%map.Option etf_price = etf_price t ~etf in
  Nav.premium ~etf_price ~nav
;;
