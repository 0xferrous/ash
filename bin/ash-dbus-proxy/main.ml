open Cmdliner
module Transport = Agent_portal.Transport

let close_noerr fd = try Unix.close fd with Unix.Unix_error _ -> ()

let shutdown_noerr fd command =
  try Unix.shutdown fd command with Unix.Unix_error _ -> ()

let rec write_all fd bytes offset length =
  if length > 0 then
    let written = Unix.write fd bytes offset length in
    if written = 0 then raise End_of_file
    else write_all fd bytes (offset + written) (length - written)

let copy source destination =
  let buffer = Bytes.create 65536 in
  let rec loop () =
    match Unix.read source buffer 0 (Bytes.length buffer) with
    | 0 -> shutdown_noerr destination Unix.SHUTDOWN_SEND
    | count ->
        write_all destination buffer 0 count;
        loop ()
  in
  try loop () with
  | End_of_file -> shutdown_noerr destination Unix.SHUTDOWN_SEND
  | Unix.Unix_error ((Unix.EPIPE | Unix.ECONNRESET), _, _) ->
      shutdown_noerr destination Unix.SHUTDOWN_SEND

let relay left_read left_write right =
  let outbound =
    Thread.create
      (fun () ->
        Fun.protect
          ~finally:(fun () -> shutdown_noerr right Unix.SHUTDOWN_SEND)
          (fun () -> copy left_read right))
      ()
  in
  Fun.protect
    ~finally:(fun () ->
      shutdown_noerr right Unix.SHUTDOWN_ALL;
      Thread.join outbound)
    (fun () -> copy right left_write)

let dbus_port_for_cid cid =
  let base = 0x2_0000L in
  if cid < 0 then invalid_arg "vsock CID must be non-negative";
  let port = Int64.add base (Int64.of_int cid) in
  if port > 0xffff_ffffL then invalid_arg "vsock CID is too large";
  Int64.to_int port

let session_bus_address () =
  match Sys.getenv_opt "DBUS_SESSION_BUS_ADDRESS" with
  | Some address when address <> "" -> address
  | _ -> (
      match Sys.getenv_opt "XDG_RUNTIME_DIR" with
      | Some directory when directory <> "" ->
          "unix:path=" ^ Filename.concat directory "bus"
      | _ -> Printf.sprintf "unix:path=/run/user/%d/bus" (Unix.getuid ()))

let find_xdg_dbus_proxy explicit =
  match explicit with
  | Some path -> path
  | None -> (
      match Sys.getenv_opt "ASH_XDG_DBUS_PROXY" with
      | Some path when path <> "" -> path
      | _ -> Agent_portal.Process.find_binary "xdg-dbus-proxy")

let remove_socket path =
  if Sys.file_exists path then
    match (Unix.lstat path).st_kind with
    | Unix.S_SOCK -> Unix.unlink path
    | _ -> failwith ("refusing to replace non-socket path: " ^ path)

let start_proxy ~program ~socket_path =
  Agent_portal.Process.ensure_dir (Filename.dirname socket_path);
  Unix.chmod (Filename.dirname socket_path) 0o700;
  remove_socket socket_path;
  match Unix.fork () with
  | 0 -> (
      let argv =
        [|
          program;
          session_bus_address ();
          socket_path;
          "--filter";
          "--talk=org.freedesktop.Notifications";
        |]
      in
      try Unix.execv program argv
      with exn ->
        Printf.eprintf "ash-dbus-proxy: failed to start xdg-dbus-proxy: %s\n%!"
          (Printexc.to_string exn);
        exit 127)
  | pid -> pid

let wait_for_proxy ?(should_stop = fun () -> false) pid socket_path =
  let deadline = Unix.gettimeofday () +. 5. in
  let rec loop () =
    if should_stop () || Sys.file_exists socket_path then ()
    else
      let waited, status = Unix.waitpid [ Unix.WNOHANG ] pid in
      if waited <> 0 then
        failwith
          (Printf.sprintf "xdg-dbus-proxy exited before becoming ready (%d)"
             (Agent_portal.Process.status_code status))
      else if Unix.gettimeofday () >= deadline then
        failwith "timed out waiting for xdg-dbus-proxy"
      else (
        Unix.sleepf 0.02;
        loop ())
  in
  loop ()

let stop_child pid =
  (try Unix.kill pid Sys.sigterm with Unix.Unix_error _ -> ());
  try ignore (Unix.waitpid [] pid) with Unix.Unix_error _ -> ()

let close_listener_noerr listener =
  try Transport.close_listener listener with Unix.Unix_error _ -> ()

let install_stop_handlers stop =
  let handle _ = try stop () with Unix.Unix_error _ -> () in
  Sys.set_signal Sys.sigterm (Sys.Signal_handle handle);
  Sys.set_signal Sys.sigint (Sys.Signal_handle handle)

let is_stopped_accept_failure message =
  String.ends_with ~suffix:": Interrupted system call" message
  || String.ends_with ~suffix:": Bad file descriptor" message

