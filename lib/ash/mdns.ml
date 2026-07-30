let multicast_address =
  Unix.ADDR_INET (Unix.inet_addr_of_string "224.0.0.251", 5353)

let default_ttl = 120l
let query_interval = 2.0

external open_socket : string -> Unix.file_descr = "ash_mdns_open_socket"

let lowercase = String.lowercase_ascii

let digest_prefix value =
  Digest.string value |> Digest.to_hex |> fun value -> String.sub value 0 8

let trim_hyphens value =
  let length = String.length value in
  let rec first i =
    if i < length && value.[i] = '-' then first (i + 1) else i
  in
  let rec last i = if i >= 0 && value.[i] = '-' then last (i - 1) else i in
  let start = first 0 in
  let stop = last (length - 1) in
  if stop < start then "" else String.sub value start (stop - start + 1)

let dns_label name =
  let lowered = lowercase name in
  let changed = ref (lowered <> name) in
  let buffer = Buffer.create (String.length lowered) in
  String.iter
    (function
      | ('a' .. 'z' | '0' .. '9' | '-') as character ->
          Buffer.add_char buffer character
      | _ ->
          changed := true;
          Buffer.add_char buffer '-')
    lowered;
  let normalized = Buffer.contents buffer |> trim_hyphens in
  if normalized <> lowered then changed := true;
  let normalized = if normalized = "" then "vm" else normalized in
  if (not !changed) && String.length normalized <= 63 then normalized
  else
    let suffix = "-" ^ digest_prefix name in
    let maximum_base = 63 - String.length suffix in
    let base =
      if String.length normalized <= maximum_base then normalized
      else String.sub normalized 0 maximum_base |> trim_hyphens
    in
    (if base = "" then "vm" else base) ^ suffix

let fqdn name = dns_label name ^ ".ash.local"

let add_u16 buffer value =
  Buffer.add_char buffer (Char.chr ((value lsr 8) land 0xff));
  Buffer.add_char buffer (Char.chr (value land 0xff))

let add_u32 buffer value =
  let open Int32 in
  Buffer.add_char buffer
    (Char.chr (to_int (shift_right_logical value 24) land 0xff));
  Buffer.add_char buffer
    (Char.chr (to_int (shift_right_logical value 16) land 0xff));
  Buffer.add_char buffer
    (Char.chr (to_int (shift_right_logical value 8) land 0xff));
  Buffer.add_char buffer (Char.chr (to_int value land 0xff))

let u16 packet offset =
  if offset + 2 > Bytes.length packet then invalid_arg "short DNS u16";
  (Char.code (Bytes.get packet offset) lsl 8)
  lor Char.code (Bytes.get packet (offset + 1))

let u32 packet offset =
  if offset + 4 > Bytes.length packet then invalid_arg "short DNS u32";
  let open Int32 in
  logor
    (shift_left (of_int (Char.code (Bytes.get packet offset))) 24)
    (logor
       (shift_left (of_int (Char.code (Bytes.get packet (offset + 1)))) 16)
       (logor
          (shift_left (of_int (Char.code (Bytes.get packet (offset + 2)))) 8)
          (of_int (Char.code (Bytes.get packet (offset + 3))))))

let labels name =
  let name =
    if String.length name > 0 && name.[String.length name - 1] = '.' then
      String.sub name 0 (String.length name - 1)
    else name
  in
  String.split_on_char '.' name

let add_name buffer name =
  labels name
  |> List.iter (fun label ->
      let length = String.length label in
      if length = 0 || length > 63 then invalid_arg "invalid DNS label";
      Buffer.add_char buffer (Char.chr length);
      Buffer.add_string buffer label);
  Buffer.add_char buffer '\000'

let decode_name packet offset =
  let packet_length = Bytes.length packet in
  let rec loop position jumped next_offset depth acc =
    if depth > 32 || position >= packet_length then
      invalid_arg "invalid DNS name";
    let length = Char.code (Bytes.get packet position) in
    if length = 0 then
      let next_offset = if jumped then next_offset else position + 1 in
      (String.concat "." (List.rev acc), next_offset)
    else if length land 0xc0 = 0xc0 then (
      if position + 1 >= packet_length then invalid_arg "short DNS pointer";
      let pointer =
        ((length land 0x3f) lsl 8)
        lor Char.code (Bytes.get packet (position + 1))
      in
      let next_offset = if jumped then next_offset else position + 2 in
      loop pointer true next_offset (depth + 1) acc)
    else if length land 0xc0 <> 0 || position + 1 + length > packet_length then
      invalid_arg "invalid DNS label"
    else
      let label = Bytes.sub_string packet (position + 1) length in
      loop (position + 1 + length) jumped next_offset (depth + 1) (label :: acc)
  in
  loop offset false 0 0 []

