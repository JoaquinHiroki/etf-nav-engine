open! Core
open Nav_domain
open Nav_store

let load store ~topic =
  let compositions =
    List.map (Store.latest_compositions store) ~f:(fun (composition, ts) ->
      Event.Composition { composition; ts })
  in
  let prices =
    List.map (Store.prices store Holding_prices) ~f:(fun { symbol; price; ts; _ } ->
      Event.Price { symbol; price; ts })
  in
  let etf_prices =
    List.map (Store.prices store Etf_prices) ~f:(fun { symbol; price; ts; _ } ->
      Event.Etf_price { etf = symbol; price; ts })
  in
  ( List.concat
      [ compositions; prices; etf_prices; Rebalance.events (Store.transitions store) ]
  , Store.next_offset store ~topic |> Option.value ~default:0 )
;;
