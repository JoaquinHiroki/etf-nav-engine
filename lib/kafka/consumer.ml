open! Core
open Nav_domain
open Nav_source

let partition = 0
let max_batch = 10_000

let create ?(poll_timeout_ms = 100) ~brokers ~topic:name () =
  let handler = Kafka.new_consumer [ "metadata.broker.list", brokers ] in
  let topic = Kafka.new_topic handler name [] in
  let started = ref false in
  let stop () = if !started then Kafka.consume_stop topic partition in
  let seek offset =
    stop ();
    Kafka.consume_start topic partition (Int64.of_int offset);
    started := true
  in
  let poll ~max =
    if not !started then seek 0;
    Kafka.consume_batch
      ~timeout_ms:poll_timeout_ms
      ~msg_count:(Int.min max max_batch)
      topic
      partition
    |> List.filter_map ~f:(function
      | Kafka.Message (_, _, offset, payload, _) ->
        Some { Source.offset = Int64.to_int_exn offset; event = Event.of_string payload }
      | PartitionEnd _ -> None)
  in
  let close () =
    stop ();
    Kafka.destroy_topic topic;
    Kafka.destroy_handler handler
  in
  { Source.seek; poll; close }
;;
