(* The executable launch plan for a virtle manifest, as rendered by the
   virtle library FFI (Virtle_ffi.plan), and an OCaml-side executor that runs
   it: prepare directories, spawn host run processes, start QEMU, wait for
   socket readiness, hold until the VM exits, then tear everything down.

   Guest serial output is wired to stderr. Run processes and QEMU inherit
   the current environment (plus per-run additions), matching what virtle's
   Go executor would pass. *)

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
  | `List items -> List.filter_map (function `String s -> Some s | _ -> None) items
  | _ -> []

let string_array = function
  | `List items -> Array.of_list (List.filter_map (function `String s -> Some s | _ -> None) items)
  | _ -> [||]

let field name fields = List.assoc_opt name fields

let of_json json =
  match Yojson.Safe.from_string json with
  | `Assoc fields -> (
      let f name = field name fields in
      let opt_str name =
        match f name with Some (`String s) -> Some s | _ -> None
      in
      let str name =
        match opt_str name with Some s -> s | None -> failwith ("virtle plan missing " ^ name)
      in
      let int_field name =
        match f name with Some (`Int i) -> i | _ -> failwith ("virtle plan missing " ^ name)
      in
      let runs =
        match f "runs" with
        | Some (`List items) ->
            List.map
              (function
                | `Assoc run_fields -> (
                    match (field "exec" run_fields, field "env" run_fields, field "dir" run_fields) with
                    | Some exec, env, Some (`String dir) ->
                        { exec = string_array exec; env = string_array (Option.value ~default:(`List []) env); dir }
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
          (match f "qemuArgv" with Some args -> string_array args | None -> [||]);
        runs;
        virtiofs_sockets =
          (match f "virtiofsSockets" with Some s -> string_list s | None -> []);
        cleanup_files =
          (match f "cleanupFiles" with Some s -> string_list s | None -> []);
        prepare_dirs =
          (match f "prepareDirs" with Some s -> string_list s | None -> []);
      })
  | _ -> failwith "virtle plan is not a JSON object"

(* --- execution --- *)

let ensure_dir dir =
  if not (Sys.file_exists dir) then Unix.mkdir dir 0o755

let spawn ~env ~dir prog args =
  let args = Array.append [| prog |] args in
  let dir =
    if dir = "" then Unix.getcwd ()
    else (
      ensure_dir dir;
      Unix.chdir dir;
      Unix.getcwd ())
  in
  ignore dir;
  Unix.create_process_env prog args env Unix.stdin Unix.stderr Unix.stderr

let spawn_qemu plan =
  Unix.create_process_env plan.qemu_binary
    (Array.append [| plan.qemu_binary |] plan.qemu_argv)
    (Unix.environment ())
    Unix.stdin Unix.stderr Unix.stderr

let alive pid =
  match Unix.waitpid [ Unix.WNOHANG ] pid with
  | 0, _ -> true
  | _, _ -> false

let exited_status = function
  | Unix.WEXITED code -> code
  | Unix.WSIGNALED n -> 128 + n
  | Unix.WSTOPPED n -> 128 + n

let wait_sockets ~stage ~paths ~pids =
  let rec loop () =
    if List.for_all Sys.file_exists paths then ()
    else (
      match List.find_opt (fun pid -> not (alive pid)) pids with
      | Some pid ->
          failwith (Printf.sprintf "%s: watched process exited early (pid %d)" stage pid)
      | None ->
          Unix.sleepf 0.1;
          loop ())
  in
  loop ()

let execute plan =
  try
    (* 1. Prepare runtime directories and clear stale sockets. *)
    List.iter ensure_dir plan.prepare_dirs;
    List.iter (fun f -> try Unix.unlink f with Unix.Unix_error _ -> ()) plan.cleanup_files;
    (* 2. Start host run processes (virtiofsd daemons lower into runs). *)
    let run_pids =
      List.map
        (fun (run : run) ->
          let env = Array.append (Unix.environment ()) run.env in
          spawn ~env ~dir:run.dir run.exec.(0) run.exec)
        plan.runs
    in
    (* 3. Wait for virtiofs daemon sockets. *)
    wait_sockets ~stage:"host startup" ~paths:plan.virtiofs_sockets ~pids:run_pids;
    (* 4. Start QEMU; guest serial output goes to stderr. *)
    let qemu_pid = spawn_qemu plan in
    (* 5. Wait for the QMP socket. *)
    wait_sockets ~stage:"vm startup" ~paths:[ plan.qmp_socket ]
      ~pids:(qemu_pid :: run_pids);
    (* 6. Hold until the VM exits. *)
    let _, status = Unix.waitpid [] qemu_pid in
    let code = exited_status status in
    (* 7. Teardown: terminate the remaining host processes. *)
    List.iter (fun pid -> try Unix.kill pid Sys.sigterm with Unix.Unix_error _ -> ()) run_pids;
    Unix.sleepf 1.0;
    List.iter (fun pid -> try Unix.kill pid Sys.sigkill with Unix.Unix_error _ -> ()) run_pids;
    Ok code
  with
  | Unix.Unix_error (errno, fn, arg) -> Error (Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message errno))
  | Failure message -> Error message
