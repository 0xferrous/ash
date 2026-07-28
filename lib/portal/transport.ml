type endpoint = Unix of string | Vsock of { cid : int; port : int }

type listener =
  | Unix_listener of Unix.file_descr * string
  | Vsock_listener of Unix.file_descr

type accepted = { socket : Unix.file_descr; peer_vsock_cid : int option }

external vsock_listen : int -> int -> Unix.file_descr
  = "agent_portal_vsock_listen"

external vsock_connect : int -> int -> Unix.file_descr
  = "agent_portal_vsock_connect"

external vsock_accept : Unix.file_descr -> Unix.file_descr * int
  = "agent_portal_vsock_accept"

external vsock_local_cid : unit -> int = "agent_portal_vsock_local_cid"

let validate_uint32 name value =
  if value < 0 || Int64.of_int value > 0xffff_ffffL then
    invalid_arg (name ^ " must fit in an unsigned 32-bit integer")

let vsock ~cid ~port =
  validate_uint32 "vsock CID" cid;
  validate_uint32 "vsock port" port;
  if port = 0 then invalid_arg "vsock port must be positive";
  Vsock { cid; port }

let managed_port_base = 0x1_0000

let managed_port_for_cid cid =
  validate_uint32 "vsock CID" cid;
  let port = Int64.add (Int64.of_int managed_port_base) (Int64.of_int cid) in
  if port > 0xffff_ffffL then
    invalid_arg "vsock CID is too large for managed port";
  Int64.to_int port

let managed ~host_cid =
  let local_cid = vsock_local_cid () in
  if Int64.of_int local_cid = 0xffff_ffffL then
    failwith "AF_VSOCK did not report a usable local CID";
  vsock ~cid:host_cid ~port:(managed_port_for_cid local_cid)

let describe = function
  | Unix path -> "unix:" ^ path
  | Vsock { cid; port } -> Printf.sprintf "vsock:%d:%d" cid port

let describe_listener = function
  | Unix path -> "unix:" ^ path
  | Vsock { port; _ } -> Printf.sprintf "vsock:any:%d" port

let parse_vsock value =
  let parse_int label value =
    try int_of_string value
    with Failure _ -> invalid_arg ("invalid " ^ label ^ ": " ^ value)
  in
  let managed_prefix =
    if String.starts_with ~prefix:"vsock-managed:" value then Some 14
    else if String.starts_with ~prefix:"managed:" value then Some 8
    else None
  in
  match managed_prefix with
  | Some prefix_length ->
      let host_cid =
        String.sub value prefix_length (String.length value - prefix_length)
        |> parse_int "managed vsock host CID"
      in
      managed ~host_cid
  | None -> (
      let value =
        if String.starts_with ~prefix:"vsock://" value then
          String.sub value 8 (String.length value - 8)
        else if String.starts_with ~prefix:"vsock:" value then
          String.sub value 6 (String.length value - 6)
        else value
      in
      match String.split_on_char ':' value with
      | [ cid; port ] ->
          vsock
            ~cid:(parse_int "vsock CID" cid)
            ~port:(parse_int "vsock port" port)
      | _ -> invalid_arg ("invalid vsock endpoint: " ^ value))

let connect = function
  | Unix path -> (
      let socket = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
      try
        Unix.connect socket (Unix.ADDR_UNIX path);
        socket
      with exn ->
        Unix.close socket;
        raise exn)
  | Vsock { cid; port } -> vsock_connect cid port

let listen endpoint backlog =
  match endpoint with
  | Unix path -> (
      let directory = Filename.dirname path in
      Process.ensure_dir directory;
      Unix.chmod directory 0o700;
      (if Sys.file_exists path then
         match (Unix.lstat path).st_kind with
         | Unix.S_SOCK -> Unix.unlink path
         | _ -> failwith ("refusing to replace non-socket path: " ^ path));
      let socket = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
      try
        Unix.bind socket (Unix.ADDR_UNIX path);
        Unix.chmod path 0o600;
        Unix.listen socket backlog;
        Unix_listener (socket, path)
      with exn ->
        Unix.close socket;
        raise exn)
  | Vsock { port; _ } -> Vsock_listener (vsock_listen port backlog)

let close_listener = function
  | Unix_listener (socket, path) -> (
      Unix.close socket;
      try Unix.unlink path with Unix.Unix_error _ -> ())
  | Vsock_listener socket -> Unix.close socket

let accept = function
  | Unix_listener (listener, _) ->
      let socket, _ = Unix.accept listener in
      { socket; peer_vsock_cid = None }
  | Vsock_listener listener ->
      let socket, cid = vsock_accept listener in
      { socket; peer_vsock_cid = Some cid }
