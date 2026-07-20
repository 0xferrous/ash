type manifest_inputs = {
  config_path : string;
  flake : string;
  name : string;
  spaces : string list;
  user : string option;
  print_serial : bool;
  mount_cwd : bool;
  ro_store_socket : string option;
  ssh : string option;
  systemd_ssh_proxy : string option;
  registration_path : string option;
  kitty : bool;
  virtiofsd : string;
  virtle : string;
}

type resolved_manifest_inputs = {
  config : Ash_config.config;
  flake : string;
  target : Nix.target;
  boot : Nix.boot;
  name : string;
  spaces : string list;
  user : string option;
  print_serial : bool;
  mount_cwd : bool;
  ro_store_socket : string option;
  ssh : string;
  systemd_ssh_proxy : string;
  kitty : bool;
  virtiofsd : string;
  virtle : string;
}

let find_exe ?hint ?env explicit_path default_name =
  let candidate =
    match explicit_path with
    | Some path -> path
    | None -> (
        match Option.bind env Sys.getenv_opt with
        | Some path when path <> "" -> path
        | _ -> default_name)
  in
  match Util.find_in_path candidate with
  | Some path ->
      Log.debug "executable=%S resolved=%S" candidate path;
      path
  | None ->
      let hint =
        match hint with None -> "" | Some hint -> "\n\nHint: " ^ hint
      in
      Log.fatal ~code:127 "could not find executable %S%s" candidate hint

let find_virtle explicit_path =
  find_exe
    ~hint:"install virtle into PATH, set ASH_VIRTLE, or pass --virtle PATH."
    ~env:"ASH_VIRTLE" explicit_path "virtle"

let find_virtiofsd () =
  find_exe
    ~hint:"install virtiofsd into PATH so virtle can start virtiofs mounts."
    None "virtiofsd"

let find_bindfs () =
  find_exe ~hint:"install bindfs into PATH so ash can create hot mounts." None
    "bindfs"

let find_ssh explicit_path =
  find_exe ~hint:"pass a valid --ssh PATH." explicit_path "ssh"

let find_kitten () =
  find_exe ~hint:"install kitty into PATH so `kitten ssh` is available." None
    "kitten"

let find_systemd_ssh_proxy explicit_path =
  find_exe ~hint:"pass a valid --systemd-ssh-proxy PATH." explicit_path
    "systemd-ssh-proxy"

let parse_memory_mib value =
  let value = String.trim value in
  let len = String.length value in
  if len = 0 then 4096
  else
    let last = value.[len - 1] in
    let number, multiplier =
      match last with
      | 'G' | 'g' -> (String.sub value 0 (len - 1), 1024)
      | 'M' | 'm' -> (String.sub value 0 (len - 1), 1)
      | _ -> (value, 1)
    in
    int_of_float
      (Float.of_string (String.trim number) *. Float.of_int multiplier)

let timestamp () =
  let tm = Unix.localtime (Unix.time ()) in
  Printf.sprintf "%04d%02d%02d%02d%02d%02d" (tm.tm_year + 1900) (tm.tm_mon + 1)
    tm.tm_mday tm.tm_hour tm.tm_min tm.tm_sec

let default_name () =
  let cwd = Sys.getcwd () in
  let base = Filename.basename cwd in
  Util.name_slug (base ^ "-" ^ timestamp ())

let state_base_dir () =
  let base =
    match Sys.getenv_opt "XDG_STATE_HOME" with
    | Some path when path <> "" -> path
    | _ -> Filename.concat (Util.home_dir ()) ".local/state"
  in
  Filename.concat base "ash"

let state_dir name = Filename.concat (state_base_dir ()) (Util.name_slug name)
let virtle_state_dir name = Filename.concat (state_dir name) "virtle_state"
let virtle_state_dir_for_path path = Filename.concat path "virtle_state"
let gcroots_dir ~name = Filename.concat (state_dir name) "gcroots"
let manifest_path ~name = Filename.concat (state_dir name) "virtle.toml"
let ash_config_path ~name = Filename.concat (state_dir name) "ash-state.toml"
let has_saved_ash_config ~name = Sys.file_exists (ash_config_path ~name)

let space_mount_ssh_wrapper_path ~name =
  Filename.concat (state_dir name) "ssh-with-space-mounts"

let space_mount_ssh_wrapper_path_for ~kitty ~name =
  if kitty then Filename.concat (state_dir name) "ssh-with-space-mounts-kitty"
  else space_mount_ssh_wrapper_path ~name

let string_array xs = Otoml.array (List.map Otoml.string xs)

let bool_of_doc doc path =
  match Otoml.find_opt doc Otoml.get_boolean path with
  | Some value -> value
  | None ->
      Log.fatal "ash-state.toml is missing boolean field %s"
        (String.concat "." path)

let string_of_doc doc path =
  match Otoml.find_opt doc Otoml.get_string path with
  | Some value -> value
  | None ->
      Log.fatal "ash-state.toml is missing string field %s"
        (String.concat "." path)

let string_array_of_doc doc path =
  match Otoml.find_opt doc (Otoml.get_array Otoml.get_string) path with
  | Some value -> value
  | None ->
      Log.fatal "ash-state.toml is missing string array field %s"
        (String.concat "." path)

let virtiofs_section ?cache ?(extra_args = []) ~socket ~bin () =
  let args =
    [
      "--socket-path={{.Socket}}";
      "--shared-dir={{.MountSource}}";
      "--tag={{.MountTag}}";
      "--xattr";
    ]
    @ extra_args
    @ match cache with None -> [] | Some cache -> [ "--cache=" ^ cache ]
  in
  Otoml.table
    [
      ("socket", Otoml.string socket);
      ("bin", Otoml.string bin);
      ("args", string_array args);
    ]

let virtiofs_mount ?target ?cache ?extra_args ~tag ~source ~read_only ~socket
    ~bin () =
  let fields =
    [
      ("type", Otoml.string "virtiofs");
      ("tag", Otoml.string tag);
      ("source", Otoml.string source);
      ("read_only", Otoml.boolean read_only);
      ("virtiofs", virtiofs_section ?cache ?extra_args ~socket ~bin ());
    ]
  in
  let fields =
    match target with
    | None -> fields
    | Some target -> ("target", Otoml.string target) :: fields
  in
  Otoml.table (List.rev fields)

let image_mount ~source =
  Otoml.table
    [
      ("type", Otoml.string "image");
      ("source", Otoml.string source);
      ("read_only", Otoml.boolean false);
      ( "image",
        Otoml.table
          [
            ("size", Otoml.integer 16384);
            ("fs", Otoml.string "ext4");
            ("create", Otoml.boolean true);
            ("label", Otoml.string "persist");
          ] );
    ]

let space_mount ~bin (mount : Ash_config.mount) =
  virtiofs_mount ~target:mount.target ~cache:"never" ~tag:mount.tag
    ~source:mount.source ~read_only:mount.read_only
    ~socket:(mount.tag ^ ".sock") ~bin ()

let workspace_mount ~workspace_guest_dir ~workspace_host_dir =
  {
    Ash_config.tag = "workspace";
    source = workspace_host_dir;
    target = workspace_guest_dir;
    read_only = false;
  }

let hotmounts_dir ~name = Filename.concat (state_dir name) "hotmounts"
let hotmounts_guest_dir = "/run/ash/hotmounts"
let hotmount_metadata_dir ~name = Filename.concat (hotmounts_dir ~name) ".ash"
let shares_dir ~name = Filename.concat (state_dir name) "shares"
let shares_ro_dir ~name = Filename.concat (shares_dir ~name) "ro"
let shares_rw_dir ~name = Filename.concat (shares_dir ~name) "rw"
let shares_guest_dir = "/run/ash/shares"

let shares_rw_virtiofs_extra_args () =
  let uid = string_of_int (Unix.getuid ()) in
  let gid = string_of_int (Unix.getgid ()) in
  [
    "--translate-uid=squash-guest:0:" ^ uid ^ ":65536";
    "--translate-uid=squash-host:" ^ uid ^ ":0:1";
    "--translate-gid=squash-guest:0:" ^ gid ^ ":65536";
    "--translate-gid=squash-host:" ^ gid ^ ":0:1";
  ]

let hotmount_slug ~host_dir ~guest_path =
  let digest = Digest.to_hex (Digest.string (host_dir ^ "\000" ^ guest_path)) in
  Util.name_slug (Filename.basename host_dir ^ "-" ^ String.sub digest 0 12)

type hotmount_mode = Read_only | Read_write

let hotmount_mode_of_string = function
  | "ro" -> Read_only
  | "rw" -> Read_write
  | mode -> Log.fatal "unsupported mount mode %S; expected ro or rw" mode

let hotmount_mode_name = function Read_only -> "ro" | Read_write -> "rw"

let mount_action (mount : Ash_config.mount) =
  Qga.mount_virtiofs_action ~name:("ash-mount-" ^ mount.tag) ~tag:mount.tag
    ~target:mount.target ~read_only:mount.read_only

let write_space_mount_ssh_wrapper ?(kitty = false) ~name ~virtle ~manifest_path
    ~registration_path ~ssh_exec mounts =
  let path = space_mount_ssh_wrapper_path_for ~kitty ~name in
  let registration_action =
    Qga.load_nix_registration_action ~name:"ash-load-nix-registration"
      ~registration:registration_path
  in
  let registration_command =
    Printf.sprintf
      {sh|result=$(%s --manifest %s rpc guest-exec %s)
case "$result" in
  *'"exitCode":0'*)
    ash_log INFO %s
    ;;
  *'"exitCode":42'*) ;;
  *)
    ash_log ERROR %s
    printf '%%s\n' "$result" >&2
    exit 1
    ;;
esac|sh}
      (Util.shell_quote virtle)
      (Util.shell_quote manifest_path)
      (Util.shell_quote (Qga.params registration_action))
      (Util.shell_quote "loaded Nix store registration")
      (Util.shell_quote "failed to load Nix store registration")
  in
  let mount_commands =
    mounts
    |> List.map (fun (mount : Ash_config.mount) ->
        let params = Qga.params (mount_action mount) in
        Printf.sprintf
          {sh|result=$(%s --manifest %s rpc guest-exec %s)
case "$result" in
  *'"exitCode":0'*)
    ash_log INFO %s
    ;;
  *'"exitCode":42'*) ;;
  *)
    ash_log ERROR %s
    printf '%%s\n' "$result" >&2
    exit 1
    ;;
