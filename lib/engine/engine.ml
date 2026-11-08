open! Core
open Nav_domain
open Nav_source

module Latency = struct
  type t =
    { p50_us : float
    ; p99_us : float
    ; p999_us : float
    ; max_us : float
    }
  [@@deriving sexp]

  let of_ns samples =
    if Queue.is_empty samples
    then None
    else (
      let sorted = Queue.to_array samples in
      Array.sort sorted ~compare:Int.compare;
      let n = Array.length sorted in
      let at q =
        Float.of_int
          sorted.(Int.min (n - 1) (Float.iround_down_exn (q *. Float.of_int n)))
        /. 1_000.
      in
      Some { p50_us = at 0.5; p99_us = at 0.99; p999_us = at 0.999; max_us = at 1. })
  ;;
end

module Report = struct
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

let run
  ?(max_events = Int.max_value)
  ?(scheduled = false)
  ?(idle_timeout = Time_ns.Span.of_sec 5.)
  ~batch_size
  ~start_offset
  ~(source : Source.t)
  ~(writer : Writer.t)
  state
  =
  source.seek start_offset;
  let processing = Queue.create () in
  let since_event_ts = Queue.create () in
  let events = ref 0 in
  let nav_updates = ref 0 in
  let started = ref None in
  let finished = ref (Time_ns.now ()) in
  let rec loop ~last_activity =
    let remaining = max_events - !events in
    if remaining > 0
    then (
      match source.poll ~max:(Int.min batch_size remaining) with
      | [] ->
        let now = Time_ns.now () in
        if Time_ns.Span.( < ) (Time_ns.diff now last_activity) idle_timeout
        then loop ~last_activity
      | records ->
        let polled = Time_ns.now () in
        if Option.is_none !started then started := Some polled;
        let changes = List.map records ~f:(Change.compute state) in
        writer.write changes;
        let written = Time_ns.now () in
        List.iter changes ~f:(fun change ->
          nav_updates := !nav_updates + List.length change.navs;
          Queue.enqueue processing (Time_ns.Span.to_int_ns (Time_ns.diff written polled));
          Queue.enqueue
            since_event_ts
            (Time_ns.Span.to_int_ns (Time_ns.diff written (Event.ts change.event))));
        events := !events + List.length records;
        finished := written;
        loop ~last_activity:written)
  in
  loop ~last_activity:(Time_ns.now ());
  let seconds =
    Option.value_map !started ~default:0. ~f:(fun started ->
      Time_ns.Span.to_sec (Time_ns.diff !finished started))
  in
  { Report.writer = writer.name
  ; batch_size
  ; events = !events
  ; nav_updates = !nav_updates
  ; seconds
  ; events_per_second =
      (if Float.(seconds > 0.) then Float.of_int !events /. seconds else 0.)
  ; processing_latency = Latency.of_ns processing
  ; latency_since_event_ts = (if scheduled then Latency.of_ns since_event_ts else None)
  }
;;
