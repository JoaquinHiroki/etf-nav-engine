open! Core

let env name ~default = Sys.getenv name |> Option.value ~default

let check_postgres () =
  let conninfo =
    env
      "NAV_POSTGRES"
      ~default:"host=localhost port=55432 dbname=nav user=nav password=nav"
  in
  let conn = new Postgresql.connection ~conninfo () in
  let major, _, _ = conn#server_version in
  conn#finish;
  printf "postgres: connected, server version %d\n" major
;;

let check_kafka () =
  let brokers = env "NAV_KAFKA_BROKERS" ~default:"localhost:9092" in
  let producer = Kafka.new_producer [ "metadata.broker.list", brokers ] in
  let topics = Kafka.all_topics_metadata ~timeout_ms:5_000 producer in
  Kafka.destroy_handler producer;
  printf "kafka: connected, %d topics\n" (List.length topics)
;;

let () =
  check_postgres ();
  check_kafka ()
;;
