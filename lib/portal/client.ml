exception Portal_error of string

type t = { socket_path : string; timeout_ms : int }

let create ?socket ?config () =
  let config = Config.load ?path:config () in
  let socket_path =
    match (socket, Sys.getenv_opt "AGENT_PORTAL_SOCKET") with
    | Some path, _ -> path
    | None, Some path when path <> "" -> path
    | None, _ -> config.socket_path
  in
  { socket_path; timeout_ms = config.request_timeout_ms }

let request client method_ =
  let socket = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close socket)
    (fun () ->
      Unix.connect socket (Unix.ADDR_UNIX client.socket_path);
      let id = Int64.of_float (Unix.gettimeofday () *. 1000.) in
      Wire.write socket
        (Protocol.request_to_msgpack Protocol.{ version = 1; id; method_ });
      let response =
        Wire.read ~timeout_ms:client.timeout_ms socket
        |> Protocol.response_of_msgpack
      in
      if response.ok then
        match response.result with
        | Some result -> result
        | None -> raise (Portal_error "portal returned no result")
      else
        match response.error with
        | Some error -> raise (Portal_error (error.code ^ ": " ^ error.message))
        | None -> raise (Portal_error "portal request failed"))

let clipboard_read_image client reason =
  match request client (Protocol.Clipboard_read_image { reason }) with
  | Protocol.Clipboard_image { mime; bytes } -> (mime, bytes)
  | _ -> raise (Portal_error "unexpected clipboard response")