esac|sh}
          (Util.shell_quote virtle)
          (Util.shell_quote manifest_path)
          (Util.shell_quote params)
          (Util.shell_quote ("mounted " ^ mount.tag ^ " at " ^ mount.target))
          (Util.shell_quote
             ("failed to mount " ^ mount.tag ^ " at " ^ mount.target)))
    |> String.concat "\n"
  in
  let identity_file = Filename.concat (state_dir name) "id_ed25519" in
  let ssh_command = String.concat " " (List.map Util.shell_quote ssh_exec) in
  let exec_ssh =
    Printf.sprintf
      {sh|if [ -r %s ]; then
  exec %s -i %s -o IdentitiesOnly=yes "$@"
else
  exec %s "$@"
fi|sh}
      (Util.shell_quote identity_file)
      ssh_command
      (Util.shell_quote identity_file)
      ssh_command
  in
  let content =
    Printf.sprintf
      {sh|#!/bin/sh
set -eu

ash_log() {
  level=$1
  shift
  ts=$(/run/current-system/sw/bin/date '+%%Y-%%m-%%dT%%H:%%M:%%S')
  dim= color= reset=
  if [ -z "${NO_COLOR:-}" ] && [ "${ASH_COLOR:-}" != never ]; then
    esc=$(/run/current-system/sw/bin/printf '\033')
    dim="${esc}[2m"
    reset="${esc}[0m"
    case "$level" in
      DEBUG) color="${esc}[2;36m" ;;
      INFO) color="${esc}[32m" ;;
      WARN) color="${esc}[33m" ;;
      ERROR) color="${esc}[31m" ;;
    esac
    printf '%%s%%s%%s %%sash-ssh%%s %%s%%s%%s %%s\n' "$dim" "$ts" "$reset" "$dim" "$reset" "$color" "$level" "$reset" "$*" >&2
  else
    printf '%%s ash-ssh %%s %%s\n' "$ts" "$level" "$*" >&2
  fi
}

# Generated by ash. Prepare the guest before attaching SSH.
%s

%s

%s
|sh}
      registration_command mount_commands exec_ssh
  in
  Util.write_file path content;
  Unix.chmod path 0o755;
  Log.debug "generated SSH space mount wrapper: %s" path;
  path

type vm_status = Running | Stopped

type vm_info = {
  name : string;
  status : vm_status;
  cid : int option;
  disk_bytes : int64;
  apparent_bytes : int64;
  modified : float;
  path : string;
}

let control_socket_path dir = Filename.concat dir "virtle.sock"

let socket_accepts_connection path =
  if not (Sys.file_exists path) then false
  else
    let fd = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
    Fun.protect
      ~finally:(fun () -> Unix.close fd)
      (fun () ->
        try
          Unix.connect fd (Unix.ADDR_UNIX path);
          true
        with Unix.Unix_error _ -> false)

let control_socket_rpc path ~method_name ~params =
  let fd = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> try Unix.close fd with Unix.Unix_error _ -> ())
    (fun () ->
      try
        Unix.connect fd (Unix.ADDR_UNIX path);
        let request =
          Yojson.Safe.to_string
            (`Assoc
               [
                 ("id", `Int 1);
                 ("method", `String method_name);
                 ("params", params);
               ])
          ^ "\n"
        in
        let _ = Unix.write_substring fd request 0 (String.length request) in
        let buffer = Bytes.create 4096 in
        let rec read_response acc =
          let n = Unix.read fd buffer 0 (Bytes.length buffer) in
          if n <= 0 then acc
          else
            let chunk = Bytes.sub_string buffer 0 n in
            let acc = acc ^ chunk in
            if String.contains chunk '\n' then acc else read_response acc
        in
        Some (read_response "")
      with Unix.Unix_error _ | Sys_error _ | Failure _ | Invalid_argument _ ->
        None)

let control_socket_status_cid path =
  Option.bind
    (control_socket_rpc path ~method_name:"status" ~params:(`Assoc []))
    (Qga.int_field ~field:"cid")

let parse_ssh_stats output =
  match String.split_on_char ' ' (String.trim output) with
  | [ connections; ptys ] -> (
      match (int_of_string_opt connections, int_of_string_opt ptys) with
      | Some connections, Some ptys when connections >= 0 && ptys >= 0 ->
          Some (connections, ptys)
      | _ -> None)
  | _ -> None

let control_socket_ssh_stats path =
  let action = Qga.ssh_stats_action in
  let params = Yojson.Safe.from_string (Qga.params action) in
  match control_socket_rpc path ~method_name:"guest-exec" ~params with
  | Some response when Qga.int_field ~field:"exitCode" response = Some 0 ->
      Option.bind (Qga.output_data response) parse_ssh_stats
  | _ -> None

let active_ssh_warning ~name = function
  | Some (connections, ptys) when connections > 0 ->
      Some
        (Printf.sprintf
           "VM %S has %d active SSH connection(s) and %d active PTY(s)" name
           connections ptys)
  | _ -> None

let affirmative_response response =
  match String.lowercase_ascii (String.trim response) with
  | "y" | "yes" -> true
  | _ -> false

let confirm_stop_with_active_ssh ~name ~force stats =
  match active_ssh_warning ~name stats with
  | None -> ()
  | Some warning when force ->
      Log.warn "%s; stopping because --force was passed" warning
  | Some warning ->
      Log.warn "%s" warning;
      if not (Unix.isatty Unix.stdin) then
        Log.fatal
          "refusing to stop VM %S non-interactively; rerun with --force to \
           override"
          name;
      Printf.eprintf "Stop VM %S anyway? [y/N] %!" name;
      let response = try input_line stdin with End_of_file -> "" in
      if not (affirmative_response response) then (
        Log.info "stop cancelled";
        exit 0)

let rec path_size ?(exclude_entry = fun _ -> false) path =
  try
    let stat = Unix.lstat path in
    match stat.st_kind with
    | Unix.S_DIR ->
        Sys.readdir path
        |> Array.fold_left
             (fun total entry ->
               if exclude_entry entry then total
               else
                 Int64.add total
                   (path_size ~exclude_entry (Filename.concat path entry)))
             (Int64.of_int stat.st_size)
    | _ -> Int64.of_int stat.st_size
  with Unix.Unix_error _ | Sys_error _ -> 0L

let first_word value =
  String.trim value |> String.split_on_char ' ' |> List.find_opt (( <> ) "")

let ignored_state_entry = function "hotmounts" | "shares" -> true | _ -> false
let state_path_size path = path_size ~exclude_entry:ignored_state_entry path

let disk_usage path =
  let hotmounts = Filename.concat path "hotmounts" in
  let shares = Filename.concat path "shares" in
  try
    let output =
      Util.command_output
        ("du -sk --exclude=" ^ Util.shell_quote hotmounts ^ " --exclude="
       ^ Util.shell_quote shares ^ " -- " ^ Util.shell_quote path
       ^ " 2>/dev/null")
    in
    let output =
      String.map (function '\t' | '\n' | '\r' -> ' ' | c -> c) output
    in
    match first_word output with
    | Some kib -> Int64.mul (Int64.of_string kib) 1024L
    | None -> state_path_size path
  with Failure _ | Invalid_argument _ -> state_path_size path

let human_size bytes =
  let units = [| "B"; "KiB"; "MiB"; "GiB"; "TiB" |] in
  let value = ref (Int64.to_float bytes) in
  let unit = ref 0 in
  while !value >= 1024. && !unit < Array.length units - 1 do
    value := !value /. 1024.;
    incr unit
  done;
  if !unit = 0 then Printf.sprintf "%.0f %s" !value units.(!unit)
  else Printf.sprintf "%.2f %s" !value units.(!unit)

let format_time seconds =
  let tm = Unix.localtime seconds in
  Printf.sprintf "%04d-%02d-%02d %02d:%02d:%02d" (tm.tm_year + 1900)
    (tm.tm_mon + 1) tm.tm_mday tm.tm_hour tm.tm_min tm.tm_sec

let list_vms () =
  let base = state_base_dir () in
  if not (Sys.file_exists base) then []
  else
    Sys.readdir base |> Array.to_list |> List.sort String.compare
    |> List.filter_map (fun name ->
        let path = Filename.concat base name in
        let manifest = Filename.concat path "virtle.toml" in
        try
          if Sys.is_directory path && Sys.file_exists manifest then
            let stat = Unix.stat path in
            let control_socket =
              control_socket_path (virtle_state_dir_for_path path)
            in
            let status, cid =
              if socket_accepts_connection control_socket then
                (Running, control_socket_status_cid control_socket)
              else (Stopped, None)
            in
            Some
              {
                name;
                status;
                cid;
                disk_bytes = disk_usage path;
                apparent_bytes = state_path_size path;
                modified = stat.st_mtime;
                path;
              }
          else None
        with Unix.Unix_error _ | Sys_error _ -> None)

let status_string = function Running -> "running" | Stopped -> "stopped"
let cid_string = function Some cid -> string_of_int cid | None -> "-"
let count_string = function Some count -> string_of_int count | None -> "-"

let ssh_stats vm =
  match vm.status with
  | Stopped -> (None, None)
  | Running -> (
      match
        control_socket_ssh_stats
          (control_socket_path (virtle_state_dir_for_path vm.path))
      with
      | Some (connections, ptys) -> (Some connections, Some ptys)
      | None -> (None, None))

let print_vm_list () =
  let vms = list_vms () in
  Printf.printf "%-32s %-8s %5s %4s %4s %10s %10s  %-19s %s\n" "NAME" "STATUS"
    "CID" "SSH" "PTY" "DISK" "VIRTUAL" "MODIFIED" "PATH";
  List.iter
    (fun vm ->
      let connections, ptys = ssh_stats vm in
      Printf.printf "%-32s %-8s %5s %4s %4s %10s %10s  %-19s %s\n" vm.name
        (status_string vm.status) (cid_string vm.cid) (count_string connections)
        (count_string ptys) (human_size vm.disk_bytes)
        (human_size vm.apparent_bytes)
        (format_time vm.modified) vm.path)
    vms

let rm_item vm =
  Printf.sprintf "%-32s %-8s %10s  %s" vm.name (status_string vm.status)
    (human_size vm.disk_bytes) vm.path

let attach_item vm =
  Printf.sprintf "%-32s %-8s %5s  %s" vm.name (status_string vm.status)
    (cid_string vm.cid) vm.path

let rm_vms () =
  let vms =
    list_vms () |> List.filter (fun vm -> vm.status = Stopped) |> Array.of_list
  in
  if Array.length vms = 0 then Log.info "no stopped VM states found"
  else
    let items = Array.map rm_item vms in
    let selected =
      Tui.multi_select ~title:"Select VM states to delete"
        ~help:
          "↑/k ↓/j move  space select  a select all/none  enter delete  q \
           cancel"
        ~items
    in
    match selected with
    | [] -> Log.info "no VM states selected"
    | selected ->
        selected
        |> List.iter (fun idx ->
            let vm = vms.(idx) in
            Log.info "deleting VM state %s (%s)" vm.name vm.path;
            Util.remove_tree ~force:true vm.path)

let attach_picker vms =
  let items = Array.map attach_item vms in
  Tui.single_select ~title:"Select VM to attach"
    ~help:"↑/k ↓/j move  enter attach  q cancel" ~items
  |> Option.map (fun idx -> vms.(idx))

let manifest_string doc path =
  match Otoml.find_opt doc Otoml.get_string path with
  | Some value -> value
  | None ->
      Log.fatal "manifest is missing string field %s" (String.concat "." path)

let manifest_string_array doc path =
  match Otoml.find_opt doc (Otoml.get_array Otoml.get_string) path with
  | Some value -> value
  | None ->
      Log.fatal "manifest is missing string array field %s"
        (String.concat "." path)

let manifest_bool_opt doc path = Otoml.find_opt doc Otoml.get_boolean path

let load_manifest_doc path =
  try
    In_channel.with_open_text path (fun ic ->
        match Otoml.Parser.from_string_result (In_channel.input_all ic) with
        | Ok doc -> doc
        | Error err -> Log.fatal "could not parse manifest %S: %s" path err)
  with Sys_error err -> Log.fatal "could not read manifest %S: %s" path err

