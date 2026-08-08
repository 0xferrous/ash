(* FFI bindings into virtle's Go library code (manifest and qemu packages),
   loaded from the cgo c-shared shim built by the nix package ash-libvirtle.

   The shim exports an opaque manifest handle, the resolved manifest as JSON,
   and the rendered QEMU argv. Strings and argv arrays returned by the shim
   are malloc'd and must be freed; use [with_manifest] to keep the handle
   lifetime and frees scoped. *)

val version : unit -> string
(** [version ()] returns the shim library version string. *)

type manifest
(** An opaque handle to a parsed and resolved virtle manifest. *)

val parse : string -> (manifest, string) result
(** [parse data] decodes and resolves [data] (TOML or JSON bytes) in-process
    through the virtle library. Returns [Error msg] when the shim library
    cannot be loaded, the manifest is invalid, or resolution fails. *)

val resolved_json : manifest -> (string, string) result
(** [resolved_json m] renders the resolved manifest as JSON. *)

val qemu_argv :
  manifest -> cid:int -> incoming:bool -> (string array, string) result
(** [qemu_argv m ~cid ~incoming] renders the QEMU argv for the manifest with
    the given vsock CID. [incoming] adds "-incoming defer" for state restore. *)

val free : manifest -> unit
(** [free m] releases the manifest handle. Must be called exactly once and
    only after no other call uses [m]. *)

type launch_result = { cid : int; qmp_socket : string }
(** Result of a plan execution: the allocated vsock CID and the QMP socket. *)

val launch :
  manifest -> cid:int -> incoming:bool -> (launch_result, string) result
(** [launch m ~cid ~incoming] executes the manifest's plan to completion:
    prepares runtime directories, starts host run processes and QEMU, waits
    for the QMP socket, holds until the VM exits, then tears everything down.
    [cid] is the vsock CID to use (0 allocates one from the manifest range);
    [incoming] adds "-incoming defer" for state restore. Blocks for the VM's
    lifetime; guest serial output goes to stderr. *)

val with_manifest : string -> (manifest -> 'a) -> ('a, string) result
(** [with_manifest data f] parses [data], applies [f], and always releases the
    handle, returning [f]'s result or the parse error. *)
