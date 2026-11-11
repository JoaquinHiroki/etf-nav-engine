open! Core

module Phase = struct
  type t =
    | Announced
    | Validated
    | Rejected
    | Applying
    | Applied
    | Settled
  [@@deriving compare, enumerate, equal, sexp]

  let is_terminal = function
    | Rejected | Settled -> true
    | Announced | Validated | Applying | Applied -> false
  ;;

  let to_string t = String.lowercase (Sexp.to_string (sexp_of_t t))
  let of_string s = t_of_sexp (Sexp.Atom (String.capitalize s))
end

module Kind = struct
  type t =
    | Announce
    | Validate
    | Reject
    | Begin_applying
    | Progress
    | Apply
    | Settle
  [@@deriving compare, enumerate, equal, sexp]

  let of_step : Rebalance_step.t -> t = function
    | Announce _ -> Announce
    | Validate -> Validate
    | Reject _ -> Reject
    | Begin_applying -> Begin_applying
    | Progress _ -> Progress
    | Apply -> Apply
    | Settle -> Settle
  ;;
end

let transitions : (Phase.t option * Kind.t * Phase.t) list =
  [ None, Announce, Announced
  ; Some Announced, Validate, Validated
  ; Some Announced, Reject, Rejected
  ; Some Validated, Reject, Rejected
  ; Some Validated, Begin_applying, Applying
  ; Some Applying, Progress, Applying
  ; Some Applying, Apply, Applied
  ; Some Applied, Settle, Settled
  ]
;;

let next from kind =
  List.find_map transitions ~f:(fun (from', kind', after) ->
    Option.some_if ([%equal: Phase.t option] from from' && Kind.equal kind kind') after)
;;

type t =
  { etf : string
  ; id : int
  ; target : Composition.t
  ; phase : Phase.t
  ; filled : String.Set.t
  ; reason : string option
  ; announced : Timestamp.t
  ; updated : Timestamp.t
  ; steps : int
  }
[@@deriving compare, sexp]

module Key = struct
  module T = struct
    type t = string * int [@@deriving compare, sexp]
  end

  include T
  include Comparator.Make (T)
end

module Book = struct
  type rebalance = t [@@deriving compare, sexp]

  type t =
    { rebalances : rebalance Map.M(Key).t
    ; active : int Map.M(String).t
    }
  [@@deriving compare, sexp]

  let empty = { rebalances = Map.empty (module Key); active = String.Map.empty }
  let find t ~etf ~id = Map.find t.rebalances (etf, id)
  let active t ~etf = Option.bind (Map.find t.active etf) ~f:(fun id -> find t ~etf ~id)
  let to_list t = Map.data t.rebalances

  let set t (r : rebalance) =
    { rebalances = Map.set t.rebalances ~key:(r.etf, r.id) ~data:r
    ; active =
        (if Phase.is_terminal r.phase
         then Map.remove t.active r.etf
         else Map.set t.active ~key:r.etf ~data:r.id)
    }
  ;;
end

module Outcome = struct
  type t =
    | Invalid of Sexp.t
    | Accepted of
        { phase : Phase.t
        ; applied : Composition.t option
        }
  [@@deriving compare, sexp]
end

let in_target (r : t) symbol =
  Array.exists r.target.holdings ~f:(fun h -> String.equal h.symbol symbol)
;;