let select_attach_vm name =
  match name with
  | Some name ->
      let name = Util.name_slug name in
      let path = manifest_path ~name in
      if not (Sys.file_exists path) then
        Log.fatal "no VM named %S (expected %s)" name path;
      if
        not
          (socket_accepts_connection
             (control_socket_path (virtle_state_dir name)))
      then Log.fatal "VM %S is not running" name;
      (name, path)
  | None -> (
      match List.filter (fun vm -> vm.status = Running) (list_vms ()) with
      | [ vm ] -> (vm.name, Filename.concat vm.path "virtle.toml")
      | [] -> Log.fatal "no running VMs; use `ash ls` to list states"
      | vms -> (
          match attach_picker (Array.of_list vms) with
          | Some vm -> (vm.name, Filename.concat vm.path "virtle.toml")
          | None ->
              Log.info "attach cancelled";
              exit 0))

let virtle_rpc ?(debug = true) ~virtle ~path ~method_name ?params () =
  let args = [ virtle; "--manifest"; path; "rpc"; method_name ] in
  let args =
    match params with Some params -> args @ [ params ] | None -> args
  in
  Util.command_output ~debug
    (String.concat " " (List.map Util.shell_quote args))

let rpc_status ?(debug = true) ~virtle ~path () =
  virtle_rpc ~debug ~virtle ~path ~method_name:"status" ()

let contains_substring text needle =
  let text_len = String.length text in
  let needle_len = String.length needle in
  if needle_len = 0 then true
  else if needle_len > text_len then false
  else
    let rec loop i =
      if i + needle_len > text_len then false
      else if String.sub text i needle_len = needle then true
      else loop (i + 1)
    in
    loop 0

let wait_for_ssh_ready ~virtle ~path ~name =
  let deadline = Unix.gettimeofday () +. 120. in
  let rec loop () =
    if Unix.gettimeofday () > deadline then
      Log.fatal "timed out waiting for VM %S SSH readiness" name;
    try
      let status = rpc_status ~debug:false ~virtle ~path () in
      if
        contains_substring status "\"sshReadyAt\""
        && not
             (contains_substring status
                "\"sshReadyAt\":\"0001-01-01T00:00:00Z\"")
      then ()
      else (
        Unix.sleepf 0.25;
        loop ())
    with Failure _ ->
      Unix.sleepf 0.25;
      loop ()
  in
  loop ()

let space_mounts_for_inputs inputs =
  let config = Ash_config.load_for_spaces inputs.config_path inputs.spaces in
  let user =
    manifest_string
      (load_manifest_doc (manifest_path ~name:inputs.name))
      [ "ssh"; "user" ]
  in
  let resources =
    Ash_config.resources_for_spaces ~guest_user:user config inputs.spaces
  in
  let workspace_mount =
    workspace_mount
      ~workspace_guest_dir:
        (Filename.concat (Ash_config.guest_home user) "workspace")
      ~workspace_host_dir:(Filename.concat (state_dir inputs.name) "workspace")
  in
  workspace_mount :: resources.mounts

let execute_nix_registration ~virtle ~path registration =
  let action =
    Qga.load_nix_registration_action ~name:"ash-load-nix-registration"
      ~registration
  in
  let output =
    virtle_rpc ~virtle ~path ~method_name:"guest-exec"
      ~params:(Qga.params action) ()
  in
  match (Qga.result action output).exit_code with
  | Some 0 -> Log.info "loaded Nix store registration"
  | Some 42 -> ()
  | _ ->
      let captured = Qga.captured_output output in
      Log.fatal "failed to load Nix store registration: %s%s" output
        (match captured with
        | None -> ""
        | Some decoded -> "\ndecoded guest output:\n" ^ decoded)

let execute_space_mounts ~virtle ~path mounts =
  List.iter
    (fun (mount : Ash_config.mount) ->
      let action = mount_action mount in
      let output =
        virtle_rpc ~virtle ~path ~method_name:"guest-exec"
          ~params:(Qga.params action) ()
      in
      match (Qga.result action output).exit_code with
      | Some 0 -> Log.info "mounted %s at %s" mount.tag mount.target
      | Some 42 -> ()
      | _ ->
          Log.fatal "failed to mount %s at %s: %s" mount.tag mount.target output)
    mounts

let bindfs_args_for_mode mode =
  let mode_args = match mode with Read_only -> [ "-r" ] | Read_write -> [] in
  [
    "--multithreaded";
    "--no-allow-other";
    "-o";
    "attr_timeout=0,entry_timeout=0,negative_timeout=0";
  ]
  @ mode_args

let try_ensure_bindfs_mount ~bindfs ~mode ~source ~target =
  Util.ensure_dir target;
  let bindfs_args = bindfs_args_for_mode mode in
  let bindfs_command =
    String.concat " "
      ([ Util.shell_quote bindfs ]
      @ List.map Util.shell_quote bindfs_args
      @ [ Util.shell_quote source; Util.shell_quote target ])
  in
  let bind_mount_command =
    String.concat " "
      [
        "mount";
        "--bind";
        "--";
        Util.shell_quote source;
        Util.shell_quote target;
      ]
  in
  let bind_mount_command =
    match mode with
    | Read_write -> bind_mount_command
    | Read_only ->
        bind_mount_command ^ " && mount -o remount,bind,ro -- "
        ^ Util.shell_quote target
  in
  let command =
    Printf.sprintf
      {sh|set -u
if mountpoint -q -- %s; then exit 0; fi
bindfs_err=$(mktemp)
if %s 2>"$bindfs_err"; then
  rm -f "$bindfs_err"
  exit 0
else
  bindfs_status=$?
fi

if [ "$(id -u)" != 0 ]; then
  printf '%%s\n' 'ash: bindfs failed; kernel mount --bind fallback requires root' >&2
  cat "$bindfs_err" >&2
  rm -f "$bindfs_err"
  exit "$bindfs_status"
fi

printf '%%s\n' 'ash: bindfs failed; trying kernel mount --bind fallback' >&2
cat "$bindfs_err" >&2
rm -f "$bindfs_err"
if %s; then
  exit 0
fi
exit "$bindfs_status"
|sh}
      (Util.shell_quote target) bindfs_command bind_mount_command
  in
  Util.run_foreground "/bin/sh" [ "-c"; command ] = 0

let ensure_bindfs_mount ~bindfs ~mode ~source ~target =
  if not (try_ensure_bindfs_mount ~bindfs ~mode ~source ~target) then
    Log.fatal "failed to mount host directory %S at hotmount staging path %S"
      source target

let split_hotmount_spec spec =
  match String.index_opt spec ':' with
  | None -> (spec, None)
  | Some idx ->
      let host_path = String.sub spec 0 idx in
      let guest_len = String.length spec - idx - 1 in
      let guest_path = String.sub spec (idx + 1) guest_len in
      (host_path, Util.some_if (guest_path <> "") guest_path)

let guest_home user = if user = "root" then "/root" else "/home/" ^ user

let metadata_path ~name ~source_name =
  Filename.concat (hotmount_metadata_dir ~name) (source_name ^ ".meta")

type hotmount_metadata = {
  guest_path : string;
  host_dir : string;
  mode : hotmount_mode;
  source_name : string;
  path : string;
}

let hotmount_metadata_content metadata =
  String.concat "\n"
    [
      metadata.guest_path;
      metadata.host_dir;
      hotmount_mode_name metadata.mode;
      metadata.source_name;
      "";
    ]

let write_hotmount_metadata_record metadata =
  Util.atomic_write_file metadata.path (hotmount_metadata_content metadata)

let hotmount_metadata ~name ~source_name ~host_dir ~guest_path ~mode =
  {
    guest_path;
    host_dir;
    mode;
    source_name;
    path = metadata_path ~name ~source_name;
  }

let read_hotmount_metadata path =
  try
    let lines =
      In_channel.with_open_text path In_channel.input_all
      |> String.split_on_char '\n'
    in
    match lines with
    | guest_path :: host_dir :: mode_name :: source_name :: _ ->
        let mode =
          match mode_name with
          | "ro" -> Ok Read_only
          | "rw" -> Ok Read_write
          | _ -> Error (Printf.sprintf "invalid mode %S" mode_name)
        in
        Result.bind mode (fun mode ->
            let file_source_name =
              Filename.basename path |> Filename.remove_extension
            in
            if guest_path = "" || Filename.is_relative guest_path then
              Error "guest path is not absolute"
            else if host_dir = "" || Filename.is_relative host_dir then
              Error "host directory is not absolute"
            else if source_name = "" || source_name <> file_source_name then
              Error "source name does not match metadata filename"
            else if source_name <> hotmount_slug ~host_dir ~guest_path then
              Error "source name does not match host and guest paths"
            else Ok { guest_path; host_dir; mode; source_name; path })
    | _ -> Error "expected four metadata lines"
  with Sys_error err -> Error err

type hotmounts_read = {
  mounts : hotmount_metadata list;
  invalid : (string * string) list;
}

(* Read the complete persistent hotmount inventory without performing mounts or
   logging. Callers such as startup reconciliation and a future inspect command
   can decide how to present malformed records. *)
let read_hotmounts ~name =
  let dir = hotmount_metadata_dir ~name in
  if not (Sys.file_exists dir) then { mounts = []; invalid = [] }
  else
    Sys.readdir dir |> Array.to_list |> List.sort String.compare
    |> List.filter (fun entry -> Filename.check_suffix entry ".meta")
    |> List.fold_left
         (fun state entry ->
           let path = Filename.concat dir entry in
           match read_hotmount_metadata path with
           | Ok metadata -> { state with mounts = metadata :: state.mounts }
           | Error err -> { state with invalid = (path, err) :: state.invalid })
         { mounts = []; invalid = [] }
    |> fun state ->
    { mounts = List.rev state.mounts; invalid = List.rev state.invalid }

let log_invalid_hotmount_metadata invalid =
  List.iter
    (fun (path, err) ->
      Log.warn "ignoring invalid hotmount metadata %s: %s" path err)
    invalid

let rec toml_to_json = function
  | Otoml.TomlString value -> `String value
  | Otoml.TomlInteger value -> `Int value
  | Otoml.TomlFloat value when Float.is_finite value -> `Float value
  | Otoml.TomlFloat value -> `String (string_of_float value)
  | Otoml.TomlBoolean value -> `Bool value
  | Otoml.TomlOffsetDateTime value
  | Otoml.TomlLocalDateTime value
  | Otoml.TomlLocalDate value
  | Otoml.TomlLocalTime value ->
      `String value
  | Otoml.TomlArray values | Otoml.TomlTableArray values ->
      `List (List.map toml_to_json values)
  | Otoml.TomlTable fields | Otoml.TomlInlineTable fields ->
      `Assoc (List.map (fun (key, value) -> (key, toml_to_json value)) fields)

