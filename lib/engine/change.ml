open! Core
open Nav_domain
open Nav_graph
open Nav_source

module Nav_update = struct
  type t =
    { etf : string
    ; nav : float
    ; premium : float option
    }
  [@@deriving compare, sexp]
end

type t =
  { offset : int
  ; event : Event.t
  ; navs : Nav_update.t list
  }
[@@deriving compare, sexp]

let compute state (record : Source.record) =
  let affected = Full_recompute.apply state record.event in
  let navs =
    List.filter_map affected ~f:(fun etf ->
      let%map.Option nav = Full_recompute.nav state ~etf in
      let premium =
        Option.map (Full_recompute.etf_price state ~etf) ~f:(fun etf_price ->
          Nav.premium ~etf_price ~nav)
      in
      { Nav_update.etf; nav; premium })
  in
  { offset = record.offset; event = record.event; navs }
;;
