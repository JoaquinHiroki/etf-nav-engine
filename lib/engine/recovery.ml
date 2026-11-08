open! Core
open Nav_domain
open Nav_graph
open Nav_store

let restore store state ~topic =
  let apply event = ignore (Full_recompute.apply state event : string list) in
  List.iter (Store.latest_compositions store) ~f:(fun (composition, ts) ->
    apply (Event.Composition { composition; ts }));
  List.iter (Store.prices store Holding_prices) ~f:(fun { symbol; price; ts; _ } ->
    apply (Event.Price { symbol; price; ts }));
  List.iter (Store.prices store Etf_prices) ~f:(fun { symbol; price; ts; _ } ->
    apply (Event.Etf_price { etf = symbol; price; ts }));
  Store.next_offset store ~topic |> Option.value ~default:0
;;
