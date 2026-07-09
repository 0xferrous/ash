type level = Debug | Info | Warn | Error

let debug_enabled = ref (Sys.getenv_opt "ASH_LOG" = Some "debug")
let set_debug enabled = debug_enabled := enabled || !debug_enabled

let color_enabled () =
  Sys.getenv_opt "NO_COLOR" = None
  && Sys.getenv_opt "ASH_COLOR" <> Some "never"
  && (Sys.getenv_opt "ASH_COLOR" = Some "always" || Unix.isatty Unix.stderr)

let level_name = function
  | Debug -> "DEBUG"
  | Info -> "INFO"
  | Warn -> "WARN"
  | Error -> "ERROR"

let timestamp () =
  let tm = Unix.localtime (Unix.time ()) in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02d" (tm.tm_year + 1900)
    (tm.tm_mon + 1) tm.tm_mday tm.tm_hour tm.tm_min tm.tm_sec

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
      let timestamp = timestamp () in
      if color_enabled () then
        Printf.eprintf "%s%s%s %sash%s %s%s%s %s\n%!" dim timestamp reset dim
          reset (level_color level) (level_name level) reset message
      else
        Printf.eprintf "%s ash %s %s\n%!" timestamp (level_name level) message

let debug fmt = Printf.ksprintf (log Debug) fmt
let info fmt = Printf.ksprintf (log Info) fmt
let warn fmt = Printf.ksprintf (log Warn) fmt
let error fmt = Printf.ksprintf (log Error) fmt

let fatal ?(code = 1) fmt =
  Printf.ksprintf
    (fun message ->
      log Error message;
      exit code)
    fmt
