type manifest_inputs = {
  config_path : string;
  flake : string;
  name : string;
  profiles : string list;
  user : string option;
  print_serial : bool;
  mount_cwd : bool;
  ssh : string option;
  systemd_ssh_proxy : string option;
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
  ssh : string;
  systemd_ssh_proxy : string;
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
  Log.debug "resolving executable: %s" candidate;
  match Util.find_in_path candidate with
  | Some path ->
      Log.debug "resolved executable %s -> %s" candidate path;
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

let find_ssh explicit_path =
  find_exe ~hint:"pass a valid --ssh PATH." explicit_path "ssh"

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

let json_string value =
  let b = Buffer.create (String.length value + 8) in
  Buffer.add_char b '"';
  String.iter
    (function
      | '"' -> Buffer.add_string b "\\\""
      | '\\' -> Buffer.add_string b "\\\\"
      | '\b' -> Buffer.add_string b "\\b"
      | '\012' -> Buffer.add_string b "\\f"
      | '\n' -> Buffer.add_string b "\\n"
      | '\r' -> Buffer.add_string b "\\r"
      | '\t' -> Buffer.add_string b "\\t"
      | c when Char.code c < 0x20 ->
          Buffer.add_string b (Printf.sprintf "\\u%04x" (Char.code c))
      | c -> Buffer.add_char b c)
    value;
  Buffer.add_char b '"';
  Buffer.contents b

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

let guest_mount_script (mount : Agent_box.mount) =
  let mount_args =
    if mount.read_only then
      Printf.sprintf "-t virtiofs -o ro -- %s %s"
        (Util.shell_quote mount.tag)
        (Util.shell_quote mount.target)
    else
      Printf.sprintf "-t virtiofs -- %s %s"
        (Util.shell_quote mount.tag)
        (Util.shell_quote mount.target)
  in
  String.concat "\n"
    [
      "set -eu";
      "if /run/current-system/sw/bin/mountpoint -q "
      ^ Util.shell_quote mount.target
      ^ "; then";
      "  exit 42";
      "fi";
      "/run/current-system/sw/bin/install -d " ^ Util.shell_quote mount.target;
      "/run/current-system/sw/bin/mount " ^ mount_args;
    ]

let guest_exec_params script =
  "{\"path\":\"/run/current-system/sw/bin/sh\",\"args\":[\"-c\","
  ^ json_string script ^ "],\"captureOutput\":true}"

let write_profile_mount_ssh_wrapper ~name ~virtle ~manifest_path ~ssh_exec
    mounts =
  let path = profile_mount_ssh_wrapper_path ~name in
  let mount_commands =
    mounts
    |> List.map (fun (mount : Agent_box.mount) ->
        let params = guest_exec_params (guest_mount_script mount) in
        String.concat "\n"
          [
            "result=$(" ^ Util.shell_quote virtle ^ " --manifest "
            ^ Util.shell_quote manifest_path
            ^ " rpc guest-exec " ^ Util.shell_quote params ^ ")";
            "case \"$result\" in";
            "  *'\"exitCode\":0'*)";
            "    ash_log INFO "
            ^ Util.shell_quote ("mounted " ^ mount.tag ^ " at " ^ mount.target);
            "    ;;";
            "  *'\"exitCode\":42'*) ;;";
            "  *)";
            "    ash_log ERROR "
            ^ Util.shell_quote
                ("failed to mount " ^ mount.tag ^ " at " ^ mount.target);
            "    printf '%s\\n' \"$result\" >&2";
            "    exit 1";
            "    ;;";
            "esac";
          ])
    |> String.concat "\n"
  in
  let exec_ssh =
    "exec "
    ^ String.concat " " (List.map Util.shell_quote ssh_exec)
    ^ " \"$@" ^ "\""
  in
  let content =
    String.concat "\n"
      [
        "#!/bin/sh";
        "set -eu";
        "";
        "ash_log() {";
        "  level=$1";
        "  shift";
        "  ts=$(/run/current-system/sw/bin/date '+%Y-%m-%dT%H:%M:%S')";
        "  dim= color= reset=";
        "  if [ -z \"${NO_COLOR:-}\" ] && [ \"${ASH_COLOR:-}\" != never ]; then";
        "    esc=$(/run/current-system/sw/bin/printf '\\033')";
        "    dim=\"${esc}[2m\"";
        "    reset=\"${esc}[0m\"";
        "    case \"$level\" in";
        "      DEBUG) color=\"${esc}[2;36m\" ;;";
        "      INFO) color=\"${esc}[32m\" ;;";
        "      WARN) color=\"${esc}[33m\" ;;";
        "      ERROR) color=\"${esc}[31m\" ;;";
        "    esac";
        "    printf '%s%s%s %sash-ssh%s %s%s%s %s\\n' \"$dim\" \"$ts\" \
         \"$reset\" \"$dim\" \"$reset\" \"$color\" \"$level\" \"$reset\" \
         \"$*\" >&2";
        "  else";
        "    printf '%s ash-ssh %s %s\\n' \"$ts\" \"$level\" \"$*\" >&2";
        "  fi";
        "}";
        "";
        "# Generated by ash. Mount profile virtiofs targets before attaching \
         SSH.";
        mount_commands;
        "";
        exec_ssh;
        "";
      ]
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

let json_int_field ~field text =
  let int_value = function
    | `Int value -> Some value
    | `Intlit value -> int_of_string_opt value
    | _ -> None
  in
  let rec find = function
    | `Assoc fields -> (
        match Option.bind (List.assoc_opt field fields) int_value with
        | Some value -> Some value
        | None -> fields |> List.find_map (fun (_, value) -> find value))
    | `List values -> List.find_map find values
    | _ -> None
  in
  try Yojson.Safe.from_string text |> find with Yojson.Json_error _ -> None

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
        let request = "{\"id\":1,\"method\":\"status\",\"params\":{}}\n" in
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
        read_response "" |> json_int_field ~field:"cid"
      with Unix.Unix_error _ | Sys_error _ | Failure _ | Invalid_argument _ ->
        None)