let inspect_toml_file path =
  if not (Sys.file_exists path) then
    `Assoc
      [ ("path", `String path); ("exists", `Bool false); ("config", `Null) ]
  else
    try
      let text = In_channel.with_open_text path In_channel.input_all in
      match Otoml.Parser.from_string_result text with
      | Ok doc ->
          `Assoc
            [
              ("path", `String path);
              ("exists", `Bool true);
              ("config", toml_to_json doc);
            ]
      | Error err ->
          `Assoc
            [
              ("path", `String path);
              ("exists", `Bool true);
              ("config", `Null);
              ("error", `String err);
            ]
    with Sys_error err ->
      `Assoc
        [
          ("path", `String path);
          ("exists", `Bool true);
          ("config", `Null);
          ("error", `String err);
        ]

let inspect_ash_config ~name =
  let ash_path = ash_config_path ~name in
  if not (Sys.file_exists ash_path) then `Null
  else
    try
      let text = In_channel.with_open_text ash_path In_channel.input_all in
      match Otoml.Parser.from_string_result text with
      | Error _ -> `Null
      | Ok doc -> (
          match
            Otoml.find_opt doc Otoml.get_string [ "spawn"; "config_path" ]
          with
          | Some path -> inspect_toml_file (Util.expand_home path)
          | None -> `Null)
    with Sys_error _ -> `Null

let json_int64 value = `Intlit (Int64.to_string value)

let file_kind path =
  try
    match (Unix.lstat path).st_kind with
    | Unix.S_REG -> Some "file"
    | Unix.S_DIR -> Some "directory"
    | Unix.S_CHR -> Some "character-device"
    | Unix.S_BLK -> Some "block-device"
    | Unix.S_LNK -> Some "symlink"
    | Unix.S_FIFO -> Some "fifo"
    | Unix.S_SOCK -> Some "socket"
  with Unix.Unix_error _ | Sys_error _ -> None

let inspect_path path =
  let exists = Sys.file_exists path in
  let details =
    try
      let stat = Unix.stat path in
      [
        ("sizeBytes", json_int64 (Int64.of_int stat.st_size));
        ("modified", `String (format_time stat.st_mtime));
        ("modifiedUnix", `Float stat.st_mtime);
      ]
    with Unix.Unix_error _ | Sys_error _ -> []
  in
  `Assoc
    ([
       ("path", `String path);
       ("exists", `Bool exists);
       ( "kind",
         match file_kind path with Some kind -> `String kind | None -> `Null );
     ]
    @ details)

let host_mountpoint_state path =
  match Util.find_in_path "mountpoint" with
  | None -> `Null
  | Some mountpoint ->
      `Bool (Util.run_foreground mountpoint [ "-q"; "--"; path ] = 0)

let hotmount_inspect_json ~name metadata =
  let staging_path =
    Filename.concat (hotmounts_dir ~name) metadata.source_name
  in
  `Assoc
    [
      ("guestPath", `String metadata.guest_path);
      ("hostPath", `String metadata.host_dir);
      ("mode", `String (hotmount_mode_name metadata.mode));
      ("sourceName", `String metadata.source_name);
      ("metadataPath", `String metadata.path);
      ("hostExists", `Bool (Sys.file_exists metadata.host_dir));
      ( "hostKind",
        match file_kind metadata.host_dir with
        | Some kind -> `String kind
        | None -> `Null );
      ("stagingPath", `String staging_path);
      ("stagingExists", `Bool (Sys.file_exists staging_path));
      ("stagingMounted", host_mountpoint_state staging_path);
    ]

let parse_json_or_string text =
  try Yojson.Safe.from_string text with Yojson.Json_error _ -> `String text

let guest_mounts_from_control_socket path =
  let action =
    Qga.shell_action ~name:"ash-inspect-mounts"
      "PATH=/run/current-system/sw/bin:/bin\ncat /proc/self/mountinfo"
  in
  let params = Yojson.Safe.from_string (Qga.params action) in
  match control_socket_rpc path ~method_name:"guest-exec" ~params with
  | Some response when Qga.int_field ~field:"exitCode" response = Some 0 -> (
      match Qga.output_data response with
      | Some output ->
          output |> String.split_on_char '\n'
          |> List.filter (fun line -> line <> "")
          |> List.map (fun line -> `String line)
          |> fun lines -> `List lines
      | None -> `Null)
  | _ -> `Null

let inspect_runtime_json (vm : vm_info) =
  let socket_path = control_socket_path (virtle_state_dir_for_path vm.path) in
  match vm.status with
  | Stopped ->
      `Assoc
        [
          ("running", `Bool false);
          ("controlSocket", `String socket_path);
          ("cid", `Null);
          ("sshConnections", `Null);
          ("sshPtys", `Null);
          ("status", `Null);
          ("guestMountInfo", `Null);
        ]
  | Running ->
      let connections, ptys = ssh_stats vm in
      let option_int = function Some value -> `Int value | None -> `Null in
      let status =
        match
          control_socket_rpc socket_path ~method_name:"status"
            ~params:(`Assoc [])
        with
        | Some response -> parse_json_or_string response
        | None -> `Null
      in
      `Assoc
        [
          ("running", `Bool true);
          ("controlSocket", `String socket_path);
          ("cid", option_int vm.cid);
          ("sshConnections", option_int connections);
          ("sshPtys", option_int ptys);
          ("status", status);
          ("guestMountInfo", guest_mounts_from_control_socket socket_path);
        ]

let find_inspect_vm ~name =
  let name = Util.name_slug name in
  match List.find_opt (fun vm -> vm.name = name) (list_vms ()) with
  | Some vm -> vm
  | None -> Log.fatal "no VM named %S (expected %s)" name (manifest_path ~name)

let inspect_vm_json ~name =
  let vm = find_inspect_vm ~name in
  let name = vm.name in
  let hotmounts = read_hotmounts ~name in
  let invalid_hotmounts =
    List.map
      (fun (path, error) ->
        `Assoc [ ("path", `String path); ("error", `String error) ])
      hotmounts.invalid
  in
  `Assoc
    [
      ("name", `String vm.name);
      ("status", `String (status_string vm.status));
      ( "state",
        `Assoc
          [
            ("directory", `String vm.path);
            ("modified", `String (format_time vm.modified));
            ("modifiedUnix", `Float vm.modified);
            ("diskBytes", json_int64 vm.disk_bytes);
            ("apparentBytes", json_int64 vm.apparent_bytes);
            ( "persistImage",
              inspect_path (Filename.concat vm.path "persist.img") );
            ("workspace", inspect_path (Filename.concat vm.path "workspace"));
          ] );
      ("runtime", inspect_runtime_json vm);
      ("ash", inspect_toml_file (ash_config_path ~name));
      ("config", inspect_ash_config ~name);
      ("virtle", inspect_toml_file (manifest_path ~name));
      ( "hotmounts",
        `Assoc
          [
            ("directory", `String (hotmounts_dir ~name));
            ("metadataDirectory", `String (hotmount_metadata_dir ~name));
            ( "mounts",
              `List (List.map (hotmount_inspect_json ~name) hotmounts.mounts) );
            ("invalid", `List invalid_hotmounts);
          ] );
    ]

let read_toml_for_inspect path =
  try
    let text = In_channel.with_open_text path In_channel.input_all in
    match Otoml.Parser.from_string_result text with
    | Ok doc -> Some doc
    | Error err ->
        Log.warn "could not parse %s: %s" path err;
        None
  with Sys_error err ->
    Log.warn "could not read %s: %s" path err;
    None

let inspect_print_field label value =
  Printf.printf "  %-16s %s\n" (label ^ ":") value

let inspect_optional_field label = function
  | Some value -> inspect_print_field label value
  | None -> ()

let inspect_string doc path = Otoml.find_opt doc Otoml.get_string path
let inspect_int doc path = Otoml.find_opt doc Otoml.get_integer path
let inspect_bool doc path = Otoml.find_opt doc Otoml.get_boolean path

let inspect_strings doc path =
  Otoml.find_opt doc (Otoml.get_array Otoml.get_string) path

let inspect_tables doc path =
  match Otoml.find_opt doc Otoml.get_value path with
  | Some (Otoml.TomlTableArray values) ->
      List.filter_map
        (function Otoml.TomlTable fields -> Some fields | _ -> None)
        values
  | _ -> []

let inspect_table_string fields key =
  match List.assoc_opt key fields with
  | Some (Otoml.TomlString value) -> Some value
  | _ -> None

let inspect_table_bool fields key =
  match List.assoc_opt key fields with
  | Some (Otoml.TomlBoolean value) -> Some value
  | _ -> None

let configured_mount_target fields =
  match inspect_table_string fields "target" with
  | Some target -> Some target
  | None -> (
      match inspect_table_string fields "tag" with
      | Some "hotmounts" -> Some hotmounts_guest_dir
      | Some "shares-ro" -> Some (Filename.concat shares_guest_dir "ro")
      | Some "shares-rw" -> Some (Filename.concat shares_guest_dir "rw")
      | Some "ro-store" -> Some "/nix/store"
      | Some "workspace_cwd" -> Some "/mnt/cwd"
      | _ -> None)

let print_configured_mount fields =
  let mount_type =
    inspect_table_string fields "type" |> Option.value ~default:"unknown"
  in
  let source =
    inspect_table_string fields "source" |> Option.value ~default:"?"
  in
  let target = configured_mount_target fields in
  let tag = inspect_table_string fields "tag" in
  let read_only =
    inspect_table_bool fields "read_only" |> Option.value ~default:false
  in
  let name =
    match tag with
    | Some tag -> tag
    | None -> (
        match List.assoc_opt "image" fields with
        | Some (Otoml.TomlTable image) ->
            inspect_table_string image "label"
            |> Option.value ~default:mount_type
        | _ -> mount_type)
  in
  let destination =
    match target with Some target -> " -> " ^ target | None -> ""
  in
  Printf.printf "  - %s [%s,%s] %s%s\n" name mount_type
    (if read_only then "ro" else "rw")
    source destination

let print_write_file fields =
  let source =
    inspect_table_string fields "source" |> Option.value ~default:"?"
  in
  let guest_path =
    inspect_table_string fields "guest_path" |> Option.value ~default:"?"
  in
  Printf.printf "  - %s -> %s\n" source guest_path

let inspect_vm_human ~name =
  let vm = find_inspect_vm ~name in
  let name = vm.name in
  let connections, ptys = ssh_stats vm in
  Printf.printf "%s\n" vm.name;
  inspect_print_field "Status" (status_string vm.status);
  inspect_optional_field "CID" (Option.map string_of_int vm.cid);
  inspect_optional_field "SSH connections"
    (Option.map string_of_int connections);
  inspect_optional_field "SSH PTYs" (Option.map string_of_int ptys);
  Printf.printf "\nState\n";
  inspect_print_field "Directory" vm.path;
  inspect_print_field "Disk" (human_size vm.disk_bytes);
  inspect_print_field "Virtual size" (human_size vm.apparent_bytes);
  inspect_print_field "Modified" (format_time vm.modified);
  let persist = Filename.concat vm.path "persist.img" in
  if Sys.file_exists persist then
    inspect_print_field "Persist image" (human_size (state_path_size persist));
  Printf.printf "\nConfiguration\n";
  (match read_toml_for_inspect (ash_config_path ~name) with
  | None -> ()
  | Some ash ->
      inspect_optional_field "Flake" (inspect_string ash [ "spawn"; "flake" ]);
      inspect_optional_field "Ash config"
        (inspect_string ash [ "spawn"; "config_path" ]
        |> Option.map Util.expand_home);
      (match inspect_strings ash [ "spawn"; "spaces" ] with
      | Some [] -> inspect_print_field "Spaces" "(none)"
      | Some spaces -> inspect_print_field "Spaces" (String.concat ", " spaces)
      | None -> ());
      inspect_optional_field "Requested user"
        (inspect_string ash [ "spawn"; "user" ]));
  let manifest = read_toml_for_inspect (manifest_path ~name) in
  (match manifest with
  | None -> ()
  | Some manifest -> (
      inspect_optional_field "Host name"
        (inspect_string manifest [ "host_name" ]);
      inspect_optional_field "SSH user"
        (inspect_string manifest [ "ssh"; "user" ]);
      inspect_optional_field "Memory"
        (inspect_int manifest [ "machine"; "memory" ]
        |> Option.map (fun mib -> Printf.sprintf "%d MiB" mib));
      inspect_optional_field "vCPUs"
        (inspect_int manifest [ "machine"; "vcpu" ] |> Option.map string_of_int);
      inspect_optional_field "Kernel"
        (inspect_string manifest [ "kernel"; "path" ]);
      inspect_optional_field "Initrd"
        (inspect_string manifest [ "kernel"; "initrd_path" ]);
      inspect_optional_field "Workspace host"
        (inspect_string manifest [ "workspace"; "host_dir" ]);
      inspect_optional_field "Workspace guest"
        (inspect_string manifest [ "workspace"; "guest_dir" ]);
      match inspect_bool manifest [ "workspace"; "mount_cwd" ] with
      | Some value -> inspect_print_field "Mount cwd" (string_of_bool value)
      | None -> ()));
  let mounts =
    match manifest with
    | None -> []
    | Some doc -> inspect_tables doc [ "mounts" ]
  in
  Printf.printf "\nConfigured mounts (%d)\n" (List.length mounts);
  List.iter print_configured_mount mounts;
  let write_files =
    match manifest with
    | None -> []
    | Some doc -> inspect_tables doc [ "write_files" ]
  in
  if write_files <> [] then (
    Printf.printf "\nConfigured files (%d)\n" (List.length write_files);
    List.iter print_write_file write_files);
  let hotmounts = read_hotmounts ~name in
  Printf.printf "\nHotmounts (%d)\n" (List.length hotmounts.mounts);
  List.iter
    (fun metadata ->
      let staging =
        Filename.concat (hotmounts_dir ~name) metadata.source_name
      in
      let annotations =
        [
          (if Sys.file_exists metadata.host_dir then None
           else Some "host missing");
          (match host_mountpoint_state staging with
          | `Bool true -> Some "staged"
          | _ -> None);
        ]
        |> List.filter_map Fun.id
      in
      let suffix =
        match annotations with
        | [] -> ""
        | values -> " [" ^ String.concat ", " values ^ "]"
      in
      Printf.printf "  - %s -> %s (%s)%s\n" metadata.host_dir
        metadata.guest_path
        (hotmount_mode_name metadata.mode)
        suffix)
    hotmounts.mounts;
  List.iter
    (fun (path, error) -> Printf.printf "  ! invalid %s: %s\n" path error)
    hotmounts.invalid;
  flush stdout

