(* The executable launch plan for a virtle manifest, as rendered by the
   virtle library FFI (Virtle_ffi.plan), and an OCaml-side executor that runs
   it: prepare directories, spawn host run processes, start QEMU, wait for
   socket readiness, serve a minimal virtle control socket (status and
   guest-exec), hold until the VM exits, then tear everything down.

   Guest serial output is wired to stderr. Run processes and QEMU inherit
   the current environment (plus per-run additions), matching what virtle's
   Go executor would pass.

   The control socket makes a plan-run VM visible to the rest of ash
   (ls/attach/stop/inspect) exactly like a virtle-managed VM: the same
   virtle.sock path is served, with status reporting the allocated CID and
   the SSH readiness timestamp, and guest-exec proxied to the guest agent.
   Spawn waits for readiness and drives guest setup through that socket
   instead of invoking the virtle CLI. *)

type run = { exec : string array; env : string array; dir : string }

type t = {
  cid : int;
  incoming : bool;
  state_dir : string;
  qmp_socket : string;
  guest_agent_socket : string;
  ssh_ready_socket : string;
  qemu_binary : string;
  qemu_argv : string array;
  runs : run list;
  virtiofs_sockets : string list;
  cleanup_files : string list;
  prepare_dirs : string list;
}

let string_list = function
  | `List items ->
      List.filter_map (function `String s -> Some s | _ -> None) items
  | _ -> []

let string_array = function
  | `List items ->
      Array.of_list
        (List.filter_map (function `String s -> Some s | _ -> None) items)
  | _ -> [||]

let field name fields = List.assoc_opt name fields

let of_json json =
  match Yojson.Safe.from_string json with
  | `Assoc fields ->
      let f name = field name fields in
      let opt_str name =
        match f name with Some (`String s) -> Some s | _ -> None
      in
      let str name =
        match opt_str name with
        | Some s -> s
        | None -> failwith ("virtle plan missing " ^ name)
      in
      let int_field name =
        match f name with
        | Some (`Int i) -> i
        | _ -> failwith ("virtle plan missing " ^ name)
      in
      let runs =
        match f "runs" with
        | Some (`List items) ->
            List.map
              (function
                | `Assoc run_fields -> (
                    match
                      ( field "exec" run_fields,
                        field "env" run_fields,
                        field "dir" run_fields )
                    with
                    | Some exec, env, Some (`String dir) ->
                        {
                          exec = string_array exec;
                          env =
                            string_array (Option.value ~default:(`List []) env);
                          dir;
                        }
                    | _ -> failwith "virtle plan run missing exec or dir")
                | _ -> failwith "virtle plan run is not an object")
              items
        | _ -> []
      in
      {
        cid = int_field "cid";
        incoming = (match f "incoming" with Some (`Bool b) -> b | _ -> false);
        state_dir = str "stateDir";
        qmp_socket = str "qmpSocket";
        guest_agent_socket =
          (match opt_str "guestAgentSocket" with Some s -> s | None -> "");
        ssh_ready_socket =
          (match opt_str "sshReadySocket" with Some s -> s | None -> "");
        qemu_binary = str "qemuBinary";
        qemu_argv =
          (match f "qemuArgv" with
          | Some args -> string_array args
          | None -> [||]);
        runs;
        virtiofs_sockets =
          (match f "virtiofsSockets" with
          | Some s -> string_list s
          | None -> []);
        cleanup_files =
          (match f "cleanupFiles" with Some s -> string_list s | None -> []);
        prepare_dirs =
          (match f "prepareDirs" with Some s -> string_list s | None -> []);
      }
  | _ -> failwith "virtle plan is not a JSON object"

(* --- direct guest agent client --- *)

(* A guest-exec result shaped like virtle's control-socket guest-exec
   response, so existing ash parsers (Qga.result) work unchanged. *)
let guest_exec_result_json ~exit_code ~out_data ~err_data =
  let option_json = function Some value -> `String value | None -> `Null in
  Yojson.Safe.to_string
    (`Assoc
       [
         ("exitCode", `Int exit_code);
         ("outData", option_json out_data);
         ("errData", option_json err_data);
       ])

