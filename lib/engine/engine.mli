open! Core
open Nav_graph
open Nav_source

module Latency : sig
  type t =
    { p50_us : float
    ; p99_us : float
    ; p999_us : float
    ; max_us : float
    }
  [@@deriving sexp]
end

module Report : sig
  type t =
    { writer : string
    ; batch_size : int
    ; events : int
    ; nav_updates : int
    ; seconds : float
    ; events_per_second : float
    ; processing_latency : Latency.t option
    ; latency_since_event_ts : Latency.t option
    }
  [@@deriving sexp]
end

(** Seeks [source] to [start_offset], then polls batches of up to [batch_size] records,
    computes each change and hands the batch to [writer]. Stops after [max_events], or
    once a poll has returned nothing for [idle_timeout].

    Processing latency runs from the poll that returned an event to the write of its
    batch. Latency since the event timestamp is only meaningful when the events were
    replayed at a fixed rate, which stamps them with their scheduled send time, so it is
    only reported when [scheduled] is set. Time spent idle before the first event is not
    counted. *)
val run
  :  ?max_events:int
  -> ?scheduled:bool
  -> ?idle_timeout:Time_ns.Span.t
  -> batch_size:int
  -> start_offset:int
  -> source:Source.t
  -> writer:Writer.t
  -> Full_recompute.t
  -> Report.t
