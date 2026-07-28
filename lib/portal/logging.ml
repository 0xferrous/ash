let mutex = Mutex.create ()
let channel : out_channel option ref = ref None
let visible = ref true

let state_home () =
  match Sys.getenv_opt "XDG_STATE_HOME" with
  | Some path when path <> "" -> path
  | _ -> Filename.concat (Config.home_dir ()) ".local/state"

let default_path socket_path =
  let name = Filename.basename socket_path in
  let stem =
    if Filename.check_suffix name ".sock" then Filename.chop_suffix name ".sock"
    else name
  in
  Filename.concat (state_home ()) ("ash/logs/" ^ stem ^ ".log")

let init ?path ?(stderr = true) socket_path =
  let path = Option.value path ~default:(default_path socket_path) in
  Process.ensure_dir (Filename.dirname path);
  let output =
    open_out_gen [ Open_creat; Open_append; Open_binary ] 0o600 path
  in
  channel := Some output;
  visible := stderr;
  path

let timestamp () =
  let time = Unix.gmtime (Unix.time ()) in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ" (time.tm_year + 1900)
    (time.tm_mon + 1) time.tm_mday time.tm_hour time.tm_min time.tm_sec

let write level message =
  let line = Printf.sprintf "%s %-5s %s\n" (timestamp ()) level message in
  Mutex.lock mutex;
  Fun.protect
    ~finally:(fun () -> Mutex.unlock mutex)
    (fun () ->
      if !visible then (
        output_string stderr line;
        flush stderr);
      Option.iter
        (fun output ->
          output_string output line;
          flush output)
        !channel)

let info format = Printf.ksprintf (write "INFO") format
let warn format = Printf.ksprintf (write "WARN") format
let error format = Printf.ksprintf (write "ERROR") format