let qga_error_message json =
  match Yojson.Safe.from_string json with
  | `Assoc fields -> (
      match List.assoc_opt "error" fields with
      | Some (`Assoc err) -> (
          match List.assoc_opt "desc" err with
          | Some (`String desc) -> desc
          | _ -> "unknown guest agent error")
      | _ -> "unknown guest agent error")
  | _ -> "malformed guest agent response"

let qga_return json =
  match Yojson.Safe.from_string json with
  | `Assoc fields -> (
      match List.assoc_opt "return" fields with
      | Some value -> Ok value
      | None -> Error (qga_error_message json))
  | _ -> Error "malformed guest agent response"

let qga_rpc ~socket ~cmd ~args =
  let fd = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> try Unix.close fd with Unix.Unix_error _ -> ())
    (fun () ->
      Unix.connect fd (Unix.ADDR_UNIX socket);
      let request =
        Yojson.Safe.to_string
          (`Assoc [ ("execute", `String cmd); ("arguments", args) ])
        ^ "\n"
      in
      ignore (Unix.write_substring fd request 0 (String.length request));
      let buffer = Bytes.create 8192 in
      let rec read acc =
        let n = Unix.read fd buffer 0 (Bytes.length buffer) in
        if n <= 0 then acc
        else
          let chunk = Bytes.sub_string buffer 0 n in
          let acc = acc ^ chunk in
          if String.contains chunk '\n' then acc else read acc
      in
      read "")

(* Run a guest command through the guest agent with output capture, polling
   guest-exec-status until it exits. Returns virtle-shaped guest-exec JSON. *)
