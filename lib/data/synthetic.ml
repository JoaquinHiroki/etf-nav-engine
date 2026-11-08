open! Core
open Nav_domain

module Config = struct
  type t =
    { seed : int
    ; events : int
    ; symbols : int
    ; etfs : int
    ; basket_size : int
    ; etf_price_ratio : float
    ; rebalance_ratio : float
    ; rebalance_step_ratio : float
    ; reject_ratio : float
    ; composition_ratio : float
    ; volatility : float
    ; tick_interval : Time_ns.Span.t
    }
  [@@deriving sexp]

  let default =
    { seed = 42
    ; events = 1_000_000
    ; symbols = 2_000
    ; etfs = 100
    ; basket_size = 50
    ; etf_price_ratio = 0.02
    ; rebalance_ratio = 0.000_1
    ; rebalance_step_ratio = 0.01
    ; reject_ratio = 0.1
    ; composition_ratio = 0.000_05
    ; volatility = 0.000_5
    ; tick_interval = Time_ns.Span.of_int_us 100
    }
  ;;

  let setup_events t = (2 * t.etfs) + t.symbols

  let validate t =
    if t.basket_size < 1 || t.basket_size >= t.symbols
    then raise_s [%message "basket_size must be in [1, symbols)" (t : t)];
    if t.events < setup_events t
    then raise_s [%message "events must cover the setup events" (setup_events t : int)]
  ;;
end

module Summary = struct
  type t =
    { events : int
    ; prices : int
    ; etf_prices : int
    ; compositions : int
    ; rebalance_steps : int
    ; rebalances : int
    ; rejected_rebalances : int
    ; symbols_held : int
    ; mean_holders_per_symbol : float
    ; max_holders_per_symbol : int
    }
  [@@deriving sexp]
end

type pending =
  { etf : int
  ; id : int
  ; step : Rebalance_step.t
  ; target : Composition.t
  }

type t =
  { config : Config.t
  ; rng : Random.State.t
  ; prices : float array
  ; compositions : Composition.t array
  ; rebalancing : bool array
  ; pending : pending Queue.t
  ; mutable next_rebalance_id : int
  }

let start = Time_ns.of_int_ns_since_epoch 1_767_225_600_000_000_000
let symbol_name i = sprintf "S%05d" i
let symbol_index name = Int.of_string (String.drop_prefix name 1)
let etf_name i = sprintf "E%04d" i
let random_int t bound = Random.State.int t.rng bound
let random_unit t = Random.State.float t.rng 1.

let gaussian t =
  let u1 = 1. -. random_unit t in
  let u2 = random_unit t in
  Float.sqrt (-2. *. Float.log u1) *. Float.cos (2. *. Float.pi *. u2)
;;

let composition_of t ~etf ~version ~symbols =
  let shares_outstanding = 1_000_000. in
  let notional = 100. *. shares_outstanding in
  let weights = Array.map symbols ~f:(fun _ -> 0.5 +. random_unit t) in
  let total_weight = Array.sum (module Float) weights ~f:Fn.id in
  let holdings =
    Array.map2_exn symbols weights ~f:(fun symbol weight ->
      { Holding.symbol = symbol_name symbol
      ; units = weight /. total_weight *. notional /. t.prices.(symbol)
      })
  in
  Composition.create
    ~etf:(etf_name etf)
    ~version
    ~holdings
    ~cash:(0.01 *. notional)
    ~shares_outstanding
  |> ok_exn
;;

let distinct_symbols t ~count ~excluding =
  let chosen = Hash_set.create (module Int) in
  while Hash_set.length chosen < count do
    let symbol = random_int t t.config.symbols in
    if not (Hash_set.mem excluding symbol) then Hash_set.add chosen symbol
  done;
  chosen
;;

let next_composition t etf =
  let current = t.compositions.(etf) in
  let held =
    Array.map current.holdings ~f:(fun h -> symbol_index h.symbol)
    |> Array.to_list
    |> Hash_set.of_list (module Int)
  in
  let replaced = Int.max 1 (Hash_set.length held / 10) in
  let dropped =
    List.take (List.permute ~random_state:t.rng (Hash_set.to_list held)) replaced
  in
  let added = distinct_symbols t ~count:replaced ~excluding:held in
  List.iter dropped ~f:(Hash_set.remove held);
  Hash_set.iter added ~f:(Hash_set.add held);
  let symbols = Hash_set.to_array held in
  Array.sort symbols ~compare:Int.compare;
  composition_of t ~etf ~version:(current.version + 1) ~symbols
;;

let nav t etf =
  let c = t.compositions.(etf) in
  let positions_value =
    Array.sum
      (module Float)
      c.holdings
      ~f:(fun h -> h.units *. t.prices.(symbol_index h.symbol))
  in
  Nav.nav ~cash:c.cash ~positions_value ~shares_outstanding:c.shares_outstanding
;;

let price_tick t ~ts =
  let symbol = random_int t t.config.symbols in
  let price = t.prices.(symbol) *. Float.exp (t.config.volatility *. gaussian t) in
  t.prices.(symbol) <- price;
  Event.Price { symbol = symbol_name symbol; price; ts }
;;

let etf_price t etf ~ts =
  let price = nav t etf *. (1. +. (0.001 *. gaussian t)) in
  Event.Etf_price { etf = etf_name etf; price; ts }
;;

let idle_etf t =
  let etf = random_int t t.config.etfs in
  Option.some_if (not t.rebalancing.(etf)) etf
;;

