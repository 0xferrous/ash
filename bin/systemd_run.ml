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

let journalctl_hint ~name =
  "journalctl --user -u " ^ Util.shell_quote (service_name ~name) ^ " -f"
