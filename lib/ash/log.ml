type level = Debug | Info | Warn | Error

let level_rank = function Debug -> 0 | Info -> 1 | Warn -> 2 | Error -> 3

let string_of_level = function
  | Debug -> "debug"
  | Info -> "info"
  | Warn -> "warn"
  | Error -> "error"

let level_of_string = function
  | "debug" -> Some Debug
  | "info" -> Some Info
  | "warn" -> Some Warn
  | "error" -> Some Error
  | _ -> None

(* Minimum level that reaches the terminal. Initialized from ASH_LOG_LEVEL so
   child ash processes (the SSH wrapper's internal `ash _log` calls) honor the
   same filter as the parent; `ash run` defaults it to Error. ASH_LOG=debug is
   kept as a legacy alias for ASH_LOG_LEVEL=debug. *)
let min_level =
  ref
    (match Option.bind (Sys.getenv_opt "ASH_LOG_LEVEL") level_of_string with
    | Some level -> level
    | None -> if Sys.getenv_opt "ASH_LOG" = Some "debug" then Debug else Info)

let set_min_level level = min_level := level

(* Apply an explicit --log-level: set the process filter and export it via
   ASH_LOG_LEVEL so child ash processes (the SSH wrapper's `ash _log` calls)
   inherit the same level. *)
let apply_log_level = function
  | Some level ->
      min_level := level;
      Unix.putenv "ASH_LOG_LEVEL" (string_of_level level)
  | None -> ()

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
  if level_rank level >= level_rank !min_level then
    let timestamp = timestamp () in
    if color_enabled () then
      Printf.eprintf "%s%s%s %sash%s %s%s%s %s\n%!" dim timestamp reset dim
        reset (level_color level) (level_name level) reset message
    else Printf.eprintf "%s ash %s %s\n%!" timestamp (level_name level) message

(* Map a level name to a log call; used by the internal `ash _log` command the
   generated SSH wrappers call instead of carrying their own logging. *)
let log_level level message =
  match level_of_string (String.lowercase_ascii level) with
  | Some level -> log level message
  | None -> ()

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