let qga_guest_exec ~socket ~path ~args ~timeout_seconds =
  let deadline = Unix.gettimeofday () +. timeout_seconds in
  let rec start () =
    if Unix.gettimeofday () > deadline then
      Error
        (Printf.sprintf "guest-exec %s timed out after %g seconds" path
           timeout_seconds)
    else
      match
        qga_rpc ~socket ~cmd:"guest-exec"
          ~args:
            (`Assoc
               [
                 ("path", `String path);
                 ("arg", `List (List.map (fun arg -> `String arg) args));
                 ("capture-output", `Bool true);
               ])
      with
      | response -> (
          match qga_return response with
          | Error message -> Error message
          | Ok (`Assoc fields) -> (
              match List.assoc_opt "pid" fields with
              | Some (`Int pid) -> poll_status pid
              | _ -> Error "guest-exec did not return a pid")
          | Ok _ -> Error "guest-exec returned an unexpected response")
  and poll_status pid =
    if Unix.gettimeofday () > deadline then
      Error
        (Printf.sprintf "guest-exec %s timed out after %g seconds" path
           timeout_seconds)
    else
      match
        qga_rpc ~socket ~cmd:"guest-exec-status"
          ~args:(`Assoc [ ("pid", `Int pid) ])
      with
      | response -> (
          match qga_return response with
          | Error message -> Error message
          | Ok (`Assoc fields) -> (
              if List.assoc_opt "exited" fields <> Some (`Bool true) then (
                Unix.sleepf 0.25;
                poll_status pid)
              else
                let int_field name =
                  match List.assoc_opt name fields with
                  | Some (`Int i) -> Some i
                  | _ -> None
                in
                let string_field name =
                  match List.assoc_opt name fields with
                  | Some (`String s) -> Some s
                  | _ -> None
                in
                match int_field "exitcode" with
                | Some exit_code ->
                    Ok
                      (guest_exec_result_json ~exit_code
                         ~out_data:(string_field "out-data")
                         ~err_data:(string_field "err-data"))
                | None ->
                    Error
                      (Printf.sprintf "guest-exec pid %d exited without a code"
                         pid))
          | Ok _ -> Error "guest-exec-status returned an unexpected response")
  in
  try start () with
  | Unix.Unix_error (errno, fn, arg) ->
      Error (Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message errno))
  | Failure message -> Error message

(* Ask the guest to power down. The guest often powers off without answering,
   so the request is written and the connection closed without waiting for a
   response; connect failures count as accepted. Callers bound the wait. *)
let qga_guest_shutdown ~socket =
  try
    let fd = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
    Fun.protect
      ~finally:(fun () -> try Unix.close fd with Unix.Unix_error _ -> ())
      (fun () ->
        Unix.connect fd (Unix.ADDR_UNIX socket);
        let request =
          Yojson.Safe.to_string
            (`Assoc
               [
                 ("execute", `String "guest-shutdown"); ("arguments", `Assoc []);
               ])
          ^ "\n"
        in
        ignore (Unix.write_substring fd request 0 (String.length request));
        true)
  with _ -> false

(* --- ssh readiness --- *)

let ssh_ready_token ~socket ~timeout_seconds =
  let deadline = Unix.gettimeofday () +. timeout_seconds in
  let rec wait_for_path () =
    if Unix.gettimeofday () > deadline then
      raise (Failure "timed out waiting for the ssh ready socket")
    else if Sys.file_exists socket then ()
    else (
      Unix.sleepf 0.1;
      wait_for_path ())
  in
  wait_for_path ();
  let fd = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> try Unix.close fd with Unix.Unix_error _ -> ())
    (fun () ->
      let rec connect () =
        if Unix.gettimeofday () > deadline then
          raise (Failure "timed out connecting to the ssh ready socket")
        else
          try Unix.connect fd (Unix.ADDR_UNIX socket)
          with Unix.Unix_error _ ->
            Unix.sleepf 0.1;
            connect ()
      in
      connect ();
      let buffer = Bytes.create 64 in
      let rec read acc =
        if Unix.gettimeofday () > deadline then
          raise (Failure "timed out waiting for the ssh ready token")
        else
          let n = Unix.read fd buffer 0 (Bytes.length buffer) in
          if n <= 0 then
            raise (Failure "ssh ready socket closed before the ready token")
          else
            let acc = acc ^ Bytes.sub_string buffer 0 n in
            if String.trim acc = "SSH-READY" then () else read acc
      in
      read "")

(* --- control socket --- *)

type control_server = { stop : unit -> unit }

let control_socket_path plan = Filename.concat plan.state_dir "virtle.sock"

let format_rfc3339 time =
  let tm = Unix.localtime time in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ" (tm.tm_year + 1900)
    (tm.tm_mon + 1) tm.tm_mday tm.tm_hour tm.tm_min tm.tm_sec

let status_result_json plan ssh_ready =
  let ssh_ready_at =
    match !ssh_ready with
    | Some time -> `String (format_rfc3339 time)
    | None -> `String "0001-01-01T00:00:00Z"
  in
  Yojson.Safe.to_string
    (`Assoc
       [
         ("state", `String "ready");
         ("cid", `Int plan.cid);
         ( "paths",
           `Assoc
             [
               ("controlSocket", `String (control_socket_path plan));
               ("qmpSocket", `String plan.qmp_socket);
               ("guestAgentSocket", `String plan.guest_agent_socket);
               ("sshReadySocket", `String plan.ssh_ready_socket);
             ] );
         ("stats", `Assoc [ ("sshReadyAt", ssh_ready_at) ]);
       ])

let guest_exec_result_from_params plan params =
  let params_fields = match params with `Assoc fields -> fields | _ -> [] in
  let path =
    match List.assoc_opt "path" params_fields with
    | Some (`String s) -> s
    | _ -> ""
  in
  let args =
    match List.assoc_opt "args" params_fields with
    | Some (`List items) ->
        List.filter_map (function `String s -> Some s | _ -> None) items
    | _ -> []
  in
  if path = "" then Error "guest exec path is required"
  else
    qga_guest_exec ~socket:plan.guest_agent_socket ~path ~args
      ~timeout_seconds:120.

let handle_connection plan ssh_ready fd =
  let request =
    let buffer = Bytes.create 4096 in
    let rec read acc =
      let n =
        try Unix.read fd buffer 0 (Bytes.length buffer)
        with Unix.Unix_error _ -> 0
      in
      if n <= 0 then acc
      else
        let chunk = Bytes.sub_string buffer 0 n in
        let acc = acc ^ chunk in
        if String.contains chunk '\n' then acc else read acc
    in
    read ""
  in
  let response =
    try
      match Yojson.Safe.from_string request with
      | `Assoc fields -> (
          let id =
            match List.assoc_opt "id" fields with
            | Some (`Int i) -> `Int i
            | _ -> `Null
          in
          let method_name =
            match List.assoc_opt "method" fields with
            | Some (`String s) -> s
            | _ -> ""
          in
          let params =
            match List.assoc_opt "params" fields with
            | Some params -> params
            | None -> `Assoc []
          in
          let error code message =
            `Assoc
              [
                ("id", id);
                ( "error",
                  `Assoc [ ("code", `Int code); ("message", `String message) ]
                );
              ]
          in
          match method_name with
          | "status" ->
              `Assoc
                [
                  ("id", id);
                  ( "result",
                    Yojson.Safe.from_string (status_result_json plan ssh_ready)
                  );
                ]
          | "guest-exec" -> (
              match guest_exec_result_from_params plan params with
              | Ok result ->
                  `Assoc
                    [ ("id", id); ("result", Yojson.Safe.from_string result) ]
              | Error message -> error 9 message)
          | _ -> error 1 ("unknown method " ^ method_name))
      | _ ->
          `Assoc
            [
              ( "error",
                `Assoc
                  [ ("code", `Int 1); ("message", `String "invalid request") ]
              );
            ]
    with
    | Yojson.Json_error _ | Failure _ ->
        `Assoc
          [
            ( "error",
              `Assoc
                [ ("code", `Int 1); ("message", `String "invalid request") ] );
          ]
    | Unix.Unix_error (errno, fn, arg) ->
        `Assoc
          [
            ( "error",
              `Assoc
                [
                  ("code", `Int 9);
                  ( "message",
                    `String
                      (Printf.sprintf "%s(%s): %s" fn arg
                         (Unix.error_message errno)) );
                ] );
          ]
  in
  let payload = Yojson.Safe.to_string response ^ "\n" in
  try ignore (Unix.write_substring fd payload 0 (String.length payload))
  with Unix.Unix_error _ -> ()

let serve_control_loop plan ssh_ready listener stop_flag () =
  while not !stop_flag do
    match Unix.accept listener with
    | fd, _ -> (
        handle_connection plan ssh_ready fd;
        try Unix.close fd with Unix.Unix_error _ -> ())
    | exception Unix.Unix_error _ -> ()
  done

let start_control_server plan =
  let socket_path = control_socket_path plan in
  if not (Sys.file_exists plan.state_dir) then Unix.mkdir plan.state_dir 0o755;
  (try Unix.unlink socket_path with Unix.Unix_error _ -> ());
  let listener = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Unix.bind listener (Unix.ADDR_UNIX socket_path);
  Unix.listen listener 8;
  (try Unix.chmod socket_path 0o600 with Unix.Unix_error _ -> ());
  let stop_flag = ref false in
  let ssh_ready = ref None in
  if plan.ssh_ready_socket <> "" then
    ignore
      (Thread.create
         (fun () ->
           try
             ssh_ready_token ~socket:plan.ssh_ready_socket ~timeout_seconds:120.;
             ssh_ready := Some (Unix.gettimeofday ())
           with Failure _ -> ())
         ());
  let server_thread =
    Thread.create (serve_control_loop plan ssh_ready listener stop_flag) ()
  in
  ignore server_thread;
  { stop = (fun () -> stop_flag := true) }

(* --- execution --- *)

type session = {
  plan : t;
  qemu_pid : int;
  run_pids : int list;
  control : control_server;
  sigterm : bool ref;
  shutdown_sent : bool ref;
}

let ensure_dir dir = if not (Sys.file_exists dir) then Unix.mkdir dir 0o755

let spawn ~env ~dir prog args =
  (* Fork so the child can chdir to the run directory without changing this
     process's working directory; [args] already includes [prog] as argv[0]. *)
  (if dir <> "" then ensure_dir dir);
  match Unix.fork () with
  | 0 -> (
      try
        if dir <> "" then Unix.chdir dir;
        Unix.execvpe prog args env
      with _ -> exit 127)
  | pid -> pid

let spawn_qemu plan =
  Unix.create_process_env plan.qemu_binary
    (Array.append [| plan.qemu_binary |] plan.qemu_argv)
    (Unix.environment ()) Unix.stdin Unix.stderr Unix.stderr

let alive pid =
  match Unix.waitpid [ Unix.WNOHANG ] pid with 0, _ -> true | _, _ -> false

let exited_status = function
  | Unix.WEXITED code -> code
  | Unix.WSIGNALED n -> 128 + n
  | Unix.WSTOPPED n -> 128 + n

let wait_sockets ~stage ~paths ~pids =
  let rec loop () =
    if List.for_all Sys.file_exists paths then ()
    else
      match List.find_opt (fun pid -> not (alive pid)) pids with
      | Some pid ->
          failwith
            (Printf.sprintf "%s: watched process exited early (pid %d)" stage
               pid)
      | None ->
          Unix.sleepf 0.1;
          loop ()
  in
  loop ()

(* Start the plan: prepare directories, start host run processes, wait for
   virtiofs sockets, start QEMU, wait for the QMP socket, and serve the
   control socket in a background thread. Returns a session; the caller must
   finish it with [wait]. *)
let start plan =
  (* Writes to peer-closed sockets (control clients, QGA) must raise EPIPE
     instead of delivering SIGPIPE, which can deadlock the process. *)
  (try Sys.set_signal Sys.sigpipe Sys.Signal_ignore
   with Invalid_argument _ -> ());
  let cleanup = ref [] in
  let track pid = cleanup := pid :: !cleanup in
  try
    List.iter ensure_dir plan.prepare_dirs;
    List.iter
      (fun f -> try Unix.unlink f with Unix.Unix_error _ -> ())
      plan.cleanup_files;
    let run_pids =
      List.map
        (fun (run : run) ->
          let env = Array.append (Unix.environment ()) run.env in
          let pid = spawn ~env ~dir:run.dir run.exec.(0) run.exec in
          track pid;
          pid)
        plan.runs
    in
    wait_sockets ~stage:"host startup" ~paths:plan.virtiofs_sockets
      ~pids:run_pids;
    let qemu_pid = spawn_qemu plan in
    track qemu_pid;
    wait_sockets ~stage:"vm startup" ~paths:[ plan.qmp_socket ]
      ~pids:(qemu_pid :: run_pids);
    let control = start_control_server plan in
    let sigterm = ref false in
    let shutdown_sent = ref false in
    (try
       Sys.set_signal Sys.sigterm (Sys.Signal_handle (fun _ -> sigterm := true))
     with Invalid_argument _ -> ());
    Ok { plan; qemu_pid; run_pids; control; sigterm; shutdown_sent }
  with
  | Unix.Unix_error (errno, fn, arg) ->
      List.iter
        (fun pid ->
          try Unix.kill pid Sys.sigkill with Unix.Unix_error _ -> ())
        !cleanup;
      Error (Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message errno))
  | Failure message ->
      List.iter
        (fun pid ->
          try Unix.kill pid Sys.sigkill with Unix.Unix_error _ -> ())
        !cleanup;
      Error message

(* Hold until the VM exits: when SIGTERM arrives (e.g. ash stop) or a
   graceful shutdown was requested, ask the guest to power down, wait for
   QEMU to exit, and tear down the remaining host processes and the control
   socket. Falls back to killing QEMU after a timeout. *)
let wait session =
  let deadline = Unix.gettimeofday () +. 30. in
  let rec loop () =
    match Unix.waitpid [ Unix.WNOHANG ] session.qemu_pid with
    | 0, _ ->
        if !(session.sigterm) && not !(session.shutdown_sent) then (
          session.shutdown_sent := true;
          ignore (qga_guest_shutdown ~socket:session.plan.guest_agent_socket));
        (if !(session.shutdown_sent) && Unix.gettimeofday () > deadline then
           try Unix.kill session.qemu_pid Sys.sigkill
           with Unix.Unix_error _ -> ());
        Unix.sleepf 0.1;
        loop ()
    | _, status ->
        let code = exited_status status in
        session.control.stop ();
        List.iter
          (fun pid ->
            try Unix.kill pid Sys.sigterm with Unix.Unix_error _ -> ())
          session.run_pids;
        Unix.sleepf 1.0;
        List.iter
          (fun pid ->
            try Unix.kill pid Sys.sigkill with Unix.Unix_error _ -> ())
          session.run_pids;
        Ok code
  in
  try loop () with
  | Unix.Unix_error (errno, fn, arg) ->
      Error (Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message errno))
  | Failure message -> Error message

(* Gracefully shut the guest down and wait for the VM to exit. *)
let shutdown_and_wait session =
  session.shutdown_sent := true;
  ignore (qga_guest_shutdown ~socket:session.plan.guest_agent_socket);
  wait session

let execute plan =
  match start plan with
  | Error message -> Error message
  | Ok session -> wait session
