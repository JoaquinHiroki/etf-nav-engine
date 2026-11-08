open! Core
open Nav_domain

module Config : sig
  type t =
    { seed : int
    ; events : int (** total, including the setup events *)
    ; symbols : int
    ; etfs : int
    ; basket_size : int
    ; etf_price_ratio : float
    ; rebalance_ratio : float (** chance an event starts a rebalance *)
    ; rebalance_step_ratio : float (** chance an event advances a pending rebalance *)
    ; reject_ratio : float
    ; composition_ratio : float (** chance an event is a direct composition update *)
    ; volatility : float (** per-tick standard deviation of log returns *)
    ; tick_interval : Time_ns.Span.t
    }
  [@@deriving sexp]

  val default : t
end

module Summary : sig
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

(** Streams [config.events] events to [f]: a composition per ETF, a price per symbol and
    a price per ETF, then randomly interleaved price ticks, ETF prices, composition
    updates and rebalances. The same config always produces the same events. *)
val generate : Config.t -> f:(Event.t -> unit) -> Summary.t
