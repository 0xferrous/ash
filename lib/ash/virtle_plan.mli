(* The executable launch plan for a virtle manifest and an OCaml-side
   executor. See Virtle_ffi.plan for how the plan is rendered. *)

type run = { exec : string array; env : string array; dir : string }
(** A resolved host run process (e.g. a virtiofsd daemon). *)

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
(** The rendered launch plan: resolved paths, run processes, and the QEMU
    command. *)

val of_json : string -> t
(** [of_json json] parses a plan rendered by [Virtle_ffi.plan]. Raises [Failure]
    on malformed input. *)

type session
(** A running plan: QEMU spawned, control socket served, host run processes
    tracked. Finish it with [wait]. *)

val start : t -> (session, string) result
(** [start plan] runs the plan up to VM launch: prepares directories, starts
    host run processes, waits for the virtiofs sockets, starts QEMU, waits for
    the QMP socket, and serves a minimal virtle control socket (virtle.sock
    under the plan state directory) in a background thread. The control socket
    reports status (CID, SSH readiness) and proxies guest-exec to the guest
    agent, so the VM is visible to the rest of ash. Requires qemu-system-* on
    PATH. *)

val wait : session -> (int, string) result
(** [wait session] holds until QEMU exits, then tears down the remaining host
    processes and stops the control socket, returning QEMU's exit code. On
    SIGTERM (e.g. ash stop), it asks the guest to power down, waits for QEMU to
    exit, and falls back to killing QEMU after a timeout. *)

val shutdown_and_wait : session -> (int, string) result
(** [shutdown_and_wait session] asks the guest to power down through the guest
    agent and then waits for the VM to exit, tearing everything down. Used to
    stop a foreground VM when the attached session ends. *)

val execute : t -> (int, string) result
(** [execute plan] is [start] followed by [wait]: runs the plan to completion.
    Guest serial output goes to stderr. *)

val qga_guest_exec :
  socket:string ->
  path:string ->
  args:string list ->
  timeout_seconds:float ->
  (string, string) result
(** [qga_guest_exec ~socket ~path ~args ~timeout_seconds] runs [path] with
    [args] directly on the guest agent socket with output capture, polling
    guest-exec-status until the process exits. Returns a guest-exec response
    shaped like virtle's control RPC ({exitCode,outData,errData}), so
    existing parsers (Qga.result) accept it. *)

val qga_guest_shutdown : socket:string -> bool
(** [qga_guest_shutdown ~socket] asks the guest to power down and treats a
    missing answer as success (the guest often powers off without replying). *)

val ssh_ready_token : socket:string -> timeout_seconds:float -> unit
(** [ssh_ready_token ~socket ~timeout_seconds] waits for the SSH readiness
    socket and reads the SSH-READY token, raising [Failure] on timeout or a
    stale token. *)
