open! Core
open Nav_store

(** One transaction per batch, with no reads. The batch is reduced in memory to the
    latest price per symbol and the latest snapshot per ETF, each written by one
    multi-row upsert, together with new compositions, applied rebalance targets, the
    batch's rebalance transitions and [next_offset]. Upserts only replace a row with a
    higher [source_offset]. *)
val create : Store.t -> topic:string -> Writer.t