let rebalance_steps t ~(target : Composition.t) : Rebalance_step.t list =
  if Float.( < ) (random_unit t) t.config.reject_ratio
  then [ Reject "validation failed" ]
  else
    Rebalance_step.[ Validate; Begin_applying ]
    @ List.map (Array.to_list target.holdings) ~f:(fun h -> Rebalance_step.Progress h)
    @ Rebalance_step.[ Apply; Settle ]
;;

let start_rebalance t etf ~ts =
  let id = t.next_rebalance_id in
  t.next_rebalance_id <- id + 1;
  t.rebalancing.(etf) <- true;
  let target = next_composition t etf in
  List.iter (rebalance_steps t ~target) ~f:(fun step ->
    Queue.enqueue t.pending { etf; id; step; target });
  Event.Rebalance { etf = etf_name etf; id; step = Announce target; ts }
;;

let advance_rebalance t ~ts =
  let { etf; id; step; target } = Queue.dequeue_exn t.pending in
  (match step with
   | Apply -> t.compositions.(etf) <- target
   | Settle | Reject _ -> t.rebalancing.(etf) <- false
   | Announce _ | Validate | Begin_applying | Progress _ -> ());
  Event.Rebalance { etf = etf_name etf; id; step; ts }
;;

let update_composition t etf ~ts =
  let composition = next_composition t etf in
  t.compositions.(etf) <- composition;
  Event.Composition { composition; ts }
;;

let pick_kind t =
  let c = t.config in
  let rec pick u = function
    | [] -> `Price_tick
    | (ratio, kind) :: rest ->
      if Float.( < ) u ratio then kind else pick (u -. ratio) rest
  in
  pick
    (random_unit t)
    [ c.etf_price_ratio, `Etf_price
    ; c.rebalance_step_ratio, `Advance_rebalance
    ; c.rebalance_ratio, `Start_rebalance
    ; c.composition_ratio, `Update_composition
    ]
;;

let stream_event t ~ts =
  match pick_kind t with
  | `Etf_price -> etf_price t (random_int t t.config.etfs) ~ts
  | `Advance_rebalance when not (Queue.is_empty t.pending) -> advance_rebalance t ~ts
  | `Start_rebalance ->
    (match idle_etf t with
     | Some etf -> start_rebalance t etf ~ts
     | None -> price_tick t ~ts)
  | `Update_composition ->
    (match idle_etf t with
     | Some etf -> update_composition t etf ~ts
     | None -> price_tick t ~ts)
  | `Advance_rebalance | `Price_tick -> price_tick t ~ts
;;

let holder_stats compositions =
  let holders = Hashtbl.create (module String) in
  Array.iter compositions ~f:(fun (c : Composition.t) ->
    Array.iter c.holdings ~f:(fun h -> Hashtbl.incr holders h.symbol));
  let counts = Hashtbl.data holders in
  let held = List.length counts in
  ( held
  , Float.of_int (List.sum (module Int) counts ~f:Fn.id) /. Float.of_int held
  , List.max_elt counts ~compare:Int.compare |> Option.value ~default:0 )
;;

let generate (config : Config.t) ~f =
  Config.validate config;
  let rng = Random.State.make [| config.seed |] in
  let prices =
    Array.init config.symbols ~f:(fun _ ->
      Float.exp (Random.State.float_range rng (Float.log 5.) (Float.log 500.)))
  in
  let t =
    { config
    ; rng
    ; prices
    ; compositions = [||]
    ; rebalancing = Array.create ~len:config.etfs false
    ; pending = Queue.create ()
    ; next_rebalance_id = 0
    }
  in
  let t =
    { t with
      compositions =
        Array.init config.etfs ~f:(fun etf ->
          let symbols =
            distinct_symbols
              t
              ~count:config.basket_size
              ~excluding:(Hash_set.create (module Int))
            |> Hash_set.to_array
          in
          Array.sort symbols ~compare:Int.compare;
          composition_of t ~etf ~version:1 ~symbols)
    }
  in
  let symbols_held, mean_holders_per_symbol, max_holders_per_symbol =
    holder_stats t.compositions
  in
  let summary =
    ref
      { Summary.events = 0
      ; prices = 0
      ; etf_prices = 0
      ; compositions = 0
      ; rebalance_steps = 0
      ; rebalances = 0
      ; rejected_rebalances = 0
      ; symbols_held
      ; mean_holders_per_symbol
      ; max_holders_per_symbol
      }
  in
  let emit make =
    let s = !summary in
    let ts = Time_ns.add start (Time_ns.Span.scale_int config.tick_interval s.events) in
    let event : Event.t = make ~ts in
    let s = { s with events = s.events + 1 } in
    (summary
     := match event with
        | Price _ -> { s with prices = s.prices + 1 }
        | Etf_price _ -> { s with etf_prices = s.etf_prices + 1 }
        | Composition _ -> { s with compositions = s.compositions + 1 }
        | Rebalance { step; _ } ->
          let s = { s with rebalance_steps = s.rebalance_steps + 1 } in
          (match step with
           | Announce _ -> { s with rebalances = s.rebalances + 1 }
           | Reject _ -> { s with rejected_rebalances = s.rejected_rebalances + 1 }
           | Validate | Begin_applying | Progress _ | Apply | Settle -> s));
    f event
  in
  Array.iter t.compositions ~f:(fun composition ->
    emit (fun ~ts -> Event.Composition { composition; ts }));
  Array.iteri t.prices ~f:(fun symbol price ->
    emit (fun ~ts -> Event.Price { symbol = symbol_name symbol; price; ts }));
  for etf = 0 to config.etfs - 1 do
    emit (etf_price t etf)
  done;
  for _ = Config.setup_events config + 1 to config.events do
    emit (stream_event t)
  done;
  !summary
;;
