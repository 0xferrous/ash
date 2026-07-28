open Cmdliner

let run config socket log_file =
  try
    let portal = Agent_portal.Config.load ?path:config () in
    let socket = Option.value socket ~default:portal.socket_path in
    let log_path = Agent_portal.Logging.init ?path:log_file socket in
    Agent_portal.Logging.info "logging to %s" log_path;
    Agent_portal.Server.run portal socket;
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
    Term.(const run $ config $ socket $ log_file)

let () = exit (Cmd.eval' command)