let advance book ~etf ~id (step : Rebalance_step.t) ~ts =
  let current = Book.find book ~etf ~id in
  let kind = Kind.of_step step in
  let from = Option.map current ~f:(fun r -> r.phase) in
  match next from kind with
  | None -> Error [%message "no transition" (from : Phase.t option) (kind : Kind.t)]
  | Some phase ->
    let moved (r : t) = { r with phase; updated = ts; steps = r.steps + 1 } in
    (match current, step with
     | None, Announce target ->
       if not (String.equal target.etf etf)
       then Error [%message "target is for another ETF" ~target:(target.etf : string)]
       else (
         match Book.active book ~etf with
         | Some active ->
           Error [%message "ETF has an active rebalance" ~id:(active.id : int)]
         | None ->
           Ok
             { etf
             ; id
             ; target
             ; phase
             ; filled = String.Set.empty
             ; reason = None
             ; announced = ts
             ; updated = ts
             ; steps = 1
             })
     | Some r, Progress holding ->
       if not (in_target r holding.symbol)
       then Error [%message "not a target holding" ~symbol:(holding.symbol : string)]
       else if Set.mem r.filled holding.symbol
       then Error [%message "already filled" ~symbol:(holding.symbol : string)]
       else Ok { (moved r) with filled = Set.add r.filled holding.symbol }
     | Some r, Apply ->
       let unfilled =
         Array.count r.target.holdings ~f:(fun h -> not (Set.mem r.filled h.symbol))
       in
       if unfilled > 0
       then Error [%message "target holdings not filled" (unfilled : int)]
       else Ok (moved r)
     | Some r, Reject reason -> Ok { (moved r) with reason = Some reason }
     | Some r, (Validate | Begin_applying | Settle) -> Ok (moved r)
     | None, (Validate | Reject _ | Begin_applying | Progress _ | Apply | Settle)
     | Some _, Announce _ ->
       raise_s
         [%message
           "transition table allows an unexpected step"
             (from : Phase.t option)
             (kind : Kind.t)])
;;

let step book ~etf ~id step ~ts : Book.t * Outcome.t =
  match advance book ~etf ~id step ~ts with
  | Error reason -> book, Invalid reason
  | Ok r ->
    let applied =
      match step with
      | Apply -> Some r.target
      | Announce _ | Validate | Reject _ | Begin_applying | Progress _ | Settle -> None
    in
    Book.set book r, Accepted { phase = r.phase; applied }
;;

module Transition = struct
  type t =
    { etf : string
    ; id : int
    ; seq : int
    ; phase : Phase.t
    ; steps : Rebalance_step.t list
    ; first_ts : Timestamp.t
    ; last_ts : Timestamp.t
    }
  [@@deriving compare, sexp]

  let create ~seq ~etf ~id ~phase step ~ts =
    { etf; id; seq; phase; steps = [ step ]; first_ts = ts; last_ts = ts }
  ;;

  let merged_count t = List.length t.steps
  let by_seq a b = Int.compare a.seq b.seq
  let by_key a b = [%compare: string * int * int] (a.etf, a.id, a.seq) (b.etf, b.id, b.seq)
end

let events transitions =
  List.stable_sort transitions ~compare:Transition.by_seq
  |> List.concat_map ~f:(fun (t : Transition.t) ->
    List.map t.steps ~f:(fun step ->
      Event.Rebalance { etf = t.etf; id = t.id; step; ts = t.last_ts }))
;;

let fold transitions =
  List.fold (events transitions) ~init:Book.empty ~f:(fun book event ->
    match event with
    | Rebalance { etf; id; step = s; ts } ->
      (match step book ~etf ~id s ~ts with
       | book, Accepted _ -> book
       | _, Invalid reason ->
         raise_s
           [%message "rejected step in rebalance log" etf (id : int) (reason : Sexp.t)])
    | Price _ | Etf_price _ | Composition _ -> book)
;;

let merge_runs (rows : Transition.t list) =
  List.group rows ~break:(fun (a : Transition.t) b -> not (Phase.equal a.phase b.phase))
  |> List.map ~f:(fun run ->
    let first = List.hd_exn run in
    let last = List.last_exn run in
    { first with
      steps = List.concat_map run ~f:(fun (t : Transition.t) -> t.steps)
    ; last_ts = last.last_ts
    })
;;

let compact transitions =
  List.sort transitions ~compare:Transition.by_key
  |> List.group ~break:(fun (a : Transition.t) b ->
    not ([%equal: string * int] (a.etf, a.id) (b.etf, b.id)))
  |> List.concat_map ~f:(fun rows ->
    if List.exists rows ~f:(fun (t : Transition.t) -> Phase.is_terminal t.phase)
    then merge_runs rows
    else rows)
;;
