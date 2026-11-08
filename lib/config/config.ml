open! Core

let env name ~default = Sys.getenv name |> Option.value ~default
let topic = "etf.events.v1"
let test_topic = "etf.events.test"
let kafka_brokers () = env "NAV_KAFKA_BROKERS" ~default:"localhost:9092"

let postgres_conninfo db =
  sprintf "host=localhost port=55432 dbname=%s user=nav password=nav" db
;;

let postgres () = env "NAV_POSTGRES" ~default:(postgres_conninfo "nav")
let postgres_test () = env "NAV_POSTGRES_TEST" ~default:(postgres_conninfo "nav_test")
