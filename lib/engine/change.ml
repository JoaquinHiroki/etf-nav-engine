open! Core
open Nav_domain
open Nav_graph
open Nav_source
open Nav_store

module Nav_update = struct
  (** An ETF's NAV and premium after the last event that affected it, with that event's
      offset and timestamp. [nav] is [None] while some holding has no price. *)
  type t =
    { etf : string
    ; nav : float option
    ; premium : float option
    ; source_offset : int
    ; ts : Timestamp.t
    }
  [@@deriving compare, sexp]

  let to_snapshot { etf; nav; premium; source_offset; ts } =
    { Store.Snapshot.etf; nav; premium; source_offset; ts }
  ;;
end

type t =
  { offset : int
  ; event : Event.t
  ; navs : Nav_update.t list
  }
[@@deriving compare, sexp]

let compute state (record : Source.record) =
  let ts = Event.ts record.event in
  let navs =
    List.map (Full_recompute.apply state record.event) ~f:(fun etf ->
      { Nav_update.etf
      ; nav = Full_recompute.nav state ~etf
      ; premium = Full_recompute.premium state ~etf
      ; source_offset = record.offset
      ; ts
      })
  in
  { offset = record.offset; event = record.event; navs }
;;
