type unit_options = { unit_name : string option; collect : bool }

let default_options = { unit_name = None; collect = true }
let unit_name ~name = "ash-" ^ Util.slug name
let service_name ~name = unit_name ~name ^ ".service"

let find_systemd_run () =
  match Util.find_in_path "systemd-run" with
  | Some path -> path
  | None -> Log.fatal ~code:127 "could not find executable %S" "systemd-run"

let find_systemctl () =
  match Util.find_in_path "systemctl" with
  | Some path -> path
  | None -> Log.fatal ~code:127 "could not find executable %S" "systemctl"

let find_journalctl () =
  match Util.find_in_path "journalctl" with
  | Some path -> path
  | None -> Log.fatal ~code:127 "could not find executable %S" "journalctl"

let start_user_unit ~name ~description ~program ~args =
  let systemd_run = find_systemd_run () in
  let unit = unit_name ~name in
  let systemd_args =
    [ "--user"; "--unit"; unit; "--description"; description; "--same-dir" ]
    @ (if default_options.collect then [ "--collect" ] else [])
    @ (program :: args)
  in
  Util.run_foreground systemd_run systemd_args

let stop_user_unit ~name =
  let systemctl = find_systemctl () in
  Util.run_foreground systemctl [ "--user"; "stop"; service_name ~name ]

let journal_timestamp json =
  match Yojson.Safe.Util.member "__REALTIME_TIMESTAMP" json with
  | `String micros -> (
      try
        let seconds = Int64.to_float (Int64.of_string micros) /. 1_000_000.0 in
        let tm = Unix.localtime seconds in
        Printf.sprintf "%04d-%02d-%02d %02d:%02d:%02d" (tm.tm_year + 1900)
          (tm.tm_mon + 1) tm.tm_mday tm.tm_hour tm.tm_min tm.tm_sec
      with Failure _ -> micros)
  | _ -> "unknown time"

let journal_message json =
  match Yojson.Safe.Util.member "MESSAGE" json with
  | `String message -> message
  | message -> Yojson.Safe.to_string message

let print_journal_entry line =
  try
    let json = Yojson.Safe.from_string line in
    let timestamp = journal_timestamp json in
    journal_message json |> String.split_on_char '\n'
    |> List.iter (fun message -> Printf.printf "[%s] %s\n%!" timestamp message)
  with Yojson.Json_error _ -> Printf.printf "%s\n%!" line

let show_user_unit_logs ~name ~follow ~lines =
  let journalctl = find_journalctl () in
  let args =
    [
      "--user";
      "--unit";
      service_name ~name;
      "--invocation=0";
      "--lines=" ^ string_of_int lines;
      "--output=json";
      "--output-fields=__REALTIME_TIMESTAMP,MESSAGE";
    ]
    @ if follow then [ "--follow" ] else []
  in
  let read_fd, write_fd = Unix.pipe () in
  let argv = Array.of_list (journalctl :: args) in
  Log.debug "run logs: %s" (Util.log_command (journalctl :: args));
  let pid =
    try Unix.create_process journalctl argv Unix.stdin write_fd Unix.stderr
    with exn ->
      Unix.close read_fd;
      Unix.close write_fd;
      raise exn
  in
  Unix.close write_fd;
  let input = Unix.in_channel_of_descr read_fd in
  (try
     while true do
       input_line input |> print_journal_entry
     done
   with End_of_file -> close_in input);
  let _, status = Unix.waitpid [] pid in
  let code = Util.process_status_code status in
  if code <> 0 then exit code

let is_user_unit_active ~name =
  match Util.find_in_path "systemctl" with
  | None -> false
  | Some systemctl -> (
      let command =
        String.concat " "
          (List.map Util.shell_quote
             [ systemctl; "--user"; "is-active"; "--quiet"; service_name ~name ])
      in
      try
        ignore (Util.command_output command);
        true
      with Failure _ -> false)

let logs_hint ~name = "ash logs -f " ^ Util.shell_quote name
