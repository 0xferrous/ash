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
(** [of_json json] parses a plan rendered by [Virtle_ffi.plan]. Raises
    [Failure] on malformed input. *)

val execute : t -> (int, string) result
(** [execute plan] runs the plan: prepares directories, starts host run
    processes and QEMU, waits for the virtiofs and QMP sockets (aborting if a
    watched process exits early), holds until the VM exits, then terminates
    the remaining host processes. Returns QEMU's exit code on success. Guest
    serial output goes to stderr; requires qemu-system-* on PATH. *)
