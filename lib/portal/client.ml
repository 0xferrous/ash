exception Portal_error of string

type t = { endpoint : Transport.endpoint; timeout_ms : int }

let configured_endpoint config =
  match config.Config.transport with
  | Config.Unix -> Transport.Unix config.socket_path
  | Config.Vsock ->
      Transport.vsock ~cid:config.vsock_cid ~port:config.vsock_port

let endpoint_from_socket value =
  if String.starts_with ~prefix:"vsock:" value then Transport.parse_vsock value
  else Transport.Unix value

let create ?socket ?vsock ?config () =
  let config = Config.load ?path:config () in
  let endpoint =
    match (socket, vsock) with
    | Some _, Some _ ->
        invalid_arg "--socket and --vsock are mutually exclusive"
    | Some path, None -> endpoint_from_socket path
    | None, Some (cid, port) -> Transport.vsock ~cid ~port
    | None, None -> (
        match Sys.getenv_opt "AGENT_PORTAL_VSOCK" with
        | Some value when value <> "" -> Transport.parse_vsock value
        | _ -> (
            match Sys.getenv_opt "AGENT_PORTAL_SOCKET" with
            | Some value when value <> "" -> endpoint_from_socket value
            | _ -> configured_endpoint config))
  in
  { endpoint; timeout_ms = config.request_timeout_ms }

let request client method_ =
  let socket = Transport.connect client.endpoint in
  Fun.protect
    ~finally:(fun () -> Unix.close socket)
    (fun () ->
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

let gh_exec client argv reason require_approval =
  match
    request client (Protocol.Gh_exec { argv; reason; require_approval })
  with
  | Protocol.Gh_exec_result result -> result
  | _ -> raise (Portal_error "unexpected gh.exec response")
