open! Core
open Nav_config
open Nav_data
open Nav_domain
open Nav_kafka

let rec wait_until deadline =
  let remaining = Time_ns.diff deadline (Time_ns.now ()) in
  if Time_ns.Span.(remaining > of_int_ms 2)
  then (
    ignore (Core_unix.nanosleep (Time_ns.Span.to_sec remaining -. 0.001) : float);
    wait_until deadline)
  else if Time_ns.Span.(remaining > zero)
  then wait_until deadline
;;

let report ~sent ~started =
  let seconds = Time_ns.Span.to_sec (Time_ns.diff (Time_ns.now ()) started) in
  eprintf
    "%d events in %.1fs (%.0f events/s)\n%!"
    sent
    seconds
    (Float.of_int sent /. seconds)
;;

let replay ~input ~topic ~rate ~limit =
  let producer = Producer.create ~brokers:(Config.kafka_brokers ()) ~topic in
  let started = Time_ns.now () in
  let scheduled_time =
    Option.map rate ~f:(fun rate sent ->
      Time_ns.add started (Time_ns.Span.of_int_ns (sent * 1_000_000_000 / rate)))
  in
  let sent =
    Event_file.fold ?limit input ~init:0 ~f:(fun sent event ->
      (match scheduled_time with
       | None -> Producer.send producer event
       | Some scheduled_time ->
         let scheduled = scheduled_time sent in
         wait_until scheduled;
         Producer.send producer (Event.with_ts event scheduled));
      if (sent + 1) % 1_000_000 = 0 then report ~sent:(sent + 1) ~started;
      sent + 1)
  in
  Producer.flush producer;
  Producer.close producer;
  report ~sent ~started
;;

let command =
  Command.basic
    ~summary:"Publish an event file to Kafka"
    ~readme:(fun () ->
      "Without -rate, events are sent as fast as possible with their original \
       timestamps. With -rate, event i is sent at start + i/rate and its timestamp is \
       replaced by that scheduled time, so latency can be measured against it.")
    (let%map_open.Command input = flag "input" (required string) ~doc:"FILE event file"
     and topic =
       flag "topic" (optional_with_default Config.topic string) ~doc:"TOPIC Kafka topic"
     and rate =
       flag "rate" (optional int) ~doc:"N events per second (default: full speed)"
     and limit = flag "limit" (optional int) ~doc:"N stop after N events" in
     fun () -> replay ~input ~topic ~rate ~limit)
;;

let () = Command_unix.run command
