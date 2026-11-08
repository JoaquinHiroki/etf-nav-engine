open! Core
open Nav_config

let check_postgres () =
  let conn = new Postgresql.connection ~conninfo:(Config.postgres ()) () in
  let major, _, _ = conn#server_version in
  conn#finish;
  printf "postgres: connected, server version %d\n" major
;;

let check_kafka () =
  let producer = Kafka.new_producer [ "metadata.broker.list", Config.kafka_brokers () ] in
  let topics = Kafka.all_topics_metadata ~timeout_ms:5_000 producer in
  Kafka.destroy_handler producer;
  printf "kafka: connected, %d topics\n" (List.length topics)
;;

let () =
  check_postgres ();
  check_kafka ()
;;
