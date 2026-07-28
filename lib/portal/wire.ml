exception Read_error of string

let write socket value =
  let bytes = Msgpck.String.to_string value |> Bytes.unsafe_to_string in
  let rec loop offset =
    if offset < String.length bytes then
      let written =
        Unix.write_substring socket bytes offset (String.length bytes - offset)
      in
      if written = 0 then
        raise (Read_error "portal socket closed while writing")
      else loop (offset + written)
  in
  loop 0

let read ?(timeout_ms = 0) socket =
  let buffer = Buffer.create 4096 in
  let chunk = Bytes.create 4096 in
  let deadline =
    if timeout_ms <= 0 then None
    else Some (Unix.gettimeofday () +. (float timeout_ms /. 1000.))
  in
  let wait_until_readable () =
    match deadline with
    | None -> ()
    | Some deadline ->
        let remaining = deadline -. Unix.gettimeofday () in
        if remaining <= 0. then raise (Read_error "portal request timed out");
        let readable, _, _ = Unix.select [ socket ] [] [] remaining in
        if readable = [] then raise (Read_error "portal request timed out")
  in
  let rec loop () =
    wait_until_readable ();
    let count = Unix.read socket chunk 0 (Bytes.length chunk) in
    if count = 0 then
      raise
        (Read_error "portal socket closed before a complete message arrived")
    else (
      Buffer.add_subbytes buffer chunk 0 count;
      let contents = Buffer.contents buffer in
      try
        let consumed, value = Msgpck.String.read contents in
        if consumed = String.length contents then value else value
      with Invalid_argument _ -> loop ())
  in
  loop ()
