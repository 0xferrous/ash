open Cmdliner

let run config socket vsock_port log_file =
  try
    let portal = Agent_portal.Config.load ?path:config () in
    let endpoint =
      match (socket, vsock_port) with
      | Some _, Some _ ->
          invalid_arg "--socket and --vsock-port are mutually exclusive"
      | Some path, None -> Agent_portal.Transport.Unix path
      | None, Some port ->
          Agent_portal.Transport.vsock ~cid:portal.vsock_cid ~port
      | None, None -> (
          match portal.transport with
          | Agent_portal.Config.Unix ->
              Agent_portal.Transport.Unix portal.socket_path
          | Agent_portal.Config.Vsock ->
              Agent_portal.Transport.vsock ~cid:portal.vsock_cid
                ~port:portal.vsock_port)
    in
    let log_path =
      Agent_portal.Logging.init ?path:log_file portal.socket_path
    in
    Agent_portal.Logging.info "logging to %s" log_path;
    Agent_portal.Server.run_endpoint portal endpoint;
    0
  with exn ->
    Printf.eprintf "agent-portal-host: %s\n%!" (Printexc.to_string exn);
    1

let config =
  Arg.(
    value
    & opt (some string) None
    & info [ "config"; "c" ] ~doc:"TOML config containing the [portal] section."
        ~docv:"PATH")

let socket =
  Arg.(
    value
    & opt (some string) None
    & info [ "socket" ] ~doc:"Override the portal Unix socket path."
        ~docv:"PATH")

let vsock_port =
  Arg.(
    value
    & opt (some int) None
    & info [ "vsock-port" ] ~doc:"Listen on the AF_VSOCK port." ~docv:"PORT")

let log_file =
  Arg.(
    value
    & opt (some string) None
    & info [ "log-file" ] ~doc:"Override the append-only portal log path."
        ~docv:"PATH")

let command =
  Cmd.v
    (Cmd.info "agent-portal-host"
       ~doc:"mediate guest access to selected host capabilities")
    Term.(const run $ config $ socket $ vsock_port $ log_file)

let () = exit (Cmd.eval' command)