let serve_connection socket_path expected_cid accepted =
  Fun.protect
    ~finally:(fun () -> close_noerr accepted.Transport.socket)
    (fun () ->
      if accepted.peer_vsock_cid <> Some expected_cid then
        Printf.eprintf "ash-dbus-proxy: rejected vsock peer CID %s\n%!"
          (Option.fold ~none:"unknown" ~some:string_of_int
             accepted.peer_vsock_cid)
      else
        let proxy = Transport.connect (Transport.Unix socket_path) in
        Fun.protect
          ~finally:(fun () -> close_noerr proxy)
          (fun () -> relay accepted.socket accepted.socket proxy))

let run_host socket_path cid managed port xdg_dbus_proxy =
  let port = if managed then dbus_port_for_cid cid else port in
  if port <= 0 then invalid_arg "--port is required unless --managed is used";
  let program = find_xdg_dbus_proxy xdg_dbus_proxy in
  let child = start_proxy ~program ~socket_path in
  let listener = ref None in
  let stopping = ref false in
  install_stop_handlers (fun () ->
      stopping := true;
      Option.iter close_listener_noerr !listener);
  Fun.protect
    ~finally:(fun () ->
      Option.iter close_listener_noerr !listener;
      stop_child child;
      try remove_socket socket_path with _ -> ())
    (fun () ->
      wait_for_proxy ~should_stop:(fun () -> !stopping) child socket_path;
      if !stopping then 0
      else
        let value = Transport.listen (Transport.vsock ~cid:0 ~port) 16 in
        listener := Some value;
        Printf.eprintf
          "ash-dbus-proxy: forwarding vsock:any:%d to notifications bus proxy %s\n\
           %!"
          port socket_path;
        let rec serve () =
          if !stopping then 0
          else
            match Transport.accept value with
            | accepted ->
                ignore
                  (Thread.create (serve_connection socket_path cid) accepted);
                serve ()
            | exception Unix.Unix_error ((Unix.EBADF | Unix.EINTR), _, _)
              when !stopping ->
                0
            | exception Failure message
              when !stopping && is_stopped_accept_failure message ->
                0
        in
        serve ())

let connect_and_relay cid port local_read local_write =
  let socket = Transport.connect (Transport.vsock ~cid ~port) in
  Fun.protect
    ~finally:(fun () -> close_noerr socket)
    (fun () -> relay local_read local_write socket)

let run_connect cid managed port listen_path =
  let port =
    if managed then Transport.vsock_local_cid () |> dbus_port_for_cid else port
  in
  if port <= 0 then invalid_arg "--port is required unless --managed is used";
  match listen_path with
  | None ->
      connect_and_relay cid port Unix.stdin Unix.stdout;
      0
  | Some path ->
      let listener = Transport.listen (Transport.Unix path) 16 in
      let stopping = ref false in
      install_stop_handlers (fun () ->
          stopping := true;
          close_listener_noerr listener);
      Fun.protect
        ~finally:(fun () -> close_listener_noerr listener)
        (fun () ->
          Printf.eprintf "ash-dbus-proxy: forwarding %s to vsock:%d:%d\n%!" path
            cid port;
          let rec serve () =
            if !stopping then 0
            else
              match Transport.accept listener with
              | accepted ->
                  ignore
                    (Thread.create
                       (fun accepted ->
                         Fun.protect
                           ~finally:(fun () ->
                             close_noerr accepted.Transport.socket)
                           (fun () ->
                             connect_and_relay cid port accepted.socket
                               accepted.socket))
                       accepted);
                  serve ()
              | exception Unix.Unix_error ((Unix.EBADF | Unix.EINTR), _, _)
                when !stopping ->
                  0
              | exception Failure message
                when !stopping && is_stopped_accept_failure message ->
                  0
          in
          serve ())

let socket_path =
  Arg.(required & opt (some string) None & info [ "socket" ] ~docv:"PATH")

let cid = Arg.(value & opt int 2 & info [ "cid" ] ~doc:"Vsock CID." ~docv:"CID")

let port =
  Arg.(value & opt int 0 & info [ "port" ] ~doc:"Vsock port." ~docv:"PORT")

let managed =
  Arg.(
    value & flag & info [ "managed" ] ~doc:"Derive the port from the VM CID.")

let listen_path =
  Arg.(
    value
    & opt (some string) None
    & info [ "listen" ]
        ~doc:"Listen on a guest Unix socket instead of relaying stdin/stdout."
        ~docv:"PATH")

let xdg_dbus_proxy =
  Arg.(
    value
    & opt (some string) None
    & info [ "xdg-dbus-proxy" ] ~doc:"xdg-dbus-proxy executable." ~docv:"PATH")

let host =
  Cmd.v
    (Cmd.info "host" ~doc:"Expose a filtered host notification bus over vsock")
    Term.(const run_host $ socket_path $ cid $ managed $ port $ xdg_dbus_proxy)

let connect =
  Cmd.v
    (Cmd.info "connect" ~doc:"Relay stdin/stdout to a host vsock endpoint")
    Term.(const run_connect $ cid $ managed $ port $ listen_path)

let command =
  Cmd.group
    (Cmd.info "ash-dbus-proxy"
       ~doc:"bridge a filtered D-Bus connection across AF_VSOCK")
    [ host; connect ]

let () =
  try exit (Cmd.eval' command) with
  | Exit -> exit 0
  | exn ->
      Printf.eprintf "ash-dbus-proxy: %s\n%!" (Printexc.to_string exn);
      exit 1
