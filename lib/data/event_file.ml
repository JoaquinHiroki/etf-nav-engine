open! Core
open Nav_domain

let magic = "ETFEV001"

let with_writer path ~f =
  Out_channel.with_file path ~f:(fun oc ->
    Out_channel.output_string oc magic;
    f (fun event ->
      let payload = Event.to_string event in
      Out_channel.output_binary_int oc (String.length payload);
      Out_channel.output_string oc payload))
;;

let read_exactly ic len =
  let buf = Bytes.create len in
  In_channel.really_input_exn ic ~buf ~pos:0 ~len;
  Bytes.unsafe_to_string ~no_mutation_while_string_reachable:buf
;;

let fold ?(limit = Int.max_value) path ~init ~f =
  In_channel.with_file path ~f:(fun ic ->
    let header = read_exactly ic (String.length magic) in
    if not (String.equal header magic)
    then raise_s [%message "not an event file" (path : string)];
    let rec loop acc count =
      if count >= limit
      then acc
      else (
        match In_channel.input_binary_int ic with
        | None -> acc
        | Some len -> loop (f acc (Event.of_string (read_exactly ic len))) (count + 1))
    in
    loop init 0)
;;

let iter ?limit path ~f = fold ?limit path ~init:() ~f:(fun () event -> f event)

let read_all ?limit path =
  fold ?limit path ~init:[] ~f:(fun acc event -> event :: acc) |> Array.of_list_rev
;;

let open_at path offset =
  let ic = In_channel.create path in
  let header = read_exactly ic (String.length magic) in
  if not (String.equal header magic)
  then raise_s [%message "not an event file" (path : string)];
  let rec skip remaining =
    if remaining > 0
    then (
      match In_channel.input_binary_int ic with
      | None -> ()
      | Some len ->
        In_channel.seek ic (Int64.( + ) (In_channel.pos ic) (Int64.of_int len));
        skip (remaining - 1))
  in
  skip offset;
  ic
;;

let source path =
  let ic = ref (open_at path 0) in
  let next = ref 0 in
  let seek offset =
    In_channel.close !ic;
    ic := open_at path offset;
    next := offset
  in
  let poll ~max =
    let rec loop acc count =
      if count >= max
      then acc
      else (
        match In_channel.input_binary_int !ic with
        | None -> acc
        | Some len ->
          let event = Event.of_string (read_exactly !ic len) in
          let record = { Nav_source.Source.offset = !next; event } in
          incr next;
          loop (record :: acc) (count + 1))
    in
    List.rev (loop [] 0)
  in
  { Nav_source.Source.seek; poll; close = (fun () -> In_channel.close !ic) }
;;
