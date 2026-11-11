open! Core
open Nav_domain
open Nav_store

let is_newer version ~than = Option.for_all than ~f:(fun stored -> version > stored)

let confirm ~what ~expected stored =
  if not ([%equal: int option] stored (Some expected))
  then raise_s [%message "readback mismatch" what (expected : int) (stored : int option)]
;;

let write_versioned ~what ~version ~read ~write =
  if is_newer version ~than:(read ())
  then (
    write ();
    confirm ~what ~expected:version (read ()))
;;

let write_price store table ~symbol ~price ~offset ~ts =
  write_versioned
    ~what:symbol
    ~version:offset
    ~read:(fun () -> Store.price_offset store table ~symbol)
    ~write:(fun () ->
      Store.upsert_price store table { symbol; price; source_offset = offset; ts })
;;

let write_event store ~offset (event : Event.t) =
  match event with
  | Price { symbol; price; ts } ->
    write_price store Holding_prices ~symbol ~price ~offset ~ts
  | Etf_price { etf; price; ts } ->
    write_price store Etf_prices ~symbol:etf ~price ~offset ~ts
  | Composition { composition; ts } ->
    write_versioned
      ~what:composition.etf
      ~version:composition.version
      ~read:(fun () -> Store.composition_version store ~etf:composition.etf)
      ~write:(fun () -> Store.insert_composition store composition ~effective_ts:ts)
  | Rebalance _ -> ()
;;

let write_snapshot store (update : Change.Nav_update.t) =
  write_versioned
    ~what:update.etf
    ~version:update.source_offset
    ~read:(fun () -> Store.snapshot_offset store ~etf:update.etf)
    ~write:(fun () -> Store.upsert_snapshot store (Change.Nav_update.to_snapshot update))
;;

let write_change store ~topic (change : Change.t) =
  Store.transaction store ~f:(fun () ->
    write_event store ~offset:change.offset change.event;
    List.iter change.navs ~f:(write_snapshot store);
    write_versioned
      ~what:topic
      ~version:(change.offset + 1)
      ~read:(fun () -> Store.next_offset store ~topic)
      ~write:(fun () -> Store.set_next_offset store ~topic (change.offset + 1)))
;;

let create store ~topic =
  { Writer.name = "baseline"; write = List.iter ~f:(write_change store ~topic) }
;;
