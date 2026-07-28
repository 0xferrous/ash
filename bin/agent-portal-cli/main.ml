open Cmdliner
module Client = Agent_portal.Client
module Protocol = Agent_portal.Protocol

let print_exec result =
  output_string stdout result.Protocol.stdout;
  flush stdout;
  output_string stderr result.stderr;
  flush stderr;
  result.exit_code

let run socket vsock config reason out require_approval command =
  try
    let vsock =
      Option.map
        (fun value ->
          match Agent_portal.Transport.parse_vsock value with
          | Agent_portal.Transport.Vsock { cid; port } -> (cid, port)
          | Agent_portal.Transport.Unix _ -> assert false)
        vsock
    in
    let client = Client.create ?socket ?vsock ?config () in
    match command with
    | `Ping -> (
        match Client.request client Protocol.Ping with
        | Protocol.Pong { now_unix_ms } ->
            Printf.printf "pong %Ld\n" now_unix_ms;
            0
        | _ -> failwith "unexpected response")
    | `Clipboard ->
        let mime, bytes = Client.clipboard_read_image client reason in
        (match out with
        | Some path ->
            let oc = open_out_bin path in
            Fun.protect
              ~finally:(fun () -> close_out oc)
              (fun () -> output_string oc bytes);
            Printf.printf "wrote %d bytes (%s) to %s\n" (String.length bytes)
              mime path
        | None ->
            Printf.printf "received %d bytes (%s)\n" (String.length bytes) mime);
        0
    | `Gh arguments ->
        Client.gh_exec client arguments reason require_approval |> print_exec
    | `Exec (arguments, cwd, environment) -> (
        match
          Client.request client
            (Protocol.Exec
               { argv = arguments; reason; cwd; env = Some environment })
        with
        | Protocol.Exec_result result -> print_exec result
        | _ -> failwith "unexpected response")
  with exn ->
    Printf.eprintf "agent-portal-cli: %s\n%!" (Printexc.to_string exn);
    1

let socket =
  Arg.(
    value
    & opt (some string) None
    & info [ "socket" ] ~doc:"Override the portal socket." ~docv:"PATH")

let vsock =
  Arg.(
    value
    & opt (some string) None
    & info [ "vsock" ] ~doc:"Connect to the AF_VSOCK endpoint CID:PORT."
        ~docv:"CID:PORT")

let config =
  Arg.(
    value
    & opt (some string) None
    & info [ "config"; "c" ] ~doc:"Portal config path." ~docv:"PATH")

let reason =
  Arg.(
    value
    & opt (some string) None
    & info [ "reason" ] ~doc:"Human-readable reason for the request."
        ~docv:"TEXT")

let out =
  Arg.(
    value
    & opt (some string) None
    & info [ "out" ] ~doc:"Write clipboard bytes to PATH." ~docv:"PATH")

let approval =
  Arg.(
    value & flag
    & info [ "require-approval" ]
        ~doc:"Require host approval for this gh.exec request.")

let arguments = Arg.(value & pos_all string [] & info [] ~docv:"ARG")
let cwd = Arg.(value & opt (some string) None & info [ "cwd" ] ~docv:"PATH")

let environment =
  Arg.(value & opt_all string [] & info [ "env" ] ~docv:"NAME=VALUE")

let environment_pairs values =
  List.map
    (fun value ->
      match String.index_opt value '=' with
      | Some index ->
          ( String.sub value 0 index,
            String.sub value (index + 1) (String.length value - index - 1) )
      | None -> invalid_arg ("invalid --env: " ^ value))
    values

let common make term =
  Term.(
    const run $ socket $ vsock $ config $ reason $ out $ approval
    $ (const make $ term))

let ping = Cmd.v (Cmd.info "ping") (common (fun () -> `Ping) Term.(const ()))

let clipboard =
  Cmd.v
    (Cmd.info "clipboard-read-image")
    (common (fun () -> `Clipboard) Term.(const ()))

let gh = Cmd.v (Cmd.info "gh-exec") (common (fun argv -> `Gh argv) arguments)

let exec_arguments =
  Term.(
    const (fun argv cwd env -> ((argv, cwd), env))
    $ arguments $ cwd $ environment)

let exec =
  Cmd.v (Cmd.info "exec")
    (common
       (fun ((argv, cwd), env) -> `Exec (argv, cwd, environment_pairs env))
       exec_arguments)

let command =
  Cmd.group
    (Cmd.info "agent-portal-cli" ~doc:"call the agent host portal")
    [ ping; clipboard; gh; exec ]

let () = exit (Cmd.eval' command)
