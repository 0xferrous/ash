type level = Debug | Info | Warn | Error

let debug_enabled = ref (Sys.getenv_opt "ASH_LOG" = Some "debug")
let set_debug enabled = debug_enabled := enabled || !debug_enabled

let color_enabled () =
  Sys.getenv_opt "NO_COLOR" = None
  && Sys.getenv_opt "ASH_COLOR" <> Some "never"
  && (Sys.getenv_opt "ASH_COLOR" = Some "always" || Unix.isatty Unix.stderr)

let level_name = function
  | Debug -> "debug"
  | Info -> "info"
  | Warn -> "warn"
  | Error -> "error"

let level_color = function
  | Debug -> "\027[2;36m"
  | Info -> "\027[32m"
  | Warn -> "\027[33m"
  | Error -> "\027[31m"

let reset = "\027[0m"
let dim = "\027[2m"
let bold = "\027[1m"

let log level message =
  match level with
  | Debug when not !debug_enabled -> ()
  | _ ->
      if color_enabled () then
        Printf.eprintf "%sash%s:%s%s%s: %s\n%!" dim reset (level_color level)
          (level_name level) reset message
      else Printf.eprintf "ash:%s: %s\n%!" (level_name level) message

let debug fmt = Printf.ksprintf (log Debug) fmt
let info fmt = Printf.ksprintf (log Info) fmt
let warn fmt = Printf.ksprintf (log Warn) fmt
let error fmt = Printf.ksprintf (log Error) fmt