let rec path_size path =
  try
    let stat = Unix.lstat path in
    match stat.st_kind with
    | Unix.S_DIR ->
        Sys.readdir path
        |> Array.fold_left
             (fun total entry ->
               Int64.add total (path_size (Filename.concat path entry)))
             (Int64.of_int stat.st_size)
    | _ -> Int64.of_int stat.st_size
  with Unix.Unix_error _ | Sys_error _ -> 0L

let first_word value =
  String.trim value |> String.split_on_char ' ' |> List.find_opt (( <> ) "")

let disk_usage path =
  try
    let output =
      Util.command_output ("du -sk -- " ^ Util.shell_quote path ^ " 2>/dev/null")
    in
    let output =
      String.map (function '\t' | '\n' | '\r' -> ' ' | c -> c) output
    in
    match first_word output with
    | Some kib -> Int64.mul (Int64.of_string kib) 1024L
    | None -> path_size path
  with Failure _ | Invalid_argument _ -> path_size path

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
                apparent_bytes = path_size path;
                modified = stat.st_mtime;
                path;
              }
          else None
        with Unix.Unix_error _ | Sys_error _ -> None)

let print_vm_list () =
  let status_string = function Running -> "running" | Stopped -> "stopped" in
  let cid_string = function Some cid -> string_of_int cid | None -> "-" in
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
      | vms ->
          Log.fatal "multiple running VMs; pass a name, e.g. `ash attach %s`"
            (List.hd vms).name)

let attach ?virtle ?name ~verbose () =
  let name, path = select_attach_vm name in
  let virtle = find_virtle virtle in
  Log.debug "attaching to VM %s using manifest %s" name path;
  let status =
    Util.command_output
      (String.concat " "
         (List.map Util.shell_quote
            [ virtle; "--manifest"; path; "rpc"; "status" ]))
  in
  let cid =
    match json_int_field ~field:"cid" status with
    | Some cid when cid > 0 -> cid
    | _ -> Log.fatal "could not read VM cid from virtle status: %s" status
  in
  let doc = load_manifest_doc path in
  let user = manifest_string doc [ "ssh"; "user" ] in
  let ssh_exec = manifest_string_array doc [ "ssh"; "exec" ] in
  let destination = user ^ "@vsock/" ^ string_of_int cid in
  let verbose_args = List.map (fun _ -> "-v") verbose in
  match ssh_exec with
  | [] -> Log.fatal "manifest ssh.exec is empty"
  | program :: args -> Util.exec program (args @ verbose_args @ [ destination ])

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
  let real_ssh_exec =
    [
      ssh;
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
    ]
  in
  let workspace_guest_dir = "/home/" ^ user ^ "/workspace" in
  let workspace_host_dir = Filename.concat state_dir "workspace" in
  Util.ensure_dir workspace_host_dir;
  let workspace_mount =
    workspace_mount ~workspace_guest_dir ~workspace_host_dir
  in
  let mounts =
    [
      profile_mount ~bin:inputs.virtiofsd workspace_mount;
      virtiofs_mount ~tag:"ro-store" ~source:"/nix/store" ~read_only:true
        ~socket:"ro-store.sock" ~bin:inputs.virtiofsd ();
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
              ("exec", string_array ssh_exec);
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
      ssh;
      systemd_ssh_proxy;
      virtiofsd = inputs.virtiofsd;
      virtle = inputs.virtle;
    }

let spawn ?virtle ?name ?user ?ssh ?systemd_ssh_proxy ~config_path ~flake
    ~profiles ~print_serial ~mount_cwd ~verbose () =
  let virtle = find_virtle virtle in
  let ssh = Option.map (fun path -> find_ssh (Some path)) ssh in
  let systemd_ssh_proxy =
    Option.map
      (fun path -> find_systemd_ssh_proxy (Some path))
      systemd_ssh_proxy
  in
  let virtiofsd = find_virtiofsd () in
  let name = Option.value name ~default:(default_name ()) in
  Log.debug "using VM name: %s" name;
  let _, manifest =
    render_manifest
      {
        config_path;
        flake;
        name;
        profiles;
        user;
        print_serial;
        mount_cwd;
        ssh;
        systemd_ssh_proxy;
        virtiofsd;
        virtle;
      }
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
      ssh;
      systemd_ssh_proxy;
      virtiofsd;
      virtle;
    }
  in
  write_ash_config inputs;
  let path = manifest_path ~name in
  Log.debug "generated virtle manifest path: %s" path;
  Util.write_file path manifest;
  Log.debug "wrote virtle manifest (%d bytes)" (String.length manifest);
  let verbose_args = List.map (fun _ -> "-v") verbose in
  Util.exec virtle
    ([ "--manifest"; path ] @ verbose_args @ [ "launch"; "--ssh" ])

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
  Log.debug "rewrote virtle manifest %s (%d bytes)" manifest_path
    (String.length manifest);
  Printf.printf "regenerated %s\n" manifest_path;
  Printf.printf "regenerated %s\n" ssh_wrapper_path