let inspect_vm ~json ~name =
  if json then (
    inspect_vm_json ~name |> Yojson.Safe.pretty_to_channel stdout;
    output_char stdout '\n';
    flush stdout)
  else inspect_vm_human ~name

let find_hotmount_metadata_by_guest_path ~name ~guest_path =
  let state = read_hotmounts ~name in
  log_invalid_hotmount_metadata state.invalid;
  List.find_opt (fun metadata -> metadata.guest_path = guest_path) state.mounts

let with_hotmount_lock ~name f =
  let dir = hotmount_metadata_dir ~name in
  Util.ensure_dir dir;
  let path = Filename.concat dir "lock" in
  let fd = Unix.openfile path [ Unix.O_CREAT; Unix.O_RDWR ] 0o600 in
  Fun.protect
    ~finally:(fun () -> Unix.close fd)
    (fun () ->
      Unix.lockf fd Unix.F_LOCK 0;
      f ())

let resolve_hotmount_guest_path ~user ~host_dir = function
  | None -> host_dir
  | Some "~" -> guest_home user
  | Some path when String.length path >= 2 && String.sub path 0 2 = "~/" ->
      Filename.concat (guest_home user)
        (String.sub path 2 (String.length path - 2))
  | Some path when Filename.is_relative path ->
      Log.fatal "guest mount path %S must be absolute or start with ~" path
  | Some path -> path

let normalize_hotmount_host_dir host_dir =
  let host_dir = Util.absolute_path host_dir in
  if not (Sys.file_exists host_dir) then
    Log.fatal "host directory %S does not exist" host_dir;
  if (Unix.stat host_dir).st_kind <> Unix.S_DIR then
    Log.fatal "host path %S is not a directory" host_dir;
  let components = String.split_on_char '/' host_dir in
  let path_of_reversed components =
    "/" ^ String.concat "/" (List.rev components)
  in
  let rec normalize reversed = function
    | [] -> path_of_reversed reversed
    | ("" | ".") :: rest -> normalize reversed rest
    | ".." :: rest -> (
        match reversed with
        | [] -> normalize [] rest
        | ".." :: _ -> normalize (".." :: reversed) rest
        | _ :: parent ->
            let previous_is_symlink =
              try (Unix.lstat (path_of_reversed reversed)).st_kind = Unix.S_LNK
              with Unix.Unix_error _ -> true
            in
            if previous_is_symlink then normalize (".." :: reversed) rest
            else normalize parent rest)
    | component :: rest -> normalize (component :: reversed) rest
  in
  normalize [] components

let resolve_hotmount_host_path path =
  Util.expand_home path |> Util.absolute_path |> normalize_hotmount_host_dir

let hotmount_path ~bindfs ~virtle ~manifest_path ~name ~mode ~host_dir
    ~guest_path () =
  let host_dir = normalize_hotmount_host_dir host_dir in
  with_hotmount_lock ~name (fun () ->
      let hotmounts_dir = hotmounts_dir ~name in
      let source_name = hotmount_slug ~host_dir ~guest_path in
      let mount_dir = Filename.concat hotmounts_dir source_name in
      (match find_hotmount_metadata_by_guest_path ~name ~guest_path with
      | Some existing when existing.source_name <> source_name ->
          Log.fatal "guest path %S is already assigned to host directory %S"
            guest_path existing.host_dir
      | Some existing when existing.mode <> mode ->
          Log.fatal
            "guest path %S is already recorded in %s mode; unmount it before \
             changing mode"
            guest_path
            (hotmount_mode_name existing.mode)
      | _ -> ());
      ensure_bindfs_mount ~bindfs ~mode ~source:host_dir ~target:mount_dir;
      let metadata =
        hotmount_metadata ~name ~source_name ~host_dir ~guest_path ~mode
      in
      let metadata_existed = Sys.file_exists metadata.path in
      if not metadata_existed then write_hotmount_metadata_record metadata;
      let action =
        Qga.hotmount_action ~name:"ash-hotmount"
          ~read_only:(match mode with Read_only -> true | Read_write -> false)
          ~hotmounts_guest_dir ~source_name ~guest_path
      in
      let output =
        try
          virtle_rpc ~virtle ~path:manifest_path ~method_name:"guest-exec"
            ~params:(Qga.params action) ()
        with exn ->
          (if not metadata_existed then
             try Unix.unlink metadata.path with Unix.Unix_error _ -> ());
          raise exn
      in
      match (Qga.result action output).exit_code with
      | Some 0 ->
          if metadata_existed then write_hotmount_metadata_record metadata;
          Log.info "mounted %s at %s (%s)" host_dir guest_path
            (hotmount_mode_name mode);
          Printf.printf "%s -> %s (%s)\n" host_dir guest_path
            (hotmount_mode_name mode)
      | Some 42 when metadata_existed ->
          Log.info "%s is already a desired hotmount" guest_path
      | Some 42 ->
          (try Unix.unlink metadata.path with Unix.Unix_error _ -> ());
          Log.fatal "%s is already a mountpoint" guest_path
      | _ ->
          (if not metadata_existed then
             try Unix.unlink metadata.path with Unix.Unix_error _ -> ());
          Log.fatal "failed to hotmount %s at %s: %s" host_dir guest_path output)

let hotmount ?virtle ~mode ~name ~spec () =
  let bindfs = find_bindfs () in
  let virtle = find_virtle virtle in
  let host_path, guest_path = split_hotmount_spec spec in
  if host_path = "" then Log.fatal "host path is empty";
  let host_dir = resolve_hotmount_host_path host_path in
  let name, manifest_path = select_attach_vm (Some name) in
  let user =
    manifest_string (load_manifest_doc manifest_path) [ "ssh"; "user" ]
  in
  let guest_path = resolve_hotmount_guest_path ~user ~host_dir guest_path in
  hotmount_path ~bindfs ~virtle ~manifest_path ~name ~mode ~host_dir ~guest_path
    ()

let try_unmount_hotmount_staging mount_dir =
  let command =
    Printf.sprintf
      {sh|set -u
target=%s

if ! mountpoint -q -- "$target"; then exit 0; fi

if command -v fusermount3 >/dev/null 2>&1; then
  fusermount3 -u "$target" && exit 0
  fusermount3 -uz "$target" && exit 0
fi

if command -v fusermount >/dev/null 2>&1; then
  fusermount -u "$target" && exit 0
  fusermount -uz "$target" && exit 0
fi

if [ "$(id -u)" = 0 ]; then
  umount "$target" && exit 0
fi

printf '%%s\n' 'ash: failed to unmount host hotmount staging path' >&2
exit 1
|sh}
      (Util.shell_quote mount_dir)
  in
  Util.run_foreground "/bin/sh" [ "-c"; command ] = 0

let unmount_hotmount_staging mount_dir =
  if not (try_unmount_hotmount_staging mount_dir) then
    Log.fatal "failed to unmount host staging path %S" mount_dir

let cleanup_orphan_hotmount_staging ~name records =
  let desired = List.map (fun metadata -> metadata.source_name) records in
  let dir = hotmounts_dir ~name in
  if Sys.file_exists dir then
    Sys.readdir dir |> Array.to_list
    |> List.filter (fun entry ->
        entry <> ".ash" && not (List.mem entry desired))
    |> List.iter (fun entry ->
        let path = Filename.concat dir entry in
        try
          if (Unix.lstat path).st_kind = Unix.S_DIR then
            if try_unmount_hotmount_staging path then (
              (try Unix.rmdir path with Unix.Unix_error _ -> ());
              Log.info "cleaned orphan hotmount staging path %s" path)
            else Log.warn "failed to clean orphan hotmount staging path %s" path
        with Unix.Unix_error _ -> ())

