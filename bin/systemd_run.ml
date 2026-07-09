(* Placeholder for future systemd-run integration.

   This module will eventually own transient unit construction and execution, so
   Virtie.spawn can be run under systemd without leaking systemd-specific details
   into the CLI or manifest generation code. *)

type unit_options = { unit_name : string option; collect : bool }

let default_options = { unit_name = None; collect = true }
let argv _options ~program ~args = program :: args
