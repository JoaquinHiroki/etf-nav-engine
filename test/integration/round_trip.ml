open! Core
open Nav_config
open Nav_domain
open Nav_kafka
open Nav_source
open Nav_store

let topic = Config.test_topic
let brokers = Config.kafka_brokers ()

let now_in_micros () =
  let ns = Time_ns.to_int_ns_since_epoch (Time_ns.now ()) in
  Time_ns.of_int_ns_since_epoch (ns / 1_000 * 1_000)
;;

let sample_composition ~version =
  Composition.create
    ~etf:"ROUNDTRIP"
    ~version
    ~holdings:
      [| { symbol = "ETHUSDT"; units = 2.5 }
       ; { symbol = "BTCUSDT"; units = 0.1 }
       ; { symbol = "SOLUSDT"; units = 1. /. 3. }
      |]
    ~cash:1_234.567
    ~shares_outstanding:1e6
  |> ok_exn
;;

let publish event =
  let producer = Producer.create ~brokers ~topic in
  Producer.send producer event;
  Producer.flush producer;
  Producer.close producer
;;

let consume_until (source : Source.t) event ~timeout =
  let deadline = Time_ns.add (Time_ns.now ()) timeout in
  let rec loop () =
    if Time_ns.( > ) (Time_ns.now ()) deadline
    then failwith "published event was not consumed before the deadline";
    match
      List.find (source.poll ~max:1_000) ~f:(fun record ->
        [%compare.equal: Event.t] record.event event)
    with
    | Some record -> record
    | None -> loop ()
  in
  loop ()
;;

let () =
  let ts = now_in_micros () in
  let composition = sample_composition ~version:1 in
  let event = Event.Composition { composition; ts } in
  publish event;
  let source = Consumer.create ~brokers ~topic () in
  let record = consume_until source event ~timeout:(Time_ns.Span.of_sec 10.) in
  source.close ();
  let store = Store.connect (Config.postgres_test ()) in
  Store.truncate_all store;
  Store.transaction store ~f:(fun () ->
    Store.insert_composition store composition ~effective_ts:ts;
    Store.set_next_offset store ~topic (record.offset + 1));
  let compositions = Store.latest_compositions store in
  let next_offset = Store.next_offset store ~topic in
  Store.close store;
  [%test_result: (Composition.t * Timestamp.t) list]
    compositions
    ~expect:[ composition, ts ];
  [%test_result: int option] next_offset ~expect:(Some (record.offset + 1));
  printf "round trip ok: offset %d\n" record.offset
;;