let restore_hotmounts ~virtle ~manifest_path ~name =
  with_hotmount_lock ~name (fun () ->
      let state = read_hotmounts ~name in
      log_invalid_hotmount_metadata state.invalid;
      cleanup_orphan_hotmount_staging ~name state.mounts;
      match state.mounts with
      | [] -> ()
      | records -> (
          match Util.find_in_path "bindfs" with
          | None ->
              Log.warn
                "cannot restore %d hotmount(s): bindfs is not available in PATH"
                (List.length records)
          | Some bindfs ->
              let restored = ref 0 in
              let failed = ref 0 in
              List.iter
                (fun metadata ->
                  if not (Sys.file_exists metadata.host_dir) then (
                    incr failed;
                    Log.warn
                      "cannot restore hotmount %s: host directory %S does not \
                       exist"
                      metadata.guest_path metadata.host_dir)
                  else
                    try
                      if (Unix.stat metadata.host_dir).st_kind <> Unix.S_DIR
                      then (
                        incr failed;
                        Log.warn
                          "cannot restore hotmount %s: host path %S is not a \
                           directory"
                          metadata.guest_path metadata.host_dir)
                      else
                        let mount_dir =
                          Filename.concat (hotmounts_dir ~name)
                            metadata.source_name
                        in
                        if
                          not
                            (try_ensure_bindfs_mount ~bindfs ~mode:metadata.mode
                               ~source:metadata.host_dir ~target:mount_dir)
                        then (
                          incr failed;
                          Log.warn
                            "cannot restore hotmount %s: failed to mount host \
                             staging path %s"
                            metadata.guest_path mount_dir)
                        else
                          let action =
                            Qga.hotmount_action ~name:"ash-hotmount-restore"
                              ~read_only:
                                (match metadata.mode with
                                | Read_only -> true
                                | Read_write -> false)
                              ~hotmounts_guest_dir
                              ~source_name:metadata.source_name
                              ~guest_path:metadata.guest_path
                          in
                          let output =
                            virtle_rpc ~virtle ~path:manifest_path
                              ~method_name:"guest-exec"
                              ~params:(Qga.params action) ()
                          in
                          match (Qga.result action output).exit_code with
                          | Some 0 ->
                              incr restored;
                              Log.info "restored hotmount %s at %s (%s)"
                                metadata.host_dir metadata.guest_path
                                (hotmount_mode_name metadata.mode)
                          | Some 42 ->
                              incr failed;
                              Log.warn
                                "cannot restore hotmount %s: guest target is \
                                 already a mountpoint"
                                metadata.guest_path
                          | _ ->
                              incr failed;
                              Log.warn "failed to restore hotmount %s at %s: %s"
                                metadata.host_dir metadata.guest_path output
                    with
                    | Unix.Unix_error (err, _, _) ->
                        incr failed;
                        Log.warn "failed to restore hotmount %s: %s"
                          metadata.guest_path (Unix.error_message err)
                    | Sys_error err | Failure err ->
                        incr failed;
                        Log.warn "failed to restore hotmount %s: %s"
                          metadata.guest_path err)
                records;
              Log.info "hotmount restoration complete: %d restored, %d failed"
                !restored !failed))

let hotunmount_path ~virtle ~manifest_path ~name ~guest_path () =
  with_hotmount_lock ~name (fun () ->
      let metadata = find_hotmount_metadata_by_guest_path ~name ~guest_path in
      Option.iter
        (fun metadata ->
          try Unix.unlink metadata.path
          with Unix.Unix_error (err, _, _) ->
            Log.fatal "failed to remove hotmount metadata %s: %s" metadata.path
              (Unix.error_message err))
        metadata;
      let action = Qga.unmount_action ~name:"ash-hotunmount" ~guest_path in
      let output =
        try
          virtle_rpc ~virtle ~path:manifest_path ~method_name:"guest-exec"
            ~params:(Qga.params action) ()
        with exn ->
          Option.iter write_hotmount_metadata_record metadata;
          raise exn
      in
      (match (Qga.result action output).exit_code with
      | Some 0 -> Log.info "unmounted guest path %s" guest_path
      | Some 42 -> Log.info "%s is not a mountpoint in guest" guest_path
      | _ ->
          Option.iter write_hotmount_metadata_record metadata;
          Log.fatal "failed to unmount guest path %s: %s" guest_path output);
      (match metadata with
      | None -> Log.warn "no hotmount metadata found for %s" guest_path
      | Some metadata ->
          let mount_dir =
            Filename.concat (hotmounts_dir ~name) metadata.source_name
          in
          unmount_hotmount_staging mount_dir;
          (try Unix.rmdir mount_dir with Unix.Unix_error _ -> ());
          Log.info "unmounted host staging path %s" mount_dir);
      Printf.printf "unmounted %s\n" guest_path)

let hotunmount ?virtle ~name ~guest_path () =
  let virtle = find_virtle virtle in
  let name, manifest_path = select_attach_vm (Some name) in
  let user =
    manifest_string (load_manifest_doc manifest_path) [ "ssh"; "user" ]
  in
  let guest_path =
    resolve_hotmount_guest_path ~user ~host_dir:"" (Some guest_path)
  in
  hotunmount_path ~virtle ~manifest_path ~name ~guest_path ()

let space_resources_for_running_vm ~name ~manifest_path spaces =
  let saved_doc = load_manifest_doc (ash_config_path ~name) in
  let config_path = string_of_doc saved_doc [ "spawn"; "config_path" ] in
  let config = Ash_config.load config_path in
  let user =
    manifest_string (load_manifest_doc manifest_path) [ "ssh"; "user" ]
  in
  Ash_config.resources_for_spaces ~guest_user:user config spaces

let hotmount_spaces ?virtle ~name ~spaces () =
  if spaces = [] then Log.fatal "mount-space requires at least one SPACE";
  let bindfs = find_bindfs () in
  let virtle = find_virtle virtle in
  let name, manifest_path = select_attach_vm (Some name) in
  let resources = space_resources_for_running_vm ~name ~manifest_path spaces in
  List.iter
    (fun (mount : Ash_config.mount) ->
      let mode = if mount.read_only then Read_only else Read_write in
      hotmount_path ~bindfs ~virtle ~manifest_path ~name ~mode
        ~host_dir:mount.source ~guest_path:mount.target ())
    resources.mounts

let hotunmount_spaces ?virtle ~name ~spaces () =
  if spaces = [] then Log.fatal "umount-space requires at least one SPACE";
  let virtle = find_virtle virtle in
  let name, manifest_path = select_attach_vm (Some name) in
  let resources = space_resources_for_running_vm ~name ~manifest_path spaces in
  List.iter
    (fun (mount : Ash_config.mount) ->
      hotunmount_path ~virtle ~manifest_path ~name ~guest_path:mount.target ())
    resources.mounts

let ssh_identity_path ~name = Filename.concat (state_dir name) "id_ed25519"

let ensure_ssh_identity ~name =
  let identity = ssh_identity_path ~name in
  let public_key = identity ^ ".pub" in
  if Sys.file_exists identity && Sys.file_exists public_key then identity
  else
    let ssh_keygen =
      match Util.find_in_path "ssh-keygen" with
      | Some path -> path
      | None -> Log.fatal ~code:127 "could not find executable %S" "ssh-keygen"
    in
    let args =
      [
        "-q";
        "-t";
        "ed25519";
        "-N";
        "";
        "-C";
        "ash-autoprovision-" ^ name;
        "-f";
        identity;
      ]
    in
    let code = Util.run_foreground ssh_keygen args in
    if code <> 0 then Log.fatal "ssh-keygen failed with exit code %d" code;
    identity

let install_ssh_key ~virtle ~path ~name ~user =
  let identity = ensure_ssh_identity ~name in
  Log.debug "installing SSH key for VM %s user %s using identity %s" name user
    identity;
  let authorized_key_path = identity ^ ".pub" in
  let authorized_key =
    try
      String.trim
        (In_channel.with_open_text authorized_key_path In_channel.input_all)
    with Sys_error err ->
      Log.fatal "could not read SSH public key %S: %s" authorized_key_path err
  in
  let target =
    if user = "root" then "/root/.ssh/authorized_keys"
    else "/home/" ^ user ^ "/.ssh/authorized_keys"
  in
  let action =
    Qga.install_ssh_key_action ~name:"ash-ssh-autoprovision" ~user ~target
      ~authorized_key
  in
  let output =
    virtle_rpc ~virtle ~path ~method_name:"guest-exec"
      ~params:(Qga.params action) ()
  in
  match (Qga.result action output).exit_code with
  | Some 0 -> identity
  | _ -> Log.fatal "SSH autoprovision failed: %s" output

let attach_running ?virtle ~name ~path ~kitty ~verbose () =
  let virtle = find_virtle virtle in
  if kitty then ignore (find_kitten ());
  Log.debug "attaching to VM %s using manifest %s" name path;
  let status = rpc_status ~virtle ~path () in
  let cid =
    match Qga.int_field ~field:"cid" status with
    | Some cid when cid > 0 -> cid
    | _ -> Log.fatal "could not read VM cid from virtle status: %s" status
  in
  let doc = load_manifest_doc path in
  let user = manifest_string doc [ "ssh"; "user" ] in
  let ssh_exec =
    if kitty then
      let kitty_wrapper = space_mount_ssh_wrapper_path_for ~kitty:true ~name in
      if Sys.file_exists kitty_wrapper then [ kitty_wrapper ]
      else
        Log.fatal "missing kitty SSH wrapper %s; run `ash regenerate %s`"
          kitty_wrapper name
    else manifest_string_array doc [ "ssh"; "exec" ]
  in
  let identity_args =
    match manifest_bool_opt doc [ "ssh"; "autoprovision" ] with
    | Some true ->
        let identity = install_ssh_key ~virtle ~path ~name ~user in
        [ "-i"; identity; "-o"; "IdentitiesOnly=yes" ]
    | _ -> []
  in
  let destination = user ^ "@vsock/" ^ string_of_int cid in
  let verbose_args = List.map (fun _ -> "-v") verbose in
  match ssh_exec with
  | [] -> Log.fatal "manifest ssh.exec is empty"
  | program :: args ->
      let code =
        Util.run_foreground program
          (args @ identity_args @ verbose_args @ [ destination ])
      in
      exit code

