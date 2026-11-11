open! Core
open Nav_store

let write store ~topic (changes : Change.t list) =
  Option.iter (List.last changes) ~f:(fun (last : Change.t) ->
    let prices = Hashtbl.create (module String) in
    let etf_prices = Hashtbl.create (module String) in
    let snapshots = Hashtbl.create (module String) in
    let compositions = Queue.create () in
    List.iter changes ~f:(fun { offset; event; navs } ->
      (match event with
       | Price { symbol; price; ts } ->
         Hashtbl.set
           prices
           ~key:symbol
           ~data:{ Store.Price.symbol; price; source_offset = offset; ts }
       | Etf_price { etf; price; ts } ->
         Hashtbl.set
           etf_prices
           ~key:etf
           ~data:{ Store.Price.symbol = etf; price; source_offset = offset; ts }
       | Composition { composition; ts } -> Queue.enqueue compositions (composition, ts)
       | Rebalance _ -> ());
      List.iter navs ~f:(fun (update : Change.Nav_update.t) ->
        Hashtbl.set snapshots ~key:update.etf ~data:(Change.Nav_update.to_snapshot update)));
    Store.transaction store ~f:(fun () ->
      Queue.iter compositions ~f:(fun (composition, ts) ->
        Store.insert_composition_if_newer store composition ~effective_ts:ts);
      Store.upsert_prices store Holding_prices (Hashtbl.data prices);
      Store.upsert_prices store Etf_prices (Hashtbl.data etf_prices);
      Store.upsert_snapshots store (Hashtbl.data snapshots);
      Store.set_next_offset store ~topic (last.offset + 1)))
;;

let create store ~topic = { Writer.name = "optimized"; write = write store ~topic }
