type manifest_inputs = {
  config_path : string;
  flake : string;
  name : string;
  profiles : string list;
  user : string option;
  print_serial : bool;
  mount_cwd : bool;
  ro_store_socket : string option;
  ssh : string option;
  systemd_ssh_proxy : string option;
  kitty : bool;
  virtiofsd : string;
  virtle : string;
}

type resolved_manifest_inputs = {
  config : Agent_box.config;
  flake : string;
  target : Nix.target;
  boot : Nix.boot;
  name : string;
  profiles : string list;
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
let manifest_path ~name = Filename.concat (state_dir name) "virtle.toml"
let ash_config_path ~name = Filename.concat (state_dir name) "ash.toml"

let profile_mount_ssh_wrapper_path ~name =
  Filename.concat (state_dir name) "ssh-with-profile-mounts"

let profile_mount_ssh_wrapper_path_for ~kitty ~name =
  if kitty then Filename.concat (state_dir name) "ssh-with-profile-mounts-kitty"
  else profile_mount_ssh_wrapper_path ~name

let string_array xs = Otoml.array (List.map Otoml.string xs)

let bool_of_doc doc path =
  match Otoml.find_opt doc Otoml.get_boolean path with
  | Some value -> value
  | None ->
      Log.fatal "ash.toml is missing boolean field %s" (String.concat "." path)

let string_of_doc doc path =
  match Otoml.find_opt doc Otoml.get_string path with
  | Some value -> value
  | None ->
      Log.fatal "ash.toml is missing string field %s" (String.concat "." path)

let string_array_of_doc doc path =
  match Otoml.find_opt doc (Otoml.get_array Otoml.get_string) path with
  | Some value -> value
  | None ->
      Log.fatal "ash.toml is missing string array field %s"
        (String.concat "." path)

let virtiofs_section ~socket ~bin =
  Otoml.table
    [
      ("socket", Otoml.string socket);
      ("bin", Otoml.string bin);
      ( "args",
        string_array
          [
            "--socket-path={{.Socket}}";
            "--shared-dir={{.MountSource}}";
            "--tag={{.MountTag}}";
          ] );
    ]

let virtiofs_mount ?target ~tag ~source ~read_only ~socket ~bin () =
  let fields =
    [
      ("type", Otoml.string "virtiofs");
      ("tag", Otoml.string tag);
      ("source", Otoml.string source);
      ("read_only", Otoml.boolean read_only);
      ("virtiofs", virtiofs_section ~socket ~bin);
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

let profile_mount ~bin (mount : Agent_box.mount) =
  virtiofs_mount ~target:mount.target ~tag:mount.tag ~source:mount.source
    ~read_only:mount.read_only ~socket:(mount.tag ^ ".sock") ~bin ()

let workspace_mount ~workspace_guest_dir ~workspace_host_dir =
  {
    Agent_box.tag = "workspace";
    source = workspace_host_dir;
    target = workspace_guest_dir;
    read_only = false;
  }

let hotmounts_dir ~name = Filename.concat (state_dir name) "hotmounts"
let hotmounts_guest_dir = "/run/ash/hotmounts"
let hotmount_metadata_dir ~name = Filename.concat (hotmounts_dir ~name) ".ash"

let hotmount_slug ~host_dir ~guest_path =
  let digest = Digest.to_hex (Digest.string (host_dir ^ "\000" ^ guest_path)) in
  Util.name_slug (Filename.basename host_dir ^ "-" ^ String.sub digest 0 12)

type hotmount_mode = Read_only | Read_write

let hotmount_mode_of_string = function
  | "ro" -> Read_only
  | "rw" -> Read_write
  | mode -> Log.fatal "unsupported mount mode %S; expected ro or rw" mode

let hotmount_mode_name = function Read_only -> "ro" | Read_write -> "rw"

let mount_action (mount : Agent_box.mount) =
  Qga.mount_virtiofs_action ~name:("ash-mount-" ^ mount.tag) ~tag:mount.tag
    ~target:mount.target ~read_only:mount.read_only

let write_profile_mount_ssh_wrapper ?(kitty = false) ~name ~virtle
    ~manifest_path ~ssh_exec mounts =
  let path = profile_mount_ssh_wrapper_path_for ~kitty ~name in
  let mount_commands =
    mounts
    |> List.map (fun (mount : Agent_box.mount) ->
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

# Generated by ash. Mount profile virtiofs targets before attaching SSH.
%s

%s
|sh}
      mount_commands exec_ssh
  in
  Util.write_file path content;
  Unix.chmod path 0o755;
  Log.debug "generated SSH profile mount wrapper: %s" path;
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

let control_socket_status_cid path =
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
                 ("method", `String "status");
                 ("params", `Assoc []);
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
        read_response "" |> Qga.int_field ~field:"cid"
      with Unix.Unix_error _ | Sys_error _ | Failure _ | Invalid_argument _ ->
        None)

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

let state_path_size path = path_size ~exclude_entry:(( = ) "hotmounts") path

let disk_usage path =
  let hotmounts = Filename.concat path "hotmounts" in
  try
    let output =
      Util.command_output
        ("du -sk --exclude=" ^ Util.shell_quote hotmounts ^ " -- "
       ^ Util.shell_quote path ^ " 2>/dev/null")
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
            let control_socket = control_socket_path path in
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

let print_vm_list () =
  let vms = list_vms () in
  Printf.printf "%-32s %-8s %5s %10s %10s  %-19s %s\n" "NAME" "STATUS" "CID"
    "DISK" "VIRTUAL" "MODIFIED" "PATH";
  List.iter
    (fun vm ->
      Printf.printf "%-32s %-8s %5s %10s %10s  %-19s %s\n" vm.name
        (status_string vm.status) (cid_string vm.cid) (human_size vm.disk_bytes)
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
            Util.remove_tree vm.path)

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
      if not (socket_accepts_connection (control_socket_path (state_dir name)))
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

let profile_mounts_for_inputs inputs =
  let config = Agent_box.load inputs.config_path in
  let profiles =
    match inputs.profiles with
    | [] -> [ Agent_box.default_profile config ]
    | profiles -> profiles
  in
  let user = Option.value inputs.user ~default:(Agent_box.ssh_user config) in
  let resources =
    Agent_box.resources_for_profiles ~guest_user:user config profiles
  in
  let workspace_mount =
    workspace_mount
      ~workspace_guest_dir:("/home/" ^ user ^ "/workspace")
      ~workspace_host_dir:(Filename.concat (state_dir inputs.name) "workspace")
  in
  workspace_mount :: resources.mounts

let execute_profile_mounts ~virtle ~path mounts =
  List.iter
    (fun (mount : Agent_box.mount) ->
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

let ensure_bindfs_mount ~bindfs ~mode ~source ~target =
  Util.ensure_dir target;
  let mode_args = match mode with Read_only -> [ "-r" ] | Read_write -> [] in
  let bindfs_args = [ "--multithreaded"; "--no-allow-other" ] @ mode_args in
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
  let code = Util.run_foreground "/bin/sh" [ "-c"; command ] in
  if code <> 0 then
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

let write_hotmount_metadata ~name ~source_name ~host_dir ~guest_path ~mode =
  let content =
    String.concat "\n"
      [ guest_path; host_dir; hotmount_mode_name mode; source_name; "" ]
  in
  Util.write_file (metadata_path ~name ~source_name) content

let first_line path =
  try Some (In_channel.with_open_text path input_line) with _ -> None

let find_hotmount_metadata_by_guest_path ~name ~guest_path =
  let dir = hotmount_metadata_dir ~name in
  if not (Sys.file_exists dir) then None
  else
    Sys.readdir dir |> Array.to_list
    |> List.filter_map (fun entry ->
        let path = Filename.concat dir entry in
        match first_line path with
        | Some line when line = guest_path ->
            let source_name = Filename.remove_extension entry in
            Some (source_name, path)
        | _ -> None)
    |> List.find_opt (fun _ -> true)

let resolve_hotmount_guest_path ~user ~host_dir = function
  | None -> host_dir
  | Some "~" -> guest_home user
  | Some path when String.length path >= 2 && String.sub path 0 2 = "~/" ->
      Filename.concat (guest_home user)
        (String.sub path 2 (String.length path - 2))
  | Some path when Filename.is_relative path ->
      Log.fatal "guest mount path %S must be absolute or start with ~" path
  | Some path -> path

let hotmount_path ~bindfs ~virtle ~manifest_path ~name ~mode ~host_dir
    ~guest_path () =
  if not (Sys.file_exists host_dir) then
    Log.fatal "host directory %S does not exist" host_dir;
  if (Unix.stat host_dir).st_kind <> Unix.S_DIR then
    Log.fatal "host path %S is not a directory" host_dir;
  let hotmounts_dir = hotmounts_dir ~name in
  let source_name = hotmount_slug ~host_dir ~guest_path in
  let mount_dir = Filename.concat hotmounts_dir source_name in
  ensure_bindfs_mount ~bindfs ~mode ~source:host_dir ~target:mount_dir;
  let action =
    Qga.hotmount_action ~name:"ash-hotmount"
      ~read_only:(match mode with Read_only -> true | Read_write -> false)
      ~hotmounts_guest_dir ~source_name ~guest_path
  in
  let output =
    virtle_rpc ~virtle ~path:manifest_path ~method_name:"guest-exec"
      ~params:(Qga.params action) ()
  in
  match (Qga.result action output).exit_code with
  | Some 0 ->
      write_hotmount_metadata ~name ~source_name ~host_dir ~guest_path ~mode;
      Log.info "mounted %s at %s (%s)" host_dir guest_path
        (hotmount_mode_name mode);
      Printf.printf "%s -> %s (%s)\n" host_dir guest_path
        (hotmount_mode_name mode)
  | Some 42 -> Log.info "%s is already a mountpoint" guest_path
  | _ -> Log.fatal "failed to hotmount %s at %s: %s" host_dir guest_path output

let hotmount ?virtle ~mode ~name ~spec () =
  let bindfs = find_bindfs () in
  let virtle = find_virtle virtle in
  let host_path, guest_path = split_hotmount_spec spec in
  let host_dir = Util.absolute_path (Util.expand_home host_path) in
  if host_path = "" then Log.fatal "host path is empty";
  let name, manifest_path = select_attach_vm (Some name) in
  let user =
    manifest_string (load_manifest_doc manifest_path) [ "ssh"; "user" ]
  in
  let guest_path = resolve_hotmount_guest_path ~user ~host_dir guest_path in
  hotmount_path ~bindfs ~virtle ~manifest_path ~name ~mode ~host_dir ~guest_path
    ()

let unmount_hotmount_staging mount_dir =
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
  let code = Util.run_foreground "/bin/sh" [ "-c"; command ] in
  if code <> 0 then Log.fatal "failed to unmount host staging path %S" mount_dir

let hotunmount_path ~virtle ~manifest_path ~name ~guest_path () =
  let metadata = find_hotmount_metadata_by_guest_path ~name ~guest_path in
  let action = Qga.unmount_action ~name:"ash-hotunmount" ~guest_path in
  let output =
    virtle_rpc ~virtle ~path:manifest_path ~method_name:"guest-exec"
      ~params:(Qga.params action) ()
  in
  (match (Qga.result action output).exit_code with
  | Some 0 -> Log.info "unmounted guest path %s" guest_path
  | Some 42 -> Log.info "%s is not a mountpoint in guest" guest_path
  | _ -> Log.fatal "failed to unmount guest path %s: %s" guest_path output);
  (match metadata with
  | None -> Log.warn "no hotmount metadata found for %s" guest_path
  | Some (source_name, metadata_path) ->
      let mount_dir = Filename.concat (hotmounts_dir ~name) source_name in
      unmount_hotmount_staging mount_dir;
      (try Unix.unlink metadata_path with Unix.Unix_error _ -> ());
      (try Unix.rmdir mount_dir with Unix.Unix_error _ -> ());
      Log.info "unmounted host staging path %s" mount_dir);
  Printf.printf "unmounted %s\n" guest_path

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

let profile_resources_for_running_vm ~name ~manifest_path profiles =
  let saved_doc = load_manifest_doc (ash_config_path ~name) in
  let config_path = string_of_doc saved_doc [ "spawn"; "config_path" ] in
  let config = Agent_box.load config_path in
  let user =
    manifest_string (load_manifest_doc manifest_path) [ "ssh"; "user" ]
  in
  let resources =
    Agent_box.resources_for_profiles ~guest_user:user config profiles
  in
  if resources.write_files <> [] then
    Log.warn
      "runtime profile mounting does not support profile file entries; \
       skipping %d file(s)"
      (List.length resources.write_files);
  resources

let hotmount_profiles ?virtle ~name ~profiles () =
  if profiles = [] then Log.fatal "mount-profile requires at least one PROFILE";
  let bindfs = find_bindfs () in
  let virtle = find_virtle virtle in
  let name, manifest_path = select_attach_vm (Some name) in
  let resources =
    profile_resources_for_running_vm ~name ~manifest_path profiles
  in
  List.iter
    (fun (mount : Agent_box.mount) ->
      let mode = if mount.read_only then Read_only else Read_write in
      hotmount_path ~bindfs ~virtle ~manifest_path ~name ~mode
        ~host_dir:mount.source ~guest_path:mount.target ())
    resources.mounts

let hotunmount_profiles ?virtle ~name ~profiles () =
  if profiles = [] then Log.fatal "umount-profile requires at least one PROFILE";
  let virtle = find_virtle virtle in
  let name, manifest_path = select_attach_vm (Some name) in
  let resources =
    profile_resources_for_running_vm ~name ~manifest_path profiles
  in
  List.iter
    (fun (mount : Agent_box.mount) ->
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
      let kitty_wrapper =
        profile_mount_ssh_wrapper_path_for ~kitty:true ~name
      in
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

let write_file_section user (file : Agent_box.write_file) =
  let fields =
    [
      ("guest_path", Otoml.string file.guest_path);
      ("source", Otoml.string file.source);
      ("chown", Otoml.string (user ^ ":users"));
      ("overwrite", Otoml.boolean true);
      ("follow_links", Otoml.boolean true);
    ]
  in
  let fields =
    if file.write_back then fields @ [ ("write_back", Otoml.boolean true) ]
    else fields
  in
  Otoml.table fields

let render_resolved_manifest inputs =
  let config = inputs.config in
  let profiles =
    match inputs.profiles with
    | [] -> [ Agent_box.default_profile config ]
    | profiles -> profiles
  in
  let state_dir = state_dir inputs.name in
  let memory =
    Agent_box.qemu_memory config
    |> Option.map parse_memory_mib
    |> Option.value ~default:4096
  in
  let vcpu = Agent_box.qemu_cpus config |> Option.value ~default:2 in
  let user = Option.value inputs.user ~default:(Agent_box.ssh_user config) in
  let target = inputs.target in
  let boot = inputs.boot in
  let resources =
    Agent_box.resources_for_profiles ~guest_user:user config profiles
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
  let workspace_guest_dir = "/home/" ^ user ^ "/workspace" in
  let workspace_host_dir = Filename.concat state_dir "workspace" in
  let hotmounts_host_dir = hotmounts_dir ~name:inputs.name in
  Util.ensure_dir workspace_host_dir;
  Util.ensure_dir hotmounts_host_dir;
  let workspace_mount =
    workspace_mount ~workspace_guest_dir ~workspace_host_dir
  in
  let mounts =
    [
      profile_mount ~bin:inputs.virtiofsd workspace_mount;
      virtiofs_mount ~tag:"hotmounts" ~source:hotmounts_host_dir
        ~read_only:false ~socket:"hotmounts.sock" ~bin:inputs.virtiofsd ();
      virtiofs_mount ~tag:"ro-store" ~source:"/nix/store" ~read_only:true
        ~socket:(Option.value inputs.ro_store_socket ~default:"ro-store.sock")
        ~bin:inputs.virtiofsd ();
      image_mount ~source:(Filename.concat state_dir "persist.img");
    ]
    @ (if inputs.mount_cwd then
         [
           virtiofs_mount ~tag:"workspace_cwd" ~source:"." ~read_only:false
             ~socket:"workspace-cwd.sock" ~bin:inputs.virtiofsd ();
         ]
       else [])
    @ List.map (profile_mount ~bin:inputs.virtiofsd) resources.mounts
  in
  let write_files = List.map (write_file_section user) resources.write_files in
  let ssh_mounts = workspace_mount :: resources.mounts in
  let ssh_exec =
    [
      write_profile_mount_ssh_wrapper ~name:inputs.name ~virtle:inputs.virtle
        ~manifest_path:(manifest_path ~name:inputs.name)
        ~ssh_exec:real_ssh_exec ssh_mounts;
    ]
  in
  let kitty_exec =
    [
      write_profile_mount_ssh_wrapper ~kitty:true ~name:inputs.name
        ~virtle:inputs.virtle
        ~manifest_path:(manifest_path ~name:inputs.name)
        ~ssh_exec:kitty_ssh_exec ssh_mounts;
    ]
  in
  let selected_ssh_exec = if inputs.kitty then kitty_exec else ssh_exec in
  let document =
    Otoml.table
      [
        ("host_name", Otoml.string target.host_name);
        ("working_dir", Otoml.string ".");
        ("state_dir", Otoml.string state_dir);
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
  let document =
    if write_files = [] then document
    else
      Otoml.update document [ "write_files" ]
        (Some (Otoml.TomlTableArray write_files))
  in
  let header =
    Printf.sprintf
      "# Generated by ash\n\
       # flake = %s\n\
       # host = %s\n\
       # name = %s\n\
       # profiles = %s\n"
      (Nix.flake_ref inputs.flake)
      target.host_name inputs.name
      (String.concat "," profiles)
  in
  (profiles, header ^ Otoml.Printer.to_string document)

let ash_config (inputs : manifest_inputs) =
  let fields =
    [
      ("config_path", Otoml.string inputs.config_path);
      ("flake", Otoml.string inputs.flake);
      ("name", Otoml.string inputs.name);
      ("profiles", string_array inputs.profiles);
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
  "# Generated by ash. Used by `ash regenerate`.\n"
  ^ Otoml.Printer.to_string (Otoml.table [ ("spawn", Otoml.table fields) ])

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
    profiles = string_array_of_doc doc [ "spawn"; "profiles" ];
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
    virtiofsd = string_of_doc doc [ "spawn"; "virtiofsd" ];
    virtle = string_of_doc doc [ "spawn"; "virtle" ];
  }

let render_manifest (inputs : manifest_inputs) =
  let config = Agent_box.load inputs.config_path in
  let target = Nix.resolve_target ~flake:inputs.flake in
  let user = Option.value inputs.user ~default:(Agent_box.ssh_user config) in
  Nix.validate_user ~target ~user;
  let boot = Nix.resolve_boot ~target in
  let ssh = Option.value inputs.ssh ~default:boot.ssh in
  let systemd_ssh_proxy =
    Option.value inputs.systemd_ssh_proxy ~default:boot.systemd_ssh_proxy
  in
  render_resolved_manifest
    {
      config;
      flake = inputs.flake;
      target;
      boot;
      name = inputs.name;
      profiles = inputs.profiles;
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

let profiles_log profiles =
  match profiles with [] -> "(none)" | profiles -> String.concat "," profiles

let write_manifest_for_inputs inputs =
  let _, manifest = render_manifest inputs in
  write_ash_config inputs;
  let path = manifest_path ~name:inputs.name in
  Log.debug "generated virtle manifest path: %s" path;
  Util.write_file path manifest;
  Log.debug "wrote virtle manifest %s (%d bytes, profiles: %s)" path
    (String.length manifest)
    (profiles_log inputs.profiles);
  path

let prepare_spawn ?virtle ?name ?user ?ssh ?systemd_ssh_proxy ?ro_store_socket
    ~config_path ~flake ~profiles ~print_serial ~mount_cwd ~kitty () =
  let virtle = find_virtle virtle in
  if kitty then ignore (find_kitten ());
  let ssh = Option.map (fun path -> find_ssh (Some path)) ssh in
  let systemd_ssh_proxy =
    Option.map
      (fun path -> find_systemd_ssh_proxy (Some path))
      systemd_ssh_proxy
  in
  let virtiofsd = find_virtiofsd () in
  let flake = Nix.storage_flake_ref flake in
  let name = Option.value name ~default:(default_name ()) in
  Log.debug "using VM name: %s" name;
  let ro_store_socket = Option.map Util.absolute_path ro_store_socket in
  let profiles =
    if profiles <> [] then profiles
    else
      let saved_path = ash_config_path ~name in
      if Sys.file_exists saved_path then (
        let saved = load_ash_config ~name in
        Log.debug "using saved profiles for existing VM %s: %s" name
          (String.concat "," saved.profiles);
        saved.profiles)
      else profiles
  in
  let inputs =
    {
      config_path;
      flake;
      name;
      profiles;
      user;
      print_serial;
      mount_cwd;
      ro_store_socket;
      ssh;
      systemd_ssh_proxy;
      kitty;
      virtiofsd;
      virtle;
    }
  in
  let path = write_manifest_for_inputs inputs in
  (inputs, path)

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

let wait_and_mount (inputs : manifest_inputs) path =
  wait_for_ssh_ready ~virtle:inputs.virtle ~path ~name:inputs.name;
  execute_profile_mounts ~virtle:inputs.virtle ~path
    (profile_mounts_for_inputs inputs)

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
            Util.remove_tree dir)
          (fun () -> Util.run_foreground inputs.virtle args)
      in
      exit code
  | None -> Util.exec inputs.virtle args

let spawn ?virtle ?name ?user ?ssh ?systemd_ssh_proxy ?ro_store_socket
    ~config_path ~flake ~profiles ~print_serial ~mount_cwd ~ephemeral ~attach
    ~keep ~kitty ~verbose () =
  let inputs, path =
    prepare_spawn ?virtle ?name ?user ?ssh ?systemd_ssh_proxy ?ro_store_socket
      ~config_path ~flake ~profiles ~print_serial ~mount_cwd ~kitty ()
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
  let _, manifest = render_manifest inputs in
  let path = manifest_path ~name:inputs.name in
  Util.write_file path manifest;
  Log.debug "rewrote virtle manifest %s (%d bytes, profiles: %s)" path
    (String.length manifest)
    (profiles_log inputs.profiles);
  path

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
  let path = rewrite_saved_manifest inputs in
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

let stop ?name () =
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
  let _, manifest = render_manifest inputs in
  let manifest_path = manifest_path ~name in
  let ssh_wrapper_path = profile_mount_ssh_wrapper_path ~name in
  Util.write_file manifest_path manifest;
  Log.debug "rewrote virtle manifest %s (%d bytes, profiles: %s)" manifest_path
    (String.length manifest)
    (profiles_log inputs.profiles);
  Printf.printf "regenerated %s\n" manifest_path;
  Printf.printf "regenerated %s\n" ssh_wrapper_path