let render_resolved_manifest inputs =
  let config = inputs.config in
  let spaces = inputs.spaces in
  let state_dir = state_dir inputs.name in
  let virtle_state_dir = virtle_state_dir inputs.name in
  let memory = 4096 in
  let vcpu = 2 in
  let user = Option.value inputs.user ~default:inputs.target.host_name in
  let target = inputs.target in
  let boot = inputs.boot in
  let resources =
    Ash_config.resources_for_spaces ~guest_user:user config spaces
  in
  let ssh = inputs.ssh in
  let systemd_ssh_proxy = inputs.systemd_ssh_proxy in
  let ssh_options =
    [
      "-o";
      "ProxyCommand=" ^ systemd_ssh_proxy ^ " %h %p";
      "-o";
      "ProxyUseFdpass=yes";
      "-o";
      "CheckHostIP=no";
      "-o";
      "StrictHostKeyChecking=no";
      "-o";
      "UserKnownHostsFile=/dev/null";
      "-o";
      "GlobalKnownHostsFile=/dev/null";
      "-o";
      "PubkeyAuthentication=yes";
    ]
  in
  let real_ssh_exec = ssh :: ssh_options in
  let kitty_ssh_exec = "kitten" :: "ssh" :: ssh_options in
  let workspace_guest_dir =
    Filename.concat (Ash_config.guest_home user) "workspace"
  in
  let workspace_host_dir = Filename.concat state_dir "workspace" in
  let hotmounts_host_dir = hotmounts_dir ~name:inputs.name in
  let ro_store_socket =
    match inputs.ro_store_socket with
    | Some socket -> socket
    | None ->
        Ash_config.global_nix_store_virtiofs_socket config
        |> Option.value ~default:"ro-store.sock"
  in
  let shares_ro_host_dir = shares_ro_dir ~name:inputs.name in
  let shares_rw_host_dir = shares_rw_dir ~name:inputs.name in
  Util.ensure_dir workspace_host_dir;
  Util.ensure_dir hotmounts_host_dir;
  Util.ensure_dir shares_ro_host_dir;
  Util.ensure_dir (Filename.concat shares_rw_host_dir "guest-store-upper");
  Util.ensure_dir (Filename.concat shares_rw_host_dir "guest-store-work");
  let workspace_mount =
    workspace_mount ~workspace_guest_dir ~workspace_host_dir
  in
  let mounts =
    [
      space_mount ~bin:inputs.virtiofsd workspace_mount;
      virtiofs_mount ~cache:"never" ~tag:"hotmounts" ~source:hotmounts_host_dir
        ~read_only:false ~socket:"hotmounts.sock" ~bin:inputs.virtiofsd ();
      virtiofs_mount ~cache:"never" ~tag:"shares-ro" ~source:shares_ro_host_dir
        ~read_only:true ~socket:"shares-ro.sock" ~bin:inputs.virtiofsd ();
      virtiofs_mount ~cache:"never"
        ~extra_args:(shares_rw_virtiofs_extra_args ())
        ~tag:"shares-rw" ~source:shares_rw_host_dir ~read_only:false
        ~socket:"shares-rw.sock" ~bin:inputs.virtiofsd ();
      virtiofs_mount ~tag:"ro-store" ~source:"/nix/store" ~read_only:true
        ~socket:ro_store_socket ~bin:inputs.virtiofsd ();
      image_mount ~source:(Filename.concat state_dir "persist.img");
    ]
    @ (if inputs.mount_cwd then
         [
           virtiofs_mount ~cache:"never" ~tag:"workspace_cwd" ~source:"."
             ~read_only:false ~socket:"workspace-cwd.sock" ~bin:inputs.virtiofsd
             ();
         ]
       else [])
    @ List.map (space_mount ~bin:inputs.virtiofsd) resources.mounts
  in
  let ssh_mounts = workspace_mount :: resources.mounts in
  let ssh_exec =
    [
      write_space_mount_ssh_wrapper ~name:inputs.name ~virtle:inputs.virtle
        ~manifest_path:(manifest_path ~name:inputs.name)
        ~registration_path:boot.registration ~ssh_exec:real_ssh_exec ssh_mounts;
    ]
  in
  let kitty_exec =
    [
      write_space_mount_ssh_wrapper ~kitty:true ~name:inputs.name
        ~virtle:inputs.virtle
        ~manifest_path:(manifest_path ~name:inputs.name)
        ~registration_path:boot.registration ~ssh_exec:kitty_ssh_exec ssh_mounts;
    ]
  in
  let selected_ssh_exec = if inputs.kitty then kitty_exec else ssh_exec in
  let document =
    Otoml.table
      [
        ("host_name", Otoml.string target.host_name);
        ("working_dir", Otoml.string ".");
        ("state_dir", Otoml.string virtle_state_dir);
        ( "machine",
          Otoml.table
            [
              ("memory", Otoml.integer memory);
              ("vcpu", Otoml.integer vcpu);
              ("kvm", Otoml.boolean true);
            ] );
        ( "kernel",
          Otoml.table
            ([
               ("path", Otoml.string boot.kernel);
               ("initrd_path", Otoml.string boot.initrd);
               ( "serial",
                 Otoml.string (if inputs.print_serial then "print" else "off")
               );
             ]
            @
            if boot.kernel_params = [] then []
            else [ ("params", string_array boot.kernel_params) ]) );
        ( "ssh",
          Otoml.table
            [
              ("user", Otoml.string user);
              ("exec", string_array selected_ssh_exec);
              ("ready_socket", Otoml.string "ready.sock");
              ("autoprovision", Otoml.boolean true);
            ] );
        ( "workspace",
          Otoml.table
            [
              ("guest_dir", Otoml.string workspace_guest_dir);
              ("host_dir", Otoml.string workspace_host_dir);
              ("mount_cwd", Otoml.boolean inputs.mount_cwd);
            ] );
        ("mounts", Otoml.TomlTableArray mounts);
      ]
  in
  let header =
    Printf.sprintf
      "# Generated by ash\n\
       # flake = %s\n\
       # host = %s\n\
       # name = %s\n\
       # spaces = %s\n"
      (Nix.flake_ref inputs.flake)
      target.host_name inputs.name (String.concat "," spaces)
  in
  (spaces, header ^ Otoml.Printer.to_string document)

let ash_config (inputs : manifest_inputs) =
  let fields =
    [
      ("config_path", Otoml.string inputs.config_path);
      ("flake", Otoml.string inputs.flake);
      ("name", Otoml.string inputs.name);
      ("spaces", string_array inputs.spaces);
      ("print_serial", Otoml.boolean inputs.print_serial);
      ("mount_cwd", Otoml.boolean inputs.mount_cwd);
      ("kitty", Otoml.boolean inputs.kitty);
      ("virtiofsd", Otoml.string inputs.virtiofsd);
      ("virtle", Otoml.string inputs.virtle);
    ]
  in
  let fields =
    match inputs.user with
    | Some user -> fields @ [ ("user", Otoml.string user) ]
    | None -> fields
  in
  let fields =
    match inputs.ro_store_socket with
    | Some socket -> fields @ [ ("ro_store_socket", Otoml.string socket) ]
    | None -> fields
  in
  let fields =
    match inputs.ssh with
    | Some ssh -> fields @ [ ("ssh", Otoml.string ssh) ]
    | None -> fields
  in
  let fields =
    match inputs.systemd_ssh_proxy with
    | Some systemd_ssh_proxy ->
        fields @ [ ("systemd_ssh_proxy", Otoml.string systemd_ssh_proxy) ]
    | None -> fields
  in
  let tables =
    [ ("spawn", Otoml.table fields) ]
    @
    match inputs.registration_path with
    | Some registration_path ->
        [
          ( "resolved",
            Otoml.table
              [ ("registration_path", Otoml.string registration_path) ] );
        ]
    | None -> []
  in
  "# Generated by ash. Used by `ash regenerate`.\n"
  ^ Otoml.Printer.to_string (Otoml.table tables)

let write_ash_config (inputs : manifest_inputs) =
  let path = ash_config_path ~name:inputs.name in
  let content = ash_config inputs in
  Util.write_file path content;
  Log.debug "wrote ash config %s (%d bytes)" path (String.length content)

let load_ash_config ~name =
  let path = ash_config_path ~name in
  let doc = load_manifest_doc path in
  {
    config_path = string_of_doc doc [ "spawn"; "config_path" ];
    flake = string_of_doc doc [ "spawn"; "flake" ];
    name = string_of_doc doc [ "spawn"; "name" ];
    spaces = string_array_of_doc doc [ "spawn"; "spaces" ];
    user = Otoml.find_opt doc Otoml.get_string [ "spawn"; "user" ];
    print_serial = bool_of_doc doc [ "spawn"; "print_serial" ];
    mount_cwd = bool_of_doc doc [ "spawn"; "mount_cwd" ];
    kitty =
      Option.value
        (Otoml.find_opt doc Otoml.get_boolean [ "spawn"; "kitty" ])
        ~default:false;
    ro_store_socket =
      Otoml.find_opt doc Otoml.get_string [ "spawn"; "ro_store_socket" ];
    ssh = Otoml.find_opt doc Otoml.get_string [ "spawn"; "ssh" ];
    systemd_ssh_proxy =
      Otoml.find_opt doc Otoml.get_string [ "spawn"; "systemd_ssh_proxy" ];
    registration_path =
      Otoml.find_opt doc Otoml.get_string [ "resolved"; "registration_path" ];
    virtiofsd = string_of_doc doc [ "spawn"; "virtiofsd" ];
    virtle = string_of_doc doc [ "spawn"; "virtle" ];
  }

let resolve_spawn_flake ~name = function
  | Some flake -> flake
  | None ->
      if has_saved_ash_config ~name then (
        let saved = load_ash_config ~name in
        Log.debug "using saved flake for existing VM %s: %s" name saved.flake;
        saved.flake)
      else Log.fatal "spawn requires --flake for a new VM"

let resolve_spawn_spaces ~name spaces =
  if spaces <> [] then spaces
  else if has_saved_ash_config ~name then (
    let saved = load_ash_config ~name in
    Log.debug "using saved spaces for existing VM %s: %s" name
      (String.concat "," saved.spaces);
    saved.spaces)
  else []

let render_manifest (inputs : manifest_inputs) =
  let config = Ash_config.load_for_spaces inputs.config_path inputs.spaces in
  let target = Nix.resolve_target ~flake:inputs.flake in
  let user =
    match inputs.user with
    | Some user ->
        Nix.validate_user ~target ~user;
        user
    | None -> Nix.resolve_ssh_user ~target
  in
  let gcroots_dir = gcroots_dir ~name:inputs.name in
  Util.ensure_dir gcroots_dir;
  let boot = Nix.resolve_boot ~target ~gcroots_dir in
  let ssh = Option.value inputs.ssh ~default:boot.ssh in
  let systemd_ssh_proxy =
    Option.value inputs.systemd_ssh_proxy ~default:boot.systemd_ssh_proxy
  in
  let rendered =
    render_resolved_manifest
      {
        config;
        flake = inputs.flake;
        target;
        boot;
        name = inputs.name;
        spaces = inputs.spaces;
        user = Some user;
        print_serial = inputs.print_serial;
        mount_cwd = inputs.mount_cwd;
        ro_store_socket = inputs.ro_store_socket;
        ssh;
        kitty = inputs.kitty;
        systemd_ssh_proxy;
        virtiofsd = inputs.virtiofsd;
        virtle = inputs.virtle;
      }
  in
  (boot.registration, rendered)

let spaces_log spaces =
  match spaces with [] -> "(none)" | spaces -> String.concat "," spaces

let write_manifest_for_inputs inputs =
  let registration_path, (_, manifest) = render_manifest inputs in
  let inputs = { inputs with registration_path = Some registration_path } in
  write_ash_config inputs;
  let path = manifest_path ~name:inputs.name in
  Log.debug "generated virtle manifest path: %s" path;
  Util.write_file path manifest;
  Log.debug "wrote virtle manifest %s (%d bytes, spaces: %s)" path
    (String.length manifest) (spaces_log inputs.spaces);
  (inputs, path)

