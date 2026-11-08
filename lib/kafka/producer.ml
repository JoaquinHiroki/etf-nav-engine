open! Core
open Nav_domain

type t =
  { handler : Kafka.handler
  ; topic : Kafka.topic
  ; failed_deliveries : int ref
  }

let partition = 0

let create ~brokers ~topic =
  let failed_deliveries = ref 0 in
  let delivery_callback _msg_id error =
    if Option.is_some error then incr failed_deliveries
  in
  let handler =
    Kafka.new_producer ~delivery_callback [ "metadata.broker.list", brokers ]
  in
  { handler; topic = Kafka.new_topic handler topic []; failed_deliveries }
;;

let rec send t event =
  match
    Kafka.produce t.topic partition ~key:(Event.key event) (Event.to_string event)
  with
  | () -> ignore (Kafka.poll_events ~timeout_ms:0 t.handler : int)
  | exception Kafka.Error (QUEUE_FULL, _) ->
    ignore (Kafka.poll_events ~timeout_ms:10 t.handler : int);
    send t event
;;

let flush t =
  Kafka.wait_delivery t.handler;
  if !(t.failed_deliveries) > 0
  then raise_s [%message "Kafka deliveries failed" (t.failed_deliveries : int ref)]
;;

let close t =
  Kafka.destroy_topic t.topic;
  Kafka.destroy_handler t.handler
;;