let ipv4_octets address =
  ignore (Unix.inet_addr_of_string address);
  match String.split_on_char '.' address |> List.map int_of_string_opt with
  | [ Some a; Some b; Some c; Some d ]
    when List.for_all (fun value -> value >= 0 && value <= 255) [ a; b; c; d ]
    ->
      [ a; b; c; d ]
  | _ -> invalid_arg "invalid IPv4 address"

let add_a_record buffer ~cache_flush ~name ~ttl address =
  add_name buffer name;
  add_u16 buffer 1;
  add_u16 buffer (if cache_flush then 0x8001 else 1);
  add_u32 buffer ttl;
  add_u16 buffer 4;
  ipv4_octets address
  |> List.iter (fun octet -> Buffer.add_char buffer (Char.chr octet))

let response ~ttl ~name address =
  let buffer = Buffer.create 128 in
  add_u16 buffer 0;
  add_u16 buffer 0x8400;
  add_u16 buffer 0;
  add_u16 buffer 1;
  add_u16 buffer 0;
  add_u16 buffer 0;
  add_a_record buffer ~cache_flush:true ~name ~ttl address;
  Buffer.contents buffer

let probe ~name address =
  let buffer = Buffer.create 160 in
  add_u16 buffer 0;
  add_u16 buffer 0;
  add_u16 buffer 1;
  add_u16 buffer 0;
  add_u16 buffer 1;
  add_u16 buffer 0;
  add_name buffer name;
  add_u16 buffer 255;
  add_u16 buffer 1;
  add_a_record buffer ~cache_flush:false ~name ~ttl:default_ttl address;
  Buffer.contents buffer

let skip_questions packet count offset =
  let rec loop remaining offset =
    if remaining = 0 then offset
    else
      let _, offset = decode_name packet offset in
      if offset + 4 > Bytes.length packet then invalid_arg "short DNS question";
      loop (remaining - 1) (offset + 4)
  in
  loop count offset

let questions packet =
  if Bytes.length packet < 12 then []
  else
    let count = u16 packet 4 in
    let rec loop remaining offset acc =
      if remaining = 0 then List.rev acc
      else
        let name, offset = decode_name packet offset in
        if offset + 4 > Bytes.length packet then
          invalid_arg "short DNS question";
        let record_type = u16 packet offset in
        let record_class = u16 packet (offset + 2) in
        loop (remaining - 1) (offset + 4)
          ((lowercase name, record_type, record_class land 0x8000 <> 0) :: acc)
    in
    loop count 12 []

let record_ipv4 packet offset length =
  if length <> 4 || offset + 4 > Bytes.length packet then None
  else
    Some
      (Printf.sprintf "%d.%d.%d.%d"
         (Char.code (Bytes.get packet offset))
         (Char.code (Bytes.get packet (offset + 1)))
         (Char.code (Bytes.get packet (offset + 2)))
         (Char.code (Bytes.get packet (offset + 3))))

let conflicting_a_record packet ~name ~address =
  if Bytes.length packet < 12 then false
  else
    try
      let question_count = u16 packet 4 in
      let record_count = u16 packet 6 + u16 packet 8 + u16 packet 10 in
      let start = skip_questions packet question_count 12 in
      let rec loop remaining offset =
        if remaining = 0 then false
        else
          let record_name, offset = decode_name packet offset in
          if offset + 10 > Bytes.length packet then
            invalid_arg "short DNS record";
          let record_type = u16 packet offset in
          let data_length = u16 packet (offset + 8) in
          let data_offset = offset + 10 in
          if data_offset + data_length > Bytes.length packet then
            invalid_arg "short DNS record data";
          match record_ipv4 packet data_offset data_length with
          | Some other
            when record_type = 1
                 && lowercase record_name = lowercase name
                 && other <> address ->
              true
          | _ -> loop (remaining - 1) (data_offset + data_length)
      in
      loop record_count start
    with Invalid_argument _ -> false