let prepare_spawn ?virtle ?name ?user ?ssh ?systemd_ssh_proxy ?ro_store_socket
    ~config_path ?flake ~spaces ~print_serial ~mount_cwd ~kitty () =
  let name = Option.value name ~default:(default_name ()) in
  Log.debug "using VM name: %s" name;
  let flake = Nix.storage_flake_ref (resolve_spawn_flake ~name flake) in
  let spaces = resolve_spawn_spaces ~name spaces in
  let virtle = find_virtle virtle in
  if kitty then ignore (find_kitten ());
  let ssh = Option.map (fun path -> find_ssh (Some path)) ssh in
  let systemd_ssh_proxy =
    Option.map
      (fun path -> find_systemd_ssh_proxy (Some path))
      systemd_ssh_proxy
  in
  let virtiofsd = find_virtiofsd () in
  let ro_store_socket = Option.map Util.absolute_path ro_store_socket in
  let inputs =
    {
      config_path;
      flake;
      name;
      spaces;
      user;
      print_serial;
      mount_cwd;
      ro_store_socket;
      ssh;
      systemd_ssh_proxy;
      registration_path = None;
      kitty;
      virtiofsd;
      virtle;
    }
  in
  write_manifest_for_inputs inputs

let launch_args ~resume ~path ~verbose ~ssh =
  let verbose_args = List.map (fun _ -> "-v") verbose in
  let resume_mode = Option.value resume ~default:"no" in
  [ "--manifest"; path ] @ verbose_args
  @ [ "launch"; "--resume"; resume_mode ]
  @ if ssh then [ "--ssh" ] else []

let print_background_started ~name =
  Printf.printf "started VM: %s\n" name;
  Printf.printf "unit: %s\n" (Systemd_run.service_name ~name);
  Printf.printf "attach: ash attach %s\n" (Util.shell_quote name);
  Printf.printf "logs: %s\n" (Systemd_run.logs_hint ~name);
  Printf.printf "stop: ash stop %s\n" (Util.shell_quote name)

let start_background ~resume ~name ~virtle ~path ~verbose =
  let args = launch_args ~resume ~path ~verbose ~ssh:false in
  let description =
    match resume with
    | Some _ -> "ash VM " ^ name ^ " (resume)"
    | None -> "ash VM " ^ name
  in
  let code =
    Systemd_run.start_user_unit ~name ~description ~program:virtle ~args
  in
  if code <> 0 then exit code;
  print_background_started ~name

let registration_for_inputs (inputs : manifest_inputs) =
  match inputs.registration_path with
  | Some registration -> registration
  | None ->
      Log.fatal
        "VM %S has no saved Nix registration path; run `ash regenerate %s`"
        inputs.name
        (Util.shell_quote inputs.name)

let wait_and_mount (inputs : manifest_inputs) path =
  let registration = registration_for_inputs inputs in
  wait_for_ssh_ready ~virtle:inputs.virtle ~path ~name:inputs.name;
  execute_nix_registration ~virtle:inputs.virtle ~path registration;
  execute_space_mounts ~virtle:inputs.virtle ~path
    (space_mounts_for_inputs inputs);
  restore_hotmounts ~virtle:inputs.virtle ~manifest_path:path ~name:inputs.name

let launch_background ~resume (inputs : manifest_inputs) path ~verbose =
  start_background ~resume ~name:inputs.name ~virtle:inputs.virtle ~path
    ~verbose;
  wait_and_mount inputs path

let launch_background_and_attach ~resume (inputs : manifest_inputs) path
    ~verbose =
  launch_background ~resume inputs path ~verbose;
  attach_running ~virtle:inputs.virtle ~name:inputs.name ~path
    ~kitty:inputs.kitty ~verbose ()

let launch_foreground_attached ?cleanup_dir ~resume (inputs : manifest_inputs)
    path ~verbose =
  let args = launch_args ~resume ~path ~verbose ~ssh:true in
  match cleanup_dir with
  | Some dir ->
      let code =
        Fun.protect
          ~finally:(fun () ->
            Log.info "removing ephemeral VM state %s" dir;
            Util.remove_tree ~force:true dir)
          (fun () -> Util.run_foreground inputs.virtle args)
      in
      exit code
  | None -> Util.exec inputs.virtle args

let spawn ?virtle ?name ?user ?ssh ?systemd_ssh_proxy ?ro_store_socket
    ~config_path ?flake ~spaces ~print_serial ~mount_cwd ~ephemeral ~attach
    ~keep ~kitty ~verbose () =
  let inputs, path =
    prepare_spawn ?virtle ?name ?user ?ssh ?systemd_ssh_proxy ?ro_store_socket
      ~config_path ?flake ~spaces ~print_serial ~mount_cwd ~kitty ()
  in
  if attach && keep then
    launch_background_and_attach ~resume:None inputs path ~verbose
  else if attach then
    launch_foreground_attached
      ?cleanup_dir:(if ephemeral then Some (state_dir inputs.name) else None)
      ~resume:None inputs path ~verbose
  else launch_background ~resume:None inputs path ~verbose

let saved_inputs ?virtle ~name () =
  let name = Util.name_slug name in
  let saved = load_ash_config ~name in
  let virtle =
    Option.value
      (Option.map (fun path -> find_virtle (Some path)) virtle)
      ~default:saved.virtle
  in
  { saved with name; virtle }

let resume ?virtle ~name ~attach ~keep ~verbose () =
  let name = Util.name_slug name in
  let running = List.filter (fun vm -> vm.status = Running) (list_vms ()) in
  if List.exists (fun vm -> vm.name = name) running then
    Log.fatal "VM %S is already running" name;
  let inputs = saved_inputs ?virtle ~name () in
  ignore (registration_for_inputs inputs);
  let path = manifest_path ~name:inputs.name in
  if not (Sys.file_exists path) then
    Log.fatal "no VM manifest for %S (expected %s)" inputs.name path;
  if attach && keep then
    launch_background_and_attach ~resume:(Some "force") inputs path ~verbose
  else if attach then
    launch_foreground_attached ~resume:(Some "force") inputs path ~verbose
  else launch_background ~resume:(Some "force") inputs path ~verbose

let rewrite_saved_manifest (inputs : manifest_inputs) =
  Log.debug "regenerating VM manifest for %s" inputs.name;
  let registration_path, (_, manifest) = render_manifest inputs in
  let inputs = { inputs with registration_path = Some registration_path } in
  write_ash_config inputs;
  let path = manifest_path ~name:inputs.name in
  Util.write_file path manifest;
  Log.debug "rewrote virtle manifest %s (%d bytes, spaces: %s)" path
    (String.length manifest) (spaces_log inputs.spaces);
  (inputs, path)

let select_running_vm ?name running =
  match name with
  | Some name ->
      let name = Util.name_slug name in
      List.find_opt (fun vm -> vm.name = name) running
  | None -> (
      match running with
      | [ vm ] -> Some vm
      | [] -> None
      | vms -> (
          match attach_picker (Array.of_list vms) with
          | Some vm -> Some vm
          | None ->
              Log.info "attach cancelled";
              exit 0))

let select_stopped_vm_for_spawn ?name stopped =
  match name with
  | Some name ->
      let name = Util.name_slug name in
      let path = state_dir name in
      let manifest = Filename.concat path "virtle.toml" in
      if not (Sys.file_exists manifest) then
        Log.fatal "no VM named %S (expected %s)" name manifest;
      name
  | None -> (
      match stopped with
      | [ vm ] -> vm.name
      | [] -> Log.fatal "no stopped VM state to spawn; pass a NAME"
      | _ -> Log.fatal "multiple stopped VM states; pass a NAME")

let spawn_saved_and_attach ?virtle ~name ~keep ~kitty ~verbose =
  if kitty then ignore (find_kitten ());
  let inputs = { (saved_inputs ?virtle ~name ()) with kitty } in
  let inputs, path = rewrite_saved_manifest inputs in
  if keep then launch_background_and_attach ~resume:None inputs path ~verbose
  else launch_foreground_attached ~resume:None inputs path ~verbose

let attach ?virtle ?name ~spawn ~keep ~kitty ~verbose () =
  let vms = list_vms () in
  let running = List.filter (fun vm -> vm.status = Running) vms in
  let stopped = List.filter (fun vm -> vm.status = Stopped) vms in
  match select_running_vm ?name running with
  | Some vm ->
      attach_running ?virtle ~name:vm.name
        ~path:(Filename.concat vm.path "virtle.toml")
        ~kitty ~verbose ()
  | None ->
      if not spawn then Log.fatal "no running VMs; use `ash ls` to list states";
      let name = select_stopped_vm_for_spawn ?name stopped in
      spawn_saved_and_attach ?virtle ~name ~keep ~kitty ~verbose

let suspend ?virtle ?name () =
  let virtle = find_virtle virtle in
  let running = List.filter (fun vm -> vm.status = Running) (list_vms ()) in
  let vm =
    match name with
    | Some name -> (
        let name = Util.name_slug name in
        match List.find_opt (fun vm -> vm.name = name) running with
        | Some vm -> vm
        | None -> Log.fatal "VM %S is not running" name)
    | None -> (
        match running with
        | [ vm ] -> vm
        | [] -> Log.fatal "no running VMs"
        | vms -> (
            match attach_picker (Array.of_list vms) with
            | Some vm -> vm
            | None ->
                Log.info "suspend cancelled";
                exit 0))
  in
  if not (Systemd_run.is_user_unit_active ~name:vm.name) then
    Log.fatal
      "VM %S is running, but not as an ash background unit; refusing to \
       suspend it"
      vm.name;
  let manifest_path = Filename.concat vm.path "virtle.toml" in
  let code =
    Util.run_foreground virtle [ "--manifest"; manifest_path; "suspend" ]
  in
  exit code

let stop ?name ~force () =
  let running = List.filter (fun vm -> vm.status = Running) (list_vms ()) in
  let vm =
    match name with
    | Some name -> (
        let name = Util.name_slug name in
        match List.find_opt (fun vm -> vm.name = name) running with
        | Some vm -> vm
        | None -> Log.fatal "VM %S is not running" name)
    | None -> (
        match running with
        | [ vm ] -> vm
        | [] -> Log.fatal "no running VMs"
        | vms -> (
            match attach_picker (Array.of_list vms) with
            | Some vm -> vm
            | None ->
                Log.info "stop cancelled";
                exit 0))
  in
  if not (Systemd_run.is_user_unit_active ~name:vm.name) then
    Log.fatal
      "VM %S is running, but not as an ash background unit; refusing to stop it"
      vm.name;
  control_socket_ssh_stats
    (control_socket_path (virtle_state_dir_for_path vm.path))
  |> confirm_stop_with_active_ssh ~name:vm.name ~force;
  let code = Systemd_run.stop_user_unit ~name:vm.name in
  exit code

let regenerate ?virtle ~name () =
  let name = Util.name_slug name in
  let saved = load_ash_config ~name in
  let virtle =
    Option.value
      (Option.map (fun path -> find_virtle (Some path)) virtle)
      ~default:saved.virtle
  in
  let inputs = { saved with name; virtle } in
  Log.debug "regenerating VM manifest for %s" name;
  let registration_path, (_, manifest) = render_manifest inputs in
  let inputs = { inputs with registration_path = Some registration_path } in
  write_ash_config inputs;
  let manifest_path = manifest_path ~name in
  let ssh_wrapper_path = space_mount_ssh_wrapper_path ~name in
  Util.write_file manifest_path manifest;
  Log.debug "rewrote virtle manifest %s (%d bytes, spaces: %s)" manifest_path
    (String.length manifest) (spaces_log inputs.spaces);
  Printf.printf "regenerated %s\n" manifest_path;
  Printf.printf "regenerated %s\n" ssh_wrapper_path
