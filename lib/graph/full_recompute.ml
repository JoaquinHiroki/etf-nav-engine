open! Core
open Nav_domain

type t =
  { prices : float String.Map.t
  ; etf_prices : float String.Map.t
  ; compositions : Composition.t String.Map.t
  }

let empty =
  { prices = String.Map.empty
  ; etf_prices = String.Map.empty
  ; compositions = String.Map.empty
  }
;;

let is_newer (composition : Composition.t) ~than:(current : Composition.t option) =
  match current with
  | None -> true
  | Some current -> composition.version > current.version
;;

let apply t (event : Event.t) =
  match event with
  | Price { symbol; price; ts = _ } ->
    { t with prices = Map.set t.prices ~key:symbol ~data:price }
  | Etf_price { etf; price; ts = _ } ->
    { t with etf_prices = Map.set t.etf_prices ~key:etf ~data:price }
  | Composition { composition; ts = _ } ->
    if is_newer composition ~than:(Map.find t.compositions composition.etf)
    then
      { t with
        compositions = Map.set t.compositions ~key:composition.etf ~data:composition
      }
    else t
  | Rebalance _ -> t
;;

let of_events events = List.fold events ~init:empty ~f:apply
let etfs t = Map.keys t.compositions

let position_value t (holding : Holding.t) =
  match Map.find t.prices holding.symbol with
  | Some price -> holding.units *. price
  | None -> Float.nan
;;

let nav t ~etf =
  let%bind.Option (c : Composition.t) = Map.find t.compositions etf in
  let positions_value = Balanced.sum (Array.map c.holdings ~f:(position_value t)) in
  let nav =
    Nav.nav ~cash:c.cash ~positions_value ~shares_outstanding:c.shares_outstanding
  in
  Option.some_if (not (Float.is_nan nav)) nav
;;

let premium t ~etf =
  let%bind.Option nav = nav t ~etf in
  let%map.Option etf_price = Map.find t.etf_prices etf in
  Nav.premium ~etf_price ~nav
;;