let send fd destination payload =
  let bytes = Bytes.of_string payload in
  ignore (Unix.sendto fd bytes 0 (Bytes.length bytes) [] destination)

let receive fd =
  let buffer = Bytes.create 9000 in
  let length, sender = Unix.recvfrom fd buffer 0 (Bytes.length buffer) [] in
  (Bytes.sub buffer 0 length, sender)

let wait timeout =
  try ignore (Unix.select [] [] [] timeout)
  with Unix.Unix_error (Unix.EINTR, _, _) -> ()

let wait_readable fd timeout =
  try
    match Unix.select [ fd ] [] [] timeout with [], _, _ -> false | _ -> true
  with Unix.Unix_error (Unix.EINTR, _, _) -> false

let packet_is_response packet =
  Bytes.length packet >= 4 && u16 packet 2 land 0x8000 <> 0

let query_destination packet sender ~name =
  try
    questions packet
    |> List.find_map (fun (question_name, record_type, unicast) ->
        if
          question_name = lowercase name
          && (record_type = 1 || record_type = 255)
        then Some (if unicast then sender else multicast_address)
        else None)
  with Invalid_argument _ -> None

let probe_name fd ~stopping ~name address =
  let conflict = ref false in
  let initial_delay = Random.float 0.25 in
  wait initial_delay;
  let rec drain_until deadline =
    let remaining = deadline -. Unix.gettimeofday () in
    if remaining > 0. && wait_readable fd remaining then (
      let packet, _ = receive fd in
      if conflicting_a_record packet ~name ~address then conflict := true;
      drain_until deadline)
  in
  for _ = 1 to 3 do
    if (not !stopping) && not !conflict then (
      send fd multicast_address (probe ~name address);
      drain_until (Unix.gettimeofday () +. 0.25))
  done;
  not !conflict

let announce fd ~name address =
  let payload = response ~ttl:default_ttl ~name address in
  send fd multicast_address payload;
  wait 1.0;
  send fd multicast_address payload

let goodbye fd ~name address =
  try send fd multicast_address (response ~ttl:0l ~name address)
  with Unix.Unix_error _ -> ()

let run ~interface ~name ~get_ip () =
  Random.self_init ();
  let stopping = ref false in
  let stop _ = stopping := true in
  Sys.set_signal Sys.sigterm (Sys.Signal_handle stop);
  Sys.set_signal Sys.sigint (Sys.Signal_handle stop);
  let rec open_with_retry () =
    try open_socket interface
    with Failure message ->
      if !stopping then raise Exit
      else (
        Log.warn "mDNS publisher waiting for interface %s: %s" interface message;
        wait 1.0;
        open_with_retry ())
  in
  try
    let fd = open_with_retry () in
    Fun.protect
      ~finally:(fun () -> try Unix.close fd with Unix.Unix_error _ -> ())
      (fun () ->
        let published = ref None in
        let next_ip_check = ref 0. in
        let withdraw () =
          Option.iter
            (fun address ->
              Log.info "withdrawing mDNS record %s -> %s" name address;
              goodbye fd ~name address)
            !published;
          published := None
        in
        Fun.protect ~finally:withdraw (fun () ->
            while not !stopping do
              let now = Unix.gettimeofday () in
              if now >= !next_ip_check then (
                next_ip_check := now +. query_interval;
                let discovered = get_ip () in
                if discovered <> !published then (
                  withdraw ();
                  match discovered with
                  | None -> ()
                  | Some address ->
                      if probe_name fd ~stopping ~name address then (
                        Log.info "publishing mDNS record %s -> %s on %s" name
                          address interface;
                        announce fd ~name address;
                        published := Some address)
                      else Log.warn "mDNS name conflict for %s; retrying" name));
              if wait_readable fd 0.25 then
                let packet, sender = receive fd in
                match !published with
                | None -> ()
                | Some address ->
                    if packet_is_response packet then
                      if conflicting_a_record packet ~name ~address then (
                        Log.warn "mDNS name conflict detected for %s" name;
                        withdraw ();
                        next_ip_check := Unix.gettimeofday () +. 5.0)
                      else ()
                    else
                      Option.iter
                        (fun destination ->
                          send fd destination
                            (response ~ttl:default_ttl ~name address))
                        (query_destination packet sender ~name)
            done));
    0
  with Exit -> 0
