type kernel_serial = Off | Print | Console

let string_of_kernel_serial = function
  | Off -> "off"
  | Print -> "print"
  | Console -> "console"

let nix_store_kernel_param = function
  | Ash_config.Shared -> "ash.nix-store=shared"
  | Ash_config.Image -> "ash.nix-store=image"

let has_prefix ~prefix value =
  String.length value >= String.length prefix
  && String.sub value 0 (String.length prefix) = prefix

let is_nix_store_kernel_param = has_prefix ~prefix:"ash.nix-store="

let is_mdns_kernel_param value =
  has_prefix ~prefix:"ash.mdns-host=" value
  || has_prefix ~prefix:"ash.mdns-mac=" value

let mdns_kernel_params ~name ~mac =
  [ "ash.mdns-host=" ^ Util.dns_label name; "ash.mdns-mac=" ^ mac ]

let kernel_serial_of_string ~field = function
  | "off" -> Off
  | "print" -> Print
  | "console" -> Console
  | value ->
      Log.fatal "%s must be one of off, print, or console (got %S)" field value

type manifest_inputs = {
  config_path : string;
  flake : string;
  override_inputs : (string * string) list;
  name : string;
  spaces : string list;
  user : string option;
  kernel_serial : kernel_serial;
  mount_cwd : bool;
  nix_store_strategy : Ash_config.nix_store_strategy option;
  nix_store_image_size_mib : int option;
  ro_store_socket : string option;
  ssh : string option;
  systemd_ssh_proxy : string option;
  registration_path : string option;
  kitty : bool;
  waypipe : string option;
  virtiofsd : string;
  virtle : string;
}

type resolved_manifest_inputs = {
  config : Ash_config.config;
  config_path : string;
  flake : string;
  target : Nix.target;
  boot : Nix.boot;
  name : string;
  spaces : string list;
  user : string option;
  kernel_serial : kernel_serial;
  mount_cwd : bool;
  nix_store_strategy : Ash_config.nix_store_strategy;
  nix_store_image_size_mib : int;
  ro_store_socket : string option;
  ssh : string;
  systemd_ssh_proxy : string;
  portal_host : string option;
  portal_dbus_proxy : string option;
  kitty : bool;
  waypipe : string option;
  virtiofsd : string;
  virtle : string;
}

let find_exe ?hint ?env explicit_path default_name =
  Util.get_exe ?hint ?env explicit_path default_name

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

let find_scp () =
  find_exe ~hint:"install OpenSSH scp into PATH so ash can copy VM files." None
    "scp"

let find_kitten () =
  find_exe ~hint:"install kitty into PATH so `kitten ssh` is available." None
    "kitten"

let find_waypipe () =
  find_exe
    ~hint:"install waypipe on the host and in the guest, or omit --waypipe."
    None "waypipe"

let find_systemd_ssh_proxy explicit_path =
  find_exe ~hint:"pass a valid --systemd-ssh-proxy PATH." explicit_path
    "systemd-ssh-proxy"

let find_sibling_or_exe ~name ~env ~hint =
  let sibling =
    Filename.concat
      (Filename.dirname (Util.absolute_path Sys.executable_name))
      name
  in
  if Sys.file_exists sibling && Util.is_executable sibling then sibling
  else find_exe ~hint ~env None name

let find_agent_portal_host () =
  find_sibling_or_exe ~name:"agent-portal-host" ~env:"ASH_AGENT_PORTAL_HOST"
    ~hint:
      "install agent-portal-host alongside ash or disable [portal] in the Ash \
       config."

let find_portal_dbus_proxy () =
  find_sibling_or_exe ~name:"ash-dbus-proxy" ~env:"ASH_DBUS_PROXY"
    ~hint:
      "install ash-dbus-proxy alongside ash or disable \
       [portal.dbus].notifications."

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
  Filename.concat base (Util.application_name ())

let state_dir name = Filename.concat (state_base_dir ()) (Util.name_slug name)

let nix_store_image_cache_dir () =
  Filename.concat
    (Filename.concat (Util.cache_home_dir ()) (Util.application_name ()))
    "nix-store-images"

let nix_store_image_cache_path ~toplevel =
  let key = Nix.image_store_cache_key ~toplevel in
  Filename.concat (nix_store_image_cache_dir ()) (key ^ ".img")

let network_mac name =
  let hash =
    Digest.string ("ash-network\000" ^ Util.name_slug name) |> Digest.to_hex
  in
  Printf.sprintf "02:%s:%s:%s:%s:%s" (String.sub hash 0 2) (String.sub hash 2 2)
    (String.sub hash 4 2) (String.sub hash 6 2) (String.sub hash 8 2)

let virtle_state_dir name = Filename.concat (state_dir name) "virtle_state"
let virtle_state_dir_for_path path = Filename.concat path "virtle_state"
let gcroots_dir ~name = Filename.concat (state_dir name) "gcroots"
let manifest_path ~name = Filename.concat (state_dir name) "virtle.toml"
let ash_config_path ~name = Filename.concat (state_dir name) "ash-state.toml"
let has_saved_ash_config ~name = Sys.file_exists (ash_config_path ~name)

let with_state_lock ~name f =
  let dir = state_dir name in
  Util.ensure_dir dir;
  let path = Filename.concat dir "ash-state.lock" in
  let fd = Unix.openfile path [ Unix.O_CREAT; Unix.O_RDWR ] 0o600 in
  Fun.protect
    ~finally:(fun () -> Unix.close fd)
    (fun () ->
      Unix.lockf fd Unix.F_LOCK 0;
      f ())

let space_mount_ssh_wrapper_path ~name =
  Filename.concat (state_dir name) "ssh-with-space-mounts"

let space_mount_ssh_wrapper_path_for ~kitty ~name =
  if kitty then Filename.concat (state_dir name) "ssh-with-space-mounts-kitty"
  else space_mount_ssh_wrapper_path ~name

let waypipe_ssh_wrapper_path_for ~kitty ~name =
  Filename.concat (state_dir name)
    (if kitty then "ssh-with-waypipe-kitty" else "ssh-with-waypipe")

let waypipe_ssh_exec ~waypipe ~ssh_wrapper ~name =
  [
    waypipe;
    "--no-gpu";
    "--title-prefix";
    "ash: " ^ name ^ ": ";
    "--ssh-bin";
    ssh_wrapper;
    "--remote-bin";
    "waypipe";
    "--xwls";
    "ssh";
  ]

let write_waypipe_ssh_wrapper ~waypipe ~ssh_wrapper ~kitty ~name =
  let path = waypipe_ssh_wrapper_path_for ~kitty ~name in
  let command =
    waypipe_ssh_exec ~waypipe ~ssh_wrapper ~name
    |> List.map Util.shell_quote |> String.concat " "
  in
  Util.write_file path
    (Printf.sprintf "#!/bin/sh\nset -eu\nexec %s \"$@\"\n" command);
  Unix.chmod path 0o755;
  Log.debug "generated Waypipe SSH wrapper: %s" path;
  path

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

let positive_integer_opt_of_doc doc path =
  match Otoml.find_opt doc Otoml.get_integer path with
  | None -> None
  | Some value when value > 0 -> Some value
  | Some _ ->
      Log.fatal "ash-state.toml field %s must be greater than zero"
        (String.concat "." path)

let virtiofs_section ?cache ?(extra_args = []) ?(virtle_defaults = false)
    ~socket ~bin () =
  let fields = [ ("socket", Otoml.string socket); ("bin", Otoml.string bin) ] in
  if virtle_defaults then Otoml.table fields
  else
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
    Otoml.table (fields @ [ ("args", string_array args) ])

let virtiofs_mount ?target ?cache ?extra_args ?virtle_defaults ~tag ~source
    ~read_only ~socket ~bin () =
  let fields =
    [
      ("type", Otoml.string "virtiofs");
      ("tag", Otoml.string tag);
      ("source", Otoml.string source);
      ("read_only", Otoml.boolean read_only);
      ( "virtiofs",
        virtiofs_section ?cache ?extra_args ?virtle_defaults ~socket ~bin () );
    ]
  in
  let fields =
    match target with
    | None -> fields
    | Some target -> ("target", Otoml.string target) :: fields
  in
  Otoml.table (List.rev fields)

let image_mount ~source ~size ~label =
  Otoml.table
    [
      ("type", Otoml.string "image");
      ("source", Otoml.string source);
      ("read_only", Otoml.boolean false);
      ( "image",
        Otoml.table
          [
            ("size", Otoml.integer size);
            ("fs", Otoml.string "ext4");
            ("create", Otoml.boolean true);
            ("label", Otoml.string label);
          ] );
    ]

let shares_dir ~name = Filename.concat (state_dir name) "shares"
let shares_ro_dir ~name = Filename.concat (shares_dir ~name) "ro"
let shares_rw_dir ~name = Filename.concat (shares_dir ~name) "rw"
let shares_guest_dir = "/run/ash/shares"
let shares_ro_guest_dir = Filename.concat shares_guest_dir "ro"
let shares_rw_guest_dir = Filename.concat shares_guest_dir "rw"

let shares_system_dir ~name ~read_only =
  Filename.concat
    (if read_only then shares_ro_dir ~name else shares_rw_dir ~name)
    "system"

let shares_mounts_dir ~name ~read_only =
  Filename.concat
    (if read_only then shares_ro_dir ~name else shares_rw_dir ~name)
    "mounts"

let shares_mount_dir ~name ~read_only category id =
  Filename.concat
    (Filename.concat (shares_mounts_dir ~name ~read_only) category)
    id

let workspace_host_dir ~name =
  Filename.concat (shares_mounts_dir ~name ~read_only:false) "workspace"

let workspace_mount ~workspace_guest_dir ~workspace_host_dir =
  {
    Ash_config.tag = "workspace";
    source = workspace_host_dir;
    target = workspace_guest_dir;
    read_only = false;
  }

(* Legacy locations are retained only for migrating existing hotmount state. *)
let legacy_hotmounts_dir ~name = Filename.concat (state_dir name) "hotmounts"

let legacy_hotmount_metadata_dir ~name =
  Filename.concat (legacy_hotmounts_dir ~name) ".ash"

let migrate_state_path ~old_path ~new_path =
  if Sys.file_exists old_path && not (Sys.file_exists new_path) then (
    Util.ensure_dir (Filename.dirname new_path);
    Unix.rename old_path new_path;
    Log.info "migrated VM state %s to %s" old_path new_path)

type subordinate_id_range = { start : int; count : int }

let subordinate_id_range ~user ~id path =
  try
    In_channel.with_open_text path (fun channel ->
        In_channel.input_lines channel
        |> List.find_map (fun line ->
            match String.split_on_char ':' line with
            | [ owner; start; count ]
              when owner = user || owner = string_of_int id -> (
                match (int_of_string_opt start, int_of_string_opt count) with
                | Some start, Some count -> Some { start; count }
                | _ -> None)
            | _ -> None))
  with Sys_error _ -> None

let virtiofs_idmap_args ~uid ~subuid_start ~subgid_start =
  [
    Printf.sprintf "--uid-map=:0:%d:1:" uid;
    Printf.sprintf "--uid-map=:1:%d:65535:" subuid_start;
    Printf.sprintf "--gid-map=:0:%d:65536:" subgid_start;
  ]

let virtiofs_squash_args ~uid ~gid =
  [
    Printf.sprintf "--translate-uid=squash-guest:0:%d:65536" uid;
    Printf.sprintf "--translate-uid=squash-host:%d:0:1" uid;
    Printf.sprintf "--translate-gid=squash-guest:0:%d:65536" gid;
    Printf.sprintf "--translate-gid=squash-host:%d:0:1" gid;
  ]

type shares_rw_identity =
  | Idmapped of { uid : int; subuid_start : int; subgid_start : int }
  | Squashed of { uid : int; gid : int }

let shares_rw_identity () =
  let uid = Unix.getuid () in
  let gid = Unix.getgid () in
  let user =
    try (Unix.getpwuid uid).pw_name with Not_found -> string_of_int uid
  in
  match
    ( subordinate_id_range ~user ~id:uid "/etc/subuid",
      subordinate_id_range ~user ~id:uid "/etc/subgid" )
  with
  | Some subuid, Some subgid when subuid.count >= 65535 && subgid.count >= 65536
    ->
      Log.debug
        "using subordinate UID/GID ranges for shares-rw virtiofs: uid=%d:%d:%d \
         gid=%d:%d:%d"
        uid subuid.start subuid.count gid subgid.start subgid.count;
      Idmapped { uid; subuid_start = subuid.start; subgid_start = subgid.start }
  | _ ->
      Log.warn
        "no sufficiently large subordinate UID/GID ranges for %s; shares-rw \
         virtiofs will squash guest identities"
        user;
      Squashed { uid; gid }

let shares_rw_virtiofs_extra_args = function
  | Idmapped { uid; subuid_start; subgid_start } ->
      virtiofs_idmap_args ~uid ~subuid_start ~subgid_start
  | Squashed { uid; gid } -> virtiofs_squash_args ~uid ~gid

let prepare_guest_store_dirs ?(run_foreground = Util.run_foreground) identity
    shares_rw_host_dir =
  let state = Filename.concat shares_rw_host_dir "guest-store-state" in
  let upper = Filename.concat shares_rw_host_dir "guest-store-upper" in
  let work = Filename.concat shares_rw_host_dir "guest-store-work" in
  let prepare_squashed () =
    Util.ensure_dir state;
    Util.ensure_dir upper;
    Unix.chmod upper 0o1777;
    Util.ensure_dir work
  in
  match identity with
  | Squashed _ ->
      prepare_squashed ();
      identity
  | Idmapped { uid; subuid_start; subgid_start } ->
      let unshare = find_exe None "unshare" in
      let shell = find_exe None "sh" in
      let script =
        {sh|set -eu
state=$1
upper=$2
work=$3
mkdir -p "$state" "$upper" "$work"
chown 0:0 "$state" "$upper" "$work"
chmod 0755 "$state" "$work"
chmod 1777 "$upper"
|sh}
      in
      let args =
        [
          "--map-users";
          Printf.sprintf "0:%d:1" uid;
          "--map-users";
          Printf.sprintf "1:%d:65535" subuid_start;
          "--map-groups";
          Printf.sprintf "0:%d:65536" subgid_start;
          "--setuid";
          "0";
          "--setgid";
          "0";
          shell;
          "-c";
          script;
          "ash-prepare-guest-store";
          state;
          upper;
          work;
        ]
      in
      if run_foreground unshare args = 0 then identity
      else
        let fallback =
          Squashed { uid = Unix.getuid (); gid = Unix.getgid () }
        in
        Log.warn
          "could not create an id-mapped user namespace; shares-rw virtiofs \
           will squash guest identities";
        prepare_squashed ();
        fallback

let hotmount_slug ~host_dir ~guest_path =
  let digest = Digest.to_hex (Digest.string (host_dir ^ "\000" ^ guest_path)) in
  Util.name_slug (Filename.basename host_dir ^ "-" ^ String.sub digest 0 12)

type hotmount_mode = Read_only | Read_write

let hotmount_mode_of_string = function
  | "ro" -> Read_only
  | "rw" -> Read_write
  | mode -> Log.fatal "unsupported mount mode %S; expected ro or rw" mode

let hotmount_mode_name = function Read_only -> "ro" | Read_write -> "rw"

let shared_mount_location (mount : Ash_config.mount) =
  let share_tag, share_guest_dir =
    if mount.read_only then ("shares-ro", shares_ro_guest_dir)
    else ("shares-rw", shares_rw_guest_dir)
  in
  let relative_source =
    match mount.tag with
    | "workspace" -> "mounts/workspace"
    | "workspace_cwd" -> "mounts/cwd"
    | tag -> Filename.concat "mounts/spaces" tag
  in
  (share_tag, share_guest_dir, relative_source)

let mount_action (mount : Ash_config.mount) =
  let share_tag, share_guest_dir, relative_source =
    shared_mount_location mount
  in
  Qga.mount_shared_path_action ~name:("ash-mount-" ^ mount.tag) ~share_tag
    ~share_guest_dir ~relative_source ~guest_path:mount.target
    ~read_only:mount.read_only

let write_space_mount_ssh_wrapper ?(kitty = false) ~name ~virtle ~manifest_path
    ~registration_path ~load_registration ~ssh_exec mounts =
  let path = space_mount_ssh_wrapper_path_for ~kitty ~name in
  let registration_action =
    Qga.load_nix_registration_action ~name:"ash-load-nix-registration"
      ~registration:registration_path
  in
  let registration_command =
    if not load_registration then ""
    else
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

type cached_image_info = {
  cache_key : string;
  metadata : Image_metadata.t option;
  toplevel : string option;
  references : string list;
  disk_bytes : int64;
  apparent_bytes : int64;
  modified : float;
  path : string;
  sidecar : string;
}

type rm_target = Vm_state of vm_info | Cached_image of cached_image_info

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

let parse_vm_stats output =
  match String.split_on_char ' ' (String.trim output) with
  | [ ip; connections; ptys ] -> (
      match (int_of_string_opt connections, int_of_string_opt ptys) with
      | Some connections, Some ptys when connections >= 0 && ptys >= 0 ->
          Some ((if ip = "-" then None else Some ip), connections, ptys)
      | _ -> None)
  | _ -> None

let control_socket_vm_stats path ~mac =
  let action = Qga.vm_stats_action ~mac in
  let params = Yojson.Safe.from_string (Qga.params action) in
  match control_socket_rpc path ~method_name:"guest-exec" ~params with
  | Some response when Qga.int_field ~field:"exitCode" response = Some 0 ->
      Option.bind (Qga.output_data response) parse_vm_stats
  | _ -> None

let control_socket_ssh_stats path ~mac =
  match control_socket_vm_stats path ~mac with
  | Some (_, connections, ptys) -> Some (connections, ptys)
  | None -> None

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

let vm_stats vm =
  match vm.status with
  | Stopped -> (None, None, None)
  | Running -> (
      match
        control_socket_vm_stats
          (control_socket_path (virtle_state_dir_for_path vm.path))
          ~mac:(network_mac vm.name)
      with
      | Some (ip, connections, ptys) -> (ip, Some connections, Some ptys)
      | None -> (None, None, None))

let ssh_stats vm =
  let _, connections, ptys = vm_stats vm in
  (connections, ptys)

let ip_string = function Some ip -> ip | None -> "-"

let print_vm_list () =
  let vms = list_vms () in
  Printf.printf "%-32s %-8s %-15s %5s %4s %4s %10s %10s  %-19s %s\n" "NAME"
    "STATUS" "IP" "CID" "SSH" "PTY" "DISK" "VIRTUAL" "MODIFIED" "PATH";
  List.iter
    (fun vm ->
      let ip, connections, ptys = vm_stats vm in
      Printf.printf "%-32s %-8s %-15s %5s %4s %4s %10s %10s  %-19s %s\n" vm.name
        (status_string vm.status) (ip_string ip) (cid_string vm.cid)
        (count_string connections) (count_string ptys)
        (human_size vm.disk_bytes)
        (human_size vm.apparent_bytes)
        (format_time vm.modified) vm.path)
    vms

let cache_reference_table vms =
  let references = Hashtbl.create (List.length vms) in
  List.iter
    (fun (vm : vm_info) ->
      let image = Filename.concat vm.path "nix-store.img" in
      try
        match Image_metadata.read image with
        | Image_metadata.Current prepared when prepared.kind = Image_metadata.Vm
          ->
            let key = Nix.image_store_cache_key ~toplevel:prepared.toplevel in
            let names =
              Hashtbl.find_opt references key |> Option.value ~default:[]
            in
            Hashtbl.replace references key (vm.name :: names)
        | Image_metadata.Current _ | Image_metadata.Legacy
        | Image_metadata.Invalid | Image_metadata.Missing ->
            ()
      with Sys_error _ | Unix.Unix_error _ -> ())
    vms;
  references

let list_cached_images ?vms () =
  let vms = Option.value vms ~default:(list_vms ()) in
  let references = cache_reference_table vms in
  let base = nix_store_image_cache_dir () in
  if not (Sys.file_exists base) then []
  else
    Sys.readdir base |> Array.to_list
    |> List.filter_map (fun name ->
        if not (Filename.check_suffix name ".img") then None
        else
          let path = Filename.concat base name in
          let sidecar = Image_metadata.sidecar_path path in
          try
            let stat = Unix.LargeFile.stat path in
            if stat.st_kind <> Unix.S_REG then None
            else
              let metadata =
                try
                  match Image_metadata.read path with
                  | Image_metadata.Current metadata
                    when metadata.kind = Image_metadata.Cache ->
                      Some metadata
                  | Image_metadata.Current _ | Image_metadata.Legacy
                  | Image_metadata.Invalid | Image_metadata.Missing ->
                      None
                with Sys_error _ | Unix.Unix_error _ -> None
              in
              Some
                {
                  cache_key = Filename.chop_suffix name ".img";
                  metadata;
                  toplevel =
                    Option.map
                      (fun metadata -> metadata.Image_metadata.toplevel)
                      metadata;
                  references =
                    Hashtbl.find_opt references
                      (Filename.chop_suffix name ".img")
                    |> Option.value ~default:[] |> List.rev;
                  disk_bytes = disk_usage path;
                  apparent_bytes = stat.st_size;
                  modified = stat.st_mtime;
                  path;
                  sidecar;
                }
          with Unix.Unix_error _ | Sys_error _ -> None)
    |> List.sort (fun left right ->
        match Float.compare right.modified left.modified with
        | 0 -> String.compare left.cache_key right.cache_key
        | order -> order)

let short_cache_key key =
  if String.length key <= 12 then key else String.sub key 0 12

let cached_image_closure image =
  image.toplevel
  |> Option.map Filename.basename
  |> Option.value ~default:"unknown-closure"

let cached_image_last_used image =
  image.metadata
  |> Option.map (fun metadata -> metadata.Image_metadata.last_used_at)
  |> Option.value ~default:"legacy"

let cached_image_path_count image =
  Option.bind image.metadata (fun metadata ->
      metadata.Image_metadata.closure_path_count)
  |> Option.map string_of_int |> Option.value ~default:"-"

let cached_image_nar_size image =
  Option.bind image.metadata (fun metadata ->
      metadata.Image_metadata.closure_nar_size_bytes)
  |> Option.map human_size |> Option.value ~default:"-"

let cached_image_origin image =
  match image.metadata with
  | Some { Image_metadata.origins = origin :: rest; _ } ->
      let value =
        Printf.sprintf "%s#%s" origin.flake_url origin.nixos_configuration
      in
      if rest = [] then value
      else Printf.sprintf "%s (+%d)" value (List.length rest)
  | Some _ -> "unknown"
  | None -> "legacy"

let cached_image_list_header =
  Printf.sprintf "%-32s %10s %10s  %-19s %-20s %4s %7s %10s  %-32s %-32s %s"
    "KEY" "DISK" "VIRTUAL" "MODIFIED" "LAST USED" "REFS" "PATHS" "NAR" "CLOSURE"
    "ORIGIN" "PATH"

let cached_image_list_item image =
  Printf.sprintf "%-32s %10s %10s  %-19s %-20s %4d %7s %10s  %-32s %-32s %s"
    image.cache_key
    (human_size image.disk_bytes)
    (human_size image.apparent_bytes)
    (format_time image.modified)
    (cached_image_last_used image)
    (List.length image.references)
    (cached_image_path_count image)
    (cached_image_nar_size image)
    (cached_image_closure image)
    (cached_image_origin image)
    image.path

let print_cached_image_list () =
  Printf.printf "%s\n" cached_image_list_header;
  list_cached_images ()
  |> List.iter (fun image ->
      Printf.printf "%s\n" (cached_image_list_item image))

let rm_item_label = function
  | Vm_state vm ->
      Printf.sprintf "%-32s %10s  %s" vm.name (human_size vm.disk_bytes)
        (format_time vm.modified)
  | Cached_image image ->
      Printf.sprintf "%-12s %10s  %s  %4d  %s"
        (short_cache_key image.cache_key)
        (human_size image.disk_bytes)
        (format_time image.modified)
        (List.length image.references)
        (cached_image_closure image)

let rm_item_detail = function
  | Vm_state vm -> vm.path
  | Cached_image image ->
      let references =
        match image.references with
        | [] -> "no VM references"
        | names ->
            Printf.sprintf "%d VM reference%s: %s" (List.length names)
              (if List.length names = 1 then "" else "s")
              (String.concat ", " names)
      in
      let metadata =
        Printf.sprintf "last used %s; %s paths; %s NAR; origin %s"
          (cached_image_last_used image)
          (cached_image_path_count image)
          (cached_image_nar_size image)
          (cached_image_origin image)
      in
      Printf.sprintf "%s  %s  %s  %s" references
        (cached_image_closure image)
        metadata image.path

let rm_item_disk_bytes = function
  | Vm_state vm -> vm.disk_bytes
  | Cached_image image -> image.disk_bytes

let rm_selection_summary targets =
  targets
  |> List.fold_left
       (fun total target -> Int64.add total (rm_item_disk_bytes target))
       0L
  |> human_size

let vm_target = function
  | Vm_state vm -> vm
  | Cached_image _ -> invalid_arg "expected VM removal target"

let cache_target = function
  | Cached_image image -> image
  | Vm_state _ -> invalid_arg "expected cached image removal target"

let compare_then compare tie left right =
  match compare left right with 0 -> tie left right | order -> order

let vm_sort compare left right =
  compare_then compare
    (fun left right -> String.compare left.name right.name)
    (vm_target left) (vm_target right)

let cache_sort compare left right =
  compare_then compare
    (fun left right -> String.compare left.cache_key right.cache_key)
    (cache_target left) (cache_target right)

let vm_rm_sorts : rm_target Tui.sort array =
  [|
    {
      name = "name";
      compare = vm_sort (fun left right -> String.compare left.name right.name);
    };
    {
      name = "modified";
      compare =
        vm_sort (fun left right -> Float.compare left.modified right.modified);
    };
    {
      name = "size";
      compare =
        vm_sort (fun left right ->
            Int64.compare left.disk_bytes right.disk_bytes);
    };
  |]

let cache_rm_sorts : rm_target Tui.sort array =
  [|
    {
      name = "modified";
      compare =
        cache_sort (fun left right ->
            Float.compare left.modified right.modified);
    };
    {
      name = "size";
      compare =
        cache_sort (fun left right ->
            Int64.compare left.disk_bytes right.disk_bytes);
    };
  |]

let attach_item vm =
  Printf.sprintf "%-32s %-8s %5s  %s" vm.name (status_string vm.status)
    (cid_string vm.cid) vm.path

let remove_cached_image image =
  Log.info "deleting cached Nix store image %s (%s)" image.cache_key image.path;
  Util.remove_tree ~force:true image.path;
  Util.remove_tree ~force:true image.sidecar;
  Util.remove_tree ~force:true (Image_metadata.legacy_path image.path)

let rm_vms () =
  let vms = list_vms () in
  let vm_targets =
    vms
    |> List.filter_map (fun vm ->
        if vm.status = Stopped then Some (Vm_state vm) else None)
    |> Array.of_list
  in
  let cache_targets =
    list_cached_images ~vms ()
    |> List.map (fun image -> Cached_image image)
    |> Array.of_list
  in
  if Array.length vm_targets + Array.length cache_targets = 0 then
    Log.info "no stopped VM states or cached images found"
  else
    let panes : rm_target Tui.pane array =
      [|
        {
          title = "VM states";
          columns = Printf.sprintf "%-32s %10s  %-19s" "NAME" "SIZE" "MODIFIED";
          items = vm_targets;
          label = rm_item_label;
          detail = rm_item_detail;
          selection_summary = rm_selection_summary;
          sorts = vm_rm_sorts;
          bulk_actions = [||];
          initial_descending = false;
        };
        {
          title = "Cached images";
          columns =
            Printf.sprintf "%-12s %10s  %-19s  %4s  %s" "KEY" "SIZE" "MODIFIED"
              "REFS" "CLOSURE";
          items = cache_targets;
          label = rm_item_label;
          detail = rm_item_detail;
          selection_summary = rm_selection_summary;
          sorts = cache_rm_sorts;
          bulk_actions =
            [|
              {
                key = 'u';
                select =
                  (function
                  | Cached_image image -> image.references = []
                  | Vm_state _ -> false);
              };
            |];
          initial_descending = true;
        };
      |]
    in
    let selected =
      Tui.select_panes ~title:"Select VM states and cached images to delete"
        ~help:
          "←/→/tab pane  ↑/k ↓/j move  space select  a all/none  u \
           unreferenced  s sort  r reverse  enter delete  q cancel"
        ~panes
    in
    match selected with
    | [] -> Log.info "no VM states or cached images selected"
    | selected ->
        selected
        |> List.iter (function
          | Vm_state vm ->
              Log.info "deleting VM state %s (%s)" vm.name vm.path;
              Util.remove_tree ~force:true vm.path
          | Cached_image image -> remove_cached_image image)

let attach_picker vms =
  Tui.select_one ~title:"Select VM to attach"
    ~help:"↑/k ↓/j move  enter attach  q cancel" ~items:vms ~label:attach_item

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

let space_mounts_for_inputs (inputs : manifest_inputs) =
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
      ~workspace_host_dir:(workspace_host_dir ~name:inputs.name)
  in
  workspace_mount
  ::
  (if inputs.mount_cwd then
     [
       {
         Ash_config.tag = "workspace_cwd";
         source = Sys.getcwd ();
         target = "/mnt/cwd";
         read_only = false;
       };
     ]
   else [])
  @ resources.mounts

let execute_nix_registration ~virtle ~path registration =
  let action =
    Qga.load_nix_registration_action ~name:"ash-load-nix-registration"
      ~registration
  in
  let output =
    try
      virtle_rpc ~virtle ~path ~method_name:"guest-exec"
        ~params:(Qga.params action) ()
    with Failure message ->
      Log.fatal "failed to run Nix store registration guest-exec: %s" message
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
    Log.fatal "failed to mount host directory %S at staging path %S" source
      target

let try_unmount_staging mount_dir =
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
if [ "$(id -u)" = 0 ]; then umount "$target" && exit 0; fi
exit 1
|sh}
      (Util.shell_quote mount_dir)
  in
  Util.run_foreground "/bin/sh" [ "-c"; command ] = 0

let remove_staging_path path =
  if try_unmount_staging path then Util.remove_tree ~force:true path
  else Log.warn "failed to remove stale staging path %s" path

let cleanup_staging_children ~dir ~desired =
  if Sys.file_exists dir then
    Sys.readdir dir |> Array.to_list
    |> List.filter (fun entry -> not (List.mem entry desired))
    |> List.iter (fun entry -> remove_staging_path (Filename.concat dir entry))

let static_mount_staging_dir ~name (mount : Ash_config.mount) =
  match mount.tag with
  | "workspace" -> workspace_host_dir ~name
  | "workspace_cwd" ->
      Filename.concat (shares_mounts_dir ~name ~read_only:false) "cwd"
  | tag -> shares_mount_dir ~name ~read_only:mount.read_only "spaces" tag

let prepare_host_share_mounts (inputs : manifest_inputs) =
  let mounts = space_mounts_for_inputs inputs in
  let store_strategy =
    Option.value inputs.nix_store_strategy
      ~default:
        (Ash_config.load_for_spaces inputs.config_path []
        |> Ash_config.global_nix_store_strategy)
  in
  let staged_mounts =
    List.filter
      (fun (mount : Ash_config.mount) -> mount.tag <> "workspace")
      mounts
  in
  let bindfs =
    if staged_mounts <> [] || store_strategy = Ash_config.Shared then
      Some (find_bindfs ())
    else None
  in
  List.iter
    (fun read_only ->
      let desired =
        mounts
        |> List.filter (fun (mount : Ash_config.mount) ->
            mount.tag <> "workspace"
            && mount.tag <> "workspace_cwd"
            && mount.read_only = read_only)
        |> List.map (fun (mount : Ash_config.mount) -> mount.tag)
      in
      cleanup_staging_children
        ~dir:
          (Filename.concat
             (shares_mounts_dir ~name:inputs.name ~read_only)
             "spaces")
        ~desired)
    [ true; false ];
  (* cwd has a fixed staging name but a launch-dependent source, so always
     replace it rather than accepting a stale mountpoint from an earlier cwd. *)
  remove_staging_path
    (Filename.concat
       (shares_mounts_dir ~name:inputs.name ~read_only:false)
       "cwd");
  List.iter
    (fun (mount : Ash_config.mount) ->
      if mount.tag = "workspace" then Util.ensure_dir mount.source
      else
        ensure_bindfs_mount ~bindfs:(Option.get bindfs)
          ~mode:(if mount.read_only then Read_only else Read_write)
          ~source:mount.source
          ~target:(static_mount_staging_dir ~name:inputs.name mount))
    mounts;
  match store_strategy with
  | Ash_config.Shared ->
      ensure_bindfs_mount ~bindfs:(Option.get bindfs) ~mode:Read_only
        ~source:"/nix/store"
        ~target:
          (Filename.concat
             (shares_system_dir ~name:inputs.name ~read_only:true)
             "nix-store")
  | Ash_config.Image ->
      remove_staging_path
        (Filename.concat
           (shares_system_dir ~name:inputs.name ~read_only:true)
           "nix-store")

let split_hotmount_spec spec =
  match String.index_opt spec ':' with
  | None -> (spec, None)
  | Some idx ->
      let host_path = String.sub spec 0 idx in
      let guest_len = String.length spec - idx - 1 in
      let guest_path = String.sub spec (idx + 1) guest_len in
      (host_path, Util.some_if (guest_path <> "") guest_path)

let guest_home user = if user = "root" then "/root" else "/home/" ^ user

type runtime_mount = {
  id : string;
  guest_path : string;
  host_dir : string;
  mode : hotmount_mode;
  owners : string list;
}

type runtime_mount_state = { spaces : string list; mounts : runtime_mount list }

let empty_runtime_mount_state = { spaces = []; mounts = [] }
let manual_mount_owner = "manual"
let space_mount_owner space = "space:" ^ space

let runtime_mount_staging_dir ~name mount =
  shares_mount_dir ~name ~read_only:(mount.mode = Read_only) "hotmounts"
    mount.id

let runtime_mount_table mount =
  Otoml.table
    [
      ("id", Otoml.string mount.id);
      ("host_path", Otoml.string mount.host_dir);
      ("guest_path", Otoml.string mount.guest_path);
      ("mode", Otoml.string (hotmount_mode_name mount.mode));
      ("owners", string_array mount.owners);
    ]

let runtime_state_table state =
  Otoml.table
    [
      ("spaces", string_array state.spaces);
      ( "mounts",
        Otoml.TomlTableArray (List.map runtime_mount_table state.mounts) );
    ]

let runtime_table_string fields key =
  match List.assoc_opt key fields with
  | Some (Otoml.TomlString value) -> value
  | _ -> Log.fatal "ash-state.toml runtime mount is missing string field %s" key

let runtime_table_strings fields key =
  match List.assoc_opt key fields with
  | Some (Otoml.TomlArray values) ->
      List.map
        (function
          | Otoml.TomlString value -> value
          | _ ->
              Log.fatal
                "ash-state.toml runtime mount field %s must contain strings" key)
        values
  | _ ->
      Log.fatal "ash-state.toml runtime mount is missing string array field %s"
        key

let runtime_mount_of_table = function
  | Otoml.TomlTable fields | Otoml.TomlInlineTable fields ->
      let id = runtime_table_string fields "id" in
      let host_dir = runtime_table_string fields "host_path" in
      let guest_path = runtime_table_string fields "guest_path" in
      let mode = hotmount_mode_of_string (runtime_table_string fields "mode") in
      let owners = runtime_table_strings fields "owners" in
      if id <> hotmount_slug ~host_dir ~guest_path then
        Log.fatal
          "ash-state.toml runtime mount id %S does not match its host and \
           guest paths"
          id;
      if Filename.is_relative host_dir || Filename.is_relative guest_path then
        Log.fatal "ash-state.toml runtime mount paths must be absolute";
      { id; host_dir; guest_path; mode; owners }
  | _ -> Log.fatal "ash-state.toml runtime.mounts must contain tables"

let legacy_runtime_mounts ~name =
  let dir = legacy_hotmount_metadata_dir ~name in
  if not (Sys.file_exists dir) then []
  else
    Sys.readdir dir |> Array.to_list |> List.sort String.compare
    |> List.filter (fun entry -> Filename.check_suffix entry ".meta")
    |> List.filter_map (fun entry ->
        let path = Filename.concat dir entry in
        try
          match
            In_channel.with_open_text path In_channel.input_all
            |> String.split_on_char '\n'
          with
          | guest_path :: host_dir :: mode_name :: id :: _ ->
              let mode =
                match mode_name with
                | "ro" -> Some Read_only
                | "rw" -> Some Read_write
                | _ -> None
              in
              if
                mode = None
                || Filename.is_relative guest_path
                || Filename.is_relative host_dir
                || id <> hotmount_slug ~host_dir ~guest_path
              then (
                Log.warn "ignoring invalid legacy hotmount metadata %s" path;
                None)
              else
                Some
                  {
                    id;
                    guest_path;
                    host_dir;
                    mode = Option.get mode;
                    owners = [ manual_mount_owner ];
                  }
          | _ ->
              Log.warn "ignoring invalid legacy hotmount metadata %s" path;
              None
        with Sys_error err ->
          Log.warn "ignoring unreadable legacy hotmount metadata %s: %s" path
            err;
          None)

let runtime_state_of_doc doc =
  let spaces =
    Otoml.find_opt doc
      (Otoml.get_array Otoml.get_string)
      [ "runtime"; "spaces" ]
    |> Option.value ~default:[]
  in
  let mounts =
    match Otoml.find_opt doc Fun.id [ "runtime"; "mounts" ] with
    | None -> []
    | Some (Otoml.TomlTableArray values | Otoml.TomlArray values) ->
        List.map runtime_mount_of_table values
    | Some _ -> Log.fatal "ash-state.toml runtime.mounts must be a table array"
  in
  { spaces; mounts }

let load_runtime_mount_state ~name =
  let path = ash_config_path ~name in
  if not (Sys.file_exists path) then empty_runtime_mount_state
  else
    let doc = load_manifest_doc path in
    if Otoml.path_exists doc [ "runtime" ] then runtime_state_of_doc doc
    else { spaces = []; mounts = legacy_runtime_mounts ~name }

let write_runtime_mount_state_unlocked ~name runtime =
  let path = ash_config_path ~name in
  let doc = load_manifest_doc path in
  let doc =
    match doc with
    | Otoml.TomlTable fields ->
        Otoml.TomlTable
          (("runtime", runtime_state_table runtime)
          :: List.remove_assoc "runtime" fields)
    | _ -> Log.fatal "ash-state.toml must contain a TOML table"
  in
  let content =
    "# Generated by ash. Used by `ash regenerate`.\n"
    ^ Otoml.Printer.to_string doc
  in
  Util.atomic_write_file path content

let runtime_mount ~host_dir ~guest_path ~mode ~owners =
  {
    id = hotmount_slug ~host_dir ~guest_path;
    host_dir;
    guest_path;
    mode;
    owners;
  }

let add_owner owner mount =
  if List.mem owner mount.owners then mount
  else { mount with owners = mount.owners @ [ owner ] }

let remove_owner owner mount =
  { mount with owners = List.filter (( <> ) owner) mount.owners }

let find_runtime_mount_by_guest_path state guest_path =
  List.find_opt (fun mount -> mount.guest_path = guest_path) state.mounts

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

let hotmount_inspect_json ~name mount =
  let staging_path = runtime_mount_staging_dir ~name mount in
  `Assoc
    [
      ("id", `String mount.id);
      ("guestPath", `String mount.guest_path);
      ("hostPath", `String mount.host_dir);
      ("mode", `String (hotmount_mode_name mount.mode));
      ("owners", `List (List.map (fun owner -> `String owner) mount.owners));
      ("hostExists", `Bool (Sys.file_exists mount.host_dir));
      ( "hostKind",
        match file_kind mount.host_dir with
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
          ("ip", `Null);
          ("sshConnections", `Null);
          ("sshPtys", `Null);
          ("status", `Null);
          ("guestMountInfo", `Null);
        ]
  | Running ->
      let ip, connections, ptys = vm_stats vm in
      let option_int = function Some value -> `Int value | None -> `Null in
      let option_string = function
        | Some value -> `String value
        | None -> `Null
      in
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
          ("ip", option_string ip);
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
  let runtime_mounts = load_runtime_mount_state ~name in
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
            ( "nixStoreImage",
              inspect_path (Filename.concat vm.path "nix-store.img") );
            ("workspace", inspect_path (workspace_host_dir ~name));
          ] );
      ("runtime", inspect_runtime_json vm);
      ("ash", inspect_toml_file (ash_config_path ~name));
      ("config", inspect_ash_config ~name);
      ("virtle", inspect_toml_file (manifest_path ~name));
      ( "hotmounts",
        `Assoc
          [
            ("stateFile", `String (ash_config_path ~name));
            ( "spaces",
              `List
                (List.map (fun space -> `String space) runtime_mounts.spaces) );
            ( "mounts",
              `List
                (List.map (hotmount_inspect_json ~name) runtime_mounts.mounts)
            );
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
      | Some "shares-ro" -> Some shares_ro_guest_dir
      | Some "shares-rw" -> Some shares_rw_guest_dir
      | _ -> (
          match List.assoc_opt "image" fields with
          | Some (Otoml.TomlTable image | Otoml.TomlInlineTable image) -> (
              match inspect_table_string image "label" with
              | Some "nix-store" -> Some "/nix"
              | _ -> None)
          | _ -> None))

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
        | Some (Otoml.TomlTable image | Otoml.TomlInlineTable image) ->
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
  let ip, connections, ptys = vm_stats vm in
  Printf.printf "%s\n" vm.name;
  inspect_print_field "Status" (status_string vm.status);
  inspect_optional_field "IP" ip;
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
  let nix_store = Filename.concat vm.path "nix-store.img" in
  if Sys.file_exists nix_store then
    inspect_print_field "Nix store image"
      (human_size (state_path_size nix_store));
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
        (inspect_string ash [ "spawn"; "user" ]);
      (match inspect_bool ash [ "spawn"; "kitty" ] with
      | Some true -> inspect_print_field "Kitty SSH" "enabled"
      | Some false | None -> ());
      inspect_optional_field "Waypipe"
        (inspect_string ash [ "spawn"; "waypipe" ]));
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
  let runtime_mounts = load_runtime_mount_state ~name in
  Printf.printf "\nRuntime mounts (%d; spaces: %s)\n"
    (List.length runtime_mounts.mounts)
    (match runtime_mounts.spaces with
    | [] -> "(none)"
    | spaces -> String.concat "," spaces);
  List.iter
    (fun mount ->
      let staging = runtime_mount_staging_dir ~name mount in
      let annotations =
        [
          (if Sys.file_exists mount.host_dir then None else Some "host missing");
          (match host_mountpoint_state staging with
          | `Bool true -> Some "staged"
          | _ -> None);
          Some ("owners=" ^ String.concat "," mount.owners);
        ]
        |> List.filter_map Fun.id
      in
      let suffix = " [" ^ String.concat ", " annotations ^ "]" in
      Printf.printf "  - %s -> %s (%s)%s\n" mount.host_dir mount.guest_path
        (hotmount_mode_name mount.mode)
        suffix)
    runtime_mounts.mounts;
  flush stdout

let inspect_vm ~json ~name =
  if json then (
    inspect_vm_json ~name |> Yojson.Safe.pretty_to_channel stdout;
    output_char stdout '\n';
    flush stdout)
  else inspect_vm_human ~name

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

let runtime_mount_action ~name:action_name mount =
  let read_only = mount.mode = Read_only in
  Qga.mount_shared_path_action ~name:action_name
    ~share_tag:(if read_only then "shares-ro" else "shares-rw")
    ~share_guest_dir:
      (if read_only then shares_ro_guest_dir else shares_rw_guest_dir)
    ~relative_source:(Filename.concat "mounts/hotmounts" mount.id)
    ~guest_path:mount.guest_path ~read_only

let realize_runtime_mount ~bindfs ~virtle ~manifest_path ~name mount =
  let staging = runtime_mount_staging_dir ~name mount in
  ensure_bindfs_mount ~bindfs ~mode:mount.mode ~source:mount.host_dir
    ~target:staging;
  let action = runtime_mount_action ~name:"ash-runtime-mount" mount in
  let output =
    virtle_rpc ~virtle ~path:manifest_path ~method_name:"guest-exec"
      ~params:(Qga.params action) ()
  in
  match (Qga.result action output).exit_code with
  | Some 0 ->
      Log.info "mounted %s at %s (%s)" mount.host_dir mount.guest_path
        (hotmount_mode_name mount.mode);
      true
  | Some 42 ->
      Log.info "%s is already mounted" mount.guest_path;
      true
  | _ ->
      Log.warn "failed to realize runtime mount %s at %s: %s" mount.host_dir
        mount.guest_path output;
      false

let ensure_runtime_target_not_static ~name guest_path =
  let saved = load_manifest_doc (ash_config_path ~name) in
  let manifest = load_manifest_doc (manifest_path ~name) in
  let config_path = string_of_doc saved [ "spawn"; "config_path" ] in
  let spaces = string_array_of_doc saved [ "spawn"; "spaces" ] in
  let mount_cwd = bool_of_doc saved [ "spawn"; "mount_cwd" ] in
  let user = manifest_string manifest [ "ssh"; "user" ] in
  let resources =
    Ash_config.load_for_spaces config_path spaces |> fun config ->
    Ash_config.resources_for_spaces ~guest_user:user config spaces
  in
  let targets =
    Filename.concat (Ash_config.guest_home user) "workspace"
    :: (if mount_cwd then [ "/mnt/cwd" ] else [])
    @ List.map (fun (mount : Ash_config.mount) -> mount.target) resources.mounts
  in
  if List.mem guest_path targets then
    Log.fatal
      "guest path %S is already provided by a launch-time mount; remove it \
       from the VM's selected spaces before adding a runtime mount"
      guest_path

let add_runtime_mount_claim ~bindfs ~virtle ~manifest_path ~name ~owner ~mode
    ~host_dir ~guest_path =
  let host_dir = normalize_hotmount_host_dir host_dir in
  ensure_runtime_target_not_static ~name guest_path;
  let desired = runtime_mount ~host_dir ~guest_path ~mode ~owners:[ owner ] in
  let state = load_runtime_mount_state ~name in
  let mount, mounts =
    match find_runtime_mount_by_guest_path state guest_path with
    | Some existing when existing.host_dir <> host_dir || existing.mode <> mode
      ->
        Log.fatal "guest path %S is already assigned to host directory %S (%s)"
          guest_path existing.host_dir
          (hotmount_mode_name existing.mode)
    | Some existing ->
        let mount = add_owner owner existing in
        ( mount,
          List.map
            (fun current -> if current.id = existing.id then mount else current)
            state.mounts )
    | None -> (desired, state.mounts @ [ desired ])
  in
  write_runtime_mount_state_unlocked ~name { state with mounts };
  if not (realize_runtime_mount ~bindfs ~virtle ~manifest_path ~name mount) then
    Log.fatal
      "saved runtime mount state, but could not realize %s; it will be retried \
       on the next start"
      guest_path;
  mount

let hotmount_path ~bindfs ~virtle ~manifest_path ~name ~owner ~mode ~host_dir
    ~guest_path () =
  with_state_lock ~name (fun () ->
      let mount =
        add_runtime_mount_claim ~bindfs ~virtle ~manifest_path ~name ~owner
          ~mode ~host_dir ~guest_path
      in
      Printf.printf "%s -> %s (%s)\n" mount.host_dir mount.guest_path
        (hotmount_mode_name mount.mode))

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
  hotmount_path ~bindfs ~virtle ~manifest_path ~name ~owner:manual_mount_owner
    ~mode ~host_dir ~guest_path ()

let try_unmount_hotmount_staging = try_unmount_staging

let unmount_hotmount_staging mount_dir =
  if not (try_unmount_hotmount_staging mount_dir) then
    Log.fatal "failed to unmount host staging path %S" mount_dir

let cleanup_orphan_hotmount_staging ~name records =
  let cleanup read_only =
    let desired =
      records
      |> List.filter (fun mount -> mount.mode = Read_only = read_only)
      |> List.map (fun mount -> mount.id)
    in
    let dir =
      Filename.concat (shares_mounts_dir ~name ~read_only) "hotmounts"
    in
    if Sys.file_exists dir then
      Sys.readdir dir |> Array.to_list
      |> List.filter (fun entry -> not (List.mem entry desired))
      |> List.iter (fun entry ->
          let path = Filename.concat dir entry in
          try
            if (Unix.lstat path).st_kind = Unix.S_DIR then
              if try_unmount_hotmount_staging path then (
                (try Unix.rmdir path with Unix.Unix_error _ -> ());
                Log.info "cleaned orphan runtime staging path %s" path)
              else Log.warn "failed to clean orphan staging path %s" path
          with Unix.Unix_error _ -> ())
  in
  cleanup true;
  cleanup false

let cleanup_legacy_hotmount_state ~name =
  let dir = legacy_hotmounts_dir ~name in
  if Sys.file_exists dir then (
    Sys.readdir dir |> Array.to_list
    |> List.filter (fun entry -> entry <> ".ash")
    |> List.iter (fun entry ->
        let path = Filename.concat dir entry in
        if try_unmount_hotmount_staging path then
          try Util.remove_tree ~force:true path with _ -> ());
    Util.remove_tree ~force:true dir)

let restore_hotmounts ~virtle ~manifest_path ~name =
  with_state_lock ~name (fun () ->
      let state = load_runtime_mount_state ~name in
      (* Writing the complete state also migrates legacy per-mount sidecars into
         ash-state.toml before any old staging paths are removed. *)
      write_runtime_mount_state_unlocked ~name state;
      cleanup_orphan_hotmount_staging ~name state.mounts;
      match state.mounts with
      | [] -> cleanup_legacy_hotmount_state ~name
      | mounts -> (
          match Util.find_in_path "bindfs" with
          | None ->
              Log.warn
                "cannot restore %d runtime mount(s): bindfs is not available \
                 in PATH"
                (List.length mounts)
          | Some bindfs ->
              let restored = ref 0 in
              let failed = ref 0 in
              List.iter
                (fun mount ->
                  if not (Sys.file_exists mount.host_dir) then (
                    incr failed;
                    Log.warn
                      "cannot restore runtime mount %s: host directory %S does \
                       not exist"
                      mount.guest_path mount.host_dir)
                  else if
                    realize_runtime_mount ~bindfs ~virtle ~manifest_path ~name
                      mount
                  then incr restored
                  else incr failed)
                mounts;
              if !failed = 0 then cleanup_legacy_hotmount_state ~name;
              Log.info
                "runtime mount restoration complete: %d restored, %d failed"
                !restored !failed))

let hotunmount_path ~virtle ~manifest_path ~name ~owner ~guest_path () =
  with_state_lock ~name (fun () ->
      let state = load_runtime_mount_state ~name in
      match find_runtime_mount_by_guest_path state guest_path with
      | None -> Log.warn "no runtime mount found for %s" guest_path
      | Some mount when not (List.mem owner mount.owners) ->
          Log.warn "runtime mount %s is not owned by %s" guest_path owner
      | Some mount ->
          let updated = remove_owner owner mount in
          let mounts =
            if updated.owners = [] then
              List.filter (fun current -> current.id <> mount.id) state.mounts
            else
              List.map
                (fun current ->
                  if current.id = mount.id then updated else current)
                state.mounts
          in
          let next = { state with mounts } in
          write_runtime_mount_state_unlocked ~name next;
          if updated.owners <> [] then
            Log.info "kept %s mounted for remaining owners: %s" guest_path
              (String.concat "," updated.owners)
          else
            let action =
              Qga.unmount_action ~name:"ash-runtime-unmount" ~guest_path
            in
            let output =
              try
                virtle_rpc ~virtle ~path:manifest_path ~method_name:"guest-exec"
                  ~params:(Qga.params action) ()
              with exn ->
                write_runtime_mount_state_unlocked ~name state;
                raise exn
            in
            (match (Qga.result action output).exit_code with
            | Some 0 -> Log.info "unmounted guest path %s" guest_path
            | Some 42 -> Log.info "%s is not a mountpoint in guest" guest_path
            | _ ->
                write_runtime_mount_state_unlocked ~name state;
                Log.fatal "failed to unmount guest path %s: %s" guest_path
                  output);
            let staging = runtime_mount_staging_dir ~name mount in
            unmount_hotmount_staging staging;
            (try Unix.rmdir staging with Unix.Unix_error _ -> ());
            Log.info "unmounted host staging path %s" staging;
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
  hotunmount_path ~virtle ~manifest_path ~name ~owner:manual_mount_owner
    ~guest_path ()

let space_resources_for_running_vm ~name ~manifest_path spaces =
  let saved_doc = load_manifest_doc (ash_config_path ~name) in
  let config_path = string_of_doc saved_doc [ "spawn"; "config_path" ] in
  let config = Ash_config.load config_path in
  let user =
    manifest_string (load_manifest_doc manifest_path) [ "ssh"; "user" ]
  in
  Ash_config.resources_for_spaces ~guest_user:user config spaces

let add_space_mount_to_state ~space state (mount : Ash_config.mount) =
  let owner = space_mount_owner space in
  let mode = if mount.read_only then Read_only else Read_write in
  let host_dir = normalize_hotmount_host_dir mount.source in
  match find_runtime_mount_by_guest_path state mount.target with
  | Some existing when existing.host_dir <> host_dir || existing.mode <> mode ->
      Log.fatal "guest path %S is already assigned to host directory %S (%s)"
        mount.target existing.host_dir
        (hotmount_mode_name existing.mode)
  | Some existing ->
      let updated = add_owner owner existing in
      {
        state with
        mounts =
          List.map
            (fun current ->
              if current.id = existing.id then updated else current)
            state.mounts;
      }
  | None ->
      let mount =
        runtime_mount ~host_dir ~guest_path:mount.target ~mode ~owners:[ owner ]
      in
      { state with mounts = state.mounts @ [ mount ] }

let hotmount_spaces ?virtle ~name ~spaces () =
  let spaces =
    List.fold_left
      (fun unique space ->
        if List.mem space unique then unique else unique @ [ space ])
      [] spaces
  in
  if spaces = [] then Log.fatal "mount-space requires at least one SPACE";
  let bindfs = find_bindfs () in
  let virtle = find_virtle virtle in
  let name, manifest_path = select_attach_vm (Some name) in
  let resolved =
    List.map
      (fun space ->
        let resources =
          space_resources_for_running_vm ~name ~manifest_path [ space ]
        in
        (space, resources.mounts))
      spaces
  in
  List.iter
    (fun (_, mounts) ->
      List.iter
        (fun (mount : Ash_config.mount) ->
          ensure_runtime_target_not_static ~name mount.target)
        mounts)
    resolved;
  with_state_lock ~name (fun () ->
      let previous = load_runtime_mount_state ~name in
      let requested_owners = List.map space_mount_owner spaces in
      let base =
        {
          spaces =
            List.filter
              (fun space -> not (List.mem space spaces))
              previous.spaces;
          mounts =
            previous.mounts
            |> List.map (fun mount ->
                List.fold_left
                  (fun current owner -> remove_owner owner current)
                  mount requested_owners)
            |> List.filter (fun mount -> mount.owners <> []);
        }
      in
      let desired =
        List.fold_left
          (fun state (space, mounts) ->
            let state =
              List.fold_left (add_space_mount_to_state ~space) state mounts
            in
            { state with spaces = state.spaces @ [ space ] })
          base resolved
      in
      write_runtime_mount_state_unlocked ~name desired;
      let obsolete =
        List.filter
          (fun old ->
            not
              (List.exists
                 (fun current -> current.id = old.id && current.mode = old.mode)
                 desired.mounts))
          previous.mounts
      in
      let failures = ref 0 in
      List.iter
        (fun mount ->
          let action =
            Qga.unmount_action ~name:"ash-runtime-space-refresh"
              ~guest_path:mount.guest_path
          in
          let output =
            virtle_rpc ~virtle ~path:manifest_path ~method_name:"guest-exec"
              ~params:(Qga.params action) ()
          in
          match (Qga.result action output).exit_code with
          | Some 0 | Some 42 -> (
              let staging = runtime_mount_staging_dir ~name mount in
              unmount_hotmount_staging staging;
              try Unix.rmdir staging with Unix.Unix_error _ -> ())
          | _ ->
              incr failures;
              Log.warn "failed to replace old runtime space path %s: %s"
                mount.guest_path output)
        obsolete;
      let requested_mounts =
        List.filter
          (fun mount ->
            List.exists
              (fun owner -> List.mem owner mount.owners)
              requested_owners)
          desired.mounts
      in
      List.iter
        (fun mount ->
          if
            not
              (realize_runtime_mount ~bindfs ~virtle ~manifest_path ~name mount)
          then incr failures)
        requested_mounts;
      if !failures <> 0 then
        Log.fatal
          "saved runtime space state, but failed to reconcile %d mount(s); \
           they will be retried on the next start"
          !failures;
      Printf.printf "mounted runtime spaces: %s\n" (String.concat "," spaces))

let hotunmount_spaces ?virtle ~name ~spaces () =
  let spaces =
    List.fold_left
      (fun unique space ->
        if List.mem space unique then unique else unique @ [ space ])
      [] spaces
  in
  if spaces = [] then Log.fatal "umount-space requires at least one SPACE";
  let bindfs = find_bindfs () in
  let virtle = find_virtle virtle in
  let name, manifest_path = select_attach_vm (Some name) in
  with_state_lock ~name (fun () ->
      let previous = load_runtime_mount_state ~name in
      let owners = List.map space_mount_owner spaces in
      let updated_mounts =
        List.map
          (fun mount ->
            List.fold_left (fun m owner -> remove_owner owner m) mount owners)
          previous.mounts
      in
      let removed, retained =
        List.partition (fun mount -> mount.owners = []) updated_mounts
      in
      let desired =
        {
          spaces =
            List.filter
              (fun space -> not (List.mem space spaces))
              previous.spaces;
          mounts = retained;
        }
      in
      write_runtime_mount_state_unlocked ~name desired;
      let restore_previous () =
        write_runtime_mount_state_unlocked ~name previous;
        List.iter
          (fun mount ->
            ignore
              (realize_runtime_mount ~bindfs ~virtle ~manifest_path ~name mount))
          removed
      in
      let failed = ref false in
      (try
         List.iter
           (fun mount ->
             let action =
               Qga.unmount_action ~name:"ash-runtime-space-unmount"
                 ~guest_path:mount.guest_path
             in
             let output =
               virtle_rpc ~virtle ~path:manifest_path ~method_name:"guest-exec"
                 ~params:(Qga.params action) ()
             in
             match (Qga.result action output).exit_code with
             | Some 0 | Some 42 -> (
                 let staging = runtime_mount_staging_dir ~name mount in
                 unmount_hotmount_staging staging;
                 try Unix.rmdir staging with Unix.Unix_error _ -> ())
             | _ ->
                 failed := true;
                 Log.warn "failed to unmount runtime space path %s: %s"
                   mount.guest_path output)
           removed
       with exn ->
         restore_previous ();
         raise exn);
      if !failed then (
        restore_previous ();
        Log.fatal
          "failed to unmount one or more runtime space paths; restored desired \
           state");
      Printf.printf "unmounted runtime spaces: %s\n" (String.concat "," spaces))

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

type copy_source = Host | Guest

let copy_source_name = function Host -> "host" | Guest -> "guest"

let scp_args ~wrapper ~identity ~host_name ~recursive ~source ~destination =
  [
    "-S";
    wrapper;
    "-i";
    identity;
    "-o";
    "IdentitiesOnly=yes";
    "-o";
    "HostName=" ^ host_name;
  ]
  @ (if recursive then [ "-r" ] else [])
  @ [ "--"; source; destination ]

let copy ?virtle ~name ~recursive ~verbose ~from_path ~to_path ~source () =
  let virtle = find_virtle virtle in
  let scp = find_scp () in
  let name, path = select_attach_vm (Some name) in
  let status = rpc_status ~virtle ~path () in
  let cid =
    match Qga.int_field ~field:"cid" status with
    | Some cid when cid > 0 -> cid
    | _ -> Log.fatal "could not read VM cid from virtle status: %s" status
  in
  let doc = load_manifest_doc path in
  let user = manifest_string doc [ "ssh"; "user" ] in
  let identity = install_ssh_key ~virtle ~path ~name ~user in
  let wrapper = space_mount_ssh_wrapper_path ~name in
  if not (Sys.file_exists wrapper) then
    Log.fatal "missing SSH wrapper %s; run `ash regenerate %s`" wrapper name;
  (* scp treats a colon as remote syntax only when it appears before any slash.
     Use a slash-free alias in the operand, then let ssh resolve it to the
     virtle vsock address through HostName. *)
  let host_name = "vsock/" ^ string_of_int cid in
  let remote_alias = "ash-vm-" ^ string_of_int cid in
  let guest_path path = user ^ "@" ^ remote_alias ^ ":" ^ path in
  let source_path, destination_path =
    match source with
    | Host -> (from_path, guest_path to_path)
    | Guest -> (guest_path from_path, to_path)
  in
  let code =
    Util.run_foreground scp
      (scp_args ~wrapper ~identity ~host_name ~recursive ~source:source_path
         ~destination:destination_path)
  in
  if code = 0 && verbose then
    Printf.printf "%s:%s -> %s:%s\n%!" (copy_source_name source) from_path
      (copy_source_name (match source with Host -> Guest | Guest -> Host))
      to_path;
  exit code

let attach_running_code ?virtle ~name ~path ~kitty ~waypipe ~verbose () =
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
    if kitty || Option.is_some waypipe then (
      let ssh_wrapper = space_mount_ssh_wrapper_path_for ~kitty ~name in
      if not (Sys.file_exists ssh_wrapper) then
        Log.fatal "missing SSH wrapper %s; run `ash regenerate %s`" ssh_wrapper
          name;
      match waypipe with
      | Some waypipe ->
          [ write_waypipe_ssh_wrapper ~waypipe ~ssh_wrapper ~kitty ~name ]
      | None -> [ ssh_wrapper ])
    else manifest_string_array doc [ "ssh"; "exec" ]
  in
  let identity = install_ssh_key ~virtle ~path ~name ~user in
  let identity_args = [ "-i"; identity; "-o"; "IdentitiesOnly=yes" ] in
  let destination = user ^ "@vsock/" ^ string_of_int cid in
  let verbose_args = List.map (fun _ -> "-v") verbose in
  match ssh_exec with
  | [] -> Log.fatal "manifest ssh.exec is empty"
  | program :: args ->
      Util.run_foreground program
        (args @ identity_args @ verbose_args @ [ destination ])

let attach_running ?virtle ~name ~path ~kitty ~waypipe ~verbose () =
  exit (attach_running_code ?virtle ~name ~path ~kitty ~waypipe ~verbose ())

let portal_profile_path = "/etc/profile.d/ash-agent-portal.sh"

let portal_nushell_path user =
  Filename.concat (guest_home user)
    ".local/share/nushell/vendor/autoload/ash-agent-portal.nu"

let manifest_write_file ?chown ~guest_path ~text ~mode () =
  let fields =
    [
      ("guest_path", Otoml.string guest_path);
      ("text", Otoml.string text);
      ("mode", Otoml.string mode);
      ("overwrite", Otoml.boolean true);
    ]
  in
  let fields =
    match chown with
    | Some owner -> fields @ [ ("chown", Otoml.string owner) ]
    | None -> fields
  in
  Otoml.table fields

let portal_write_file ?chown ~guest_path text =
  manifest_write_file ?chown ~guest_path ~text ~mode:"0644" ()

let configured_write_file (file : Ash_config.write_file) =
  manifest_write_file ?chown:file.chown ~guest_path:file.guest_path
    ~text:file.text ~mode:file.mode ()

let portal_dbus_socket_path name =
  let runtime_dir =
    match Sys.getenv_opt "XDG_RUNTIME_DIR" with
    | Some path when path <> "" -> path
    | _ -> Printf.sprintf "/run/user/%d" (Unix.getuid ())
  in
  let digest = Digest.to_hex (Digest.string name) in
  Filename.concat
    (Filename.concat runtime_dir "ash-dbus-proxy")
    (String.sub digest 0 16 ^ ".sock")

let portal_dbus_profile =
  "export \
   DBUS_SESSION_BUS_ADDRESS=\"unix:path=${XDG_RUNTIME_DIR:-/run/user/$(id \
   -u)}/ash-dbus-proxy/bus.sock\"\n"

let portal_dbus_nushell =
  "let ash_dbus_runtime = ($env.XDG_RUNTIME_DIR? | default $\"/run/user/(id \
   -u)\")\n\
   $env.DBUS_SESSION_BUS_ADDRESS = \
   $\"unix:path=($ash_dbus_runtime)/ash-dbus-proxy/bus.sock\"\n"

let portal_dbus_run inputs portal =
  if not portal.Agent_portal.Config.dbus_notifications then []
  else
    let executable =
      match inputs.portal_dbus_proxy with
      | Some path -> path
      | None ->
          Log.fatal
            "Portal D-Bus notifications are enabled but ash-dbus-proxy was not \
             resolved"
    in
    [
      Otoml.table
        [
          ( "exec",
            string_array
              [
                executable;
                "host";
                "--socket";
                portal_dbus_socket_path inputs.name;
                "--cid";
                "{{.CID}}";
                "--managed";
              ] );
        ];
    ]

let portal_environment_files ~user ~profile ~nushell =
  let owner = if user = "root" then "root:root" else user ^ ":users" in
  [
    portal_write_file ~guest_path:portal_profile_path profile;
    portal_write_file ~chown:owner ~guest_path:(portal_nushell_path user)
      nushell;
  ]

let portal_manifest_fields inputs state_dir configured_files =
  let user = Option.value inputs.user ~default:inputs.target.host_name in
  match Ash_config.portal inputs.config with
  | None ->
      if configured_files = [] then []
      else [ ("write_files", Otoml.TomlTableArray configured_files) ]
  | Some portal when not portal.enabled ->
      [
        ( "write_files",
          Otoml.TomlTableArray
            (configured_files
            @ portal_environment_files ~user
                ~profile:
                  "# Generated by ash. Portal disabled.\n\
                   unset AGENT_PORTAL_VSOCK AGENT_PORTAL_SOCKET \
                   DBUS_SESSION_BUS_ADDRESS\n"
                ~nushell:
                  "# Generated by ash. Portal disabled.\n\
                   hide-env --ignore-errors AGENT_PORTAL_VSOCK \
                   AGENT_PORTAL_SOCKET DBUS_SESSION_BUS_ADDRESS\n") );
      ]
  | Some portal ->
      let host_cid = portal.vsock_cid in
      let endpoint, runs =
        if portal.global then (
          if portal.transport <> Agent_portal.Config.Vsock then
            Log.fatal
              "[portal] global mode requires transport = \"vsock\" for Ash VM \
               integration";
          (Printf.sprintf "%d:%d" host_cid portal.vsock_port, []))
        else
          let portal_host =
            match inputs.portal_host with
            | Some path -> path
            | None ->
                Log.fatal
                  "managed Portal is enabled but agent-portal-host was not \
                   resolved"
          in
          let endpoint = Printf.sprintf "managed:%d" host_cid in
          let run =
            Otoml.table
              [
                ( "exec",
                  string_array
                    [
                      portal_host;
                      "-c";
                      Util.expand_home inputs.config_path |> Util.absolute_path;
                      "--vsock-port-for-cid";
                      "{{.CID}}";
                      "--log-file";
                      Filename.concat state_dir "portal.log";
                    ] );
              ]
          in
          (endpoint, [ run ])
      in
      let dbus_profile, dbus_nushell =
        if portal.dbus_notifications then
          (portal_dbus_profile, portal_dbus_nushell)
        else
          ( "unset DBUS_SESSION_BUS_ADDRESS\n",
            "hide-env --ignore-errors DBUS_SESSION_BUS_ADDRESS\n" )
      in
      let files =
        portal_environment_files ~user
          ~profile:
            (Printf.sprintf
               "# Generated by ash.\nexport AGENT_PORTAL_VSOCK=%s\n%s" endpoint
               dbus_profile)
          ~nushell:
            (Printf.sprintf
               "# Generated by ash.\n\
                $env.AGENT_PORTAL_VSOCK = %S\n\
                hide-env --ignore-errors AGENT_PORTAL_SOCKET\n\
                %s"
               endpoint dbus_nushell)
      in
      let runs = runs @ portal_dbus_run inputs portal in
      [ ("write_files", Otoml.TomlTableArray (configured_files @ files)) ]
      @ if runs = [] then [] else [ ("run", Otoml.TomlTableArray runs) ]

let render_resolved_manifest inputs =
  let config = inputs.config in
  let spaces = inputs.spaces in
  let state_dir = state_dir inputs.name in
  let virtle_state_dir = virtle_state_dir inputs.name in
  let memory = Ash_config.global_memory config in
  let vcpu = Util.command_output "nproc" |> int_of_string in
  let network_bridge = Ash_config.global_network_bridge config in
  let qemu_bridge_helper = Ash_config.global_qemu_bridge_helper config in
  let network_mac = network_mac inputs.name in
  let user = Option.value inputs.user ~default:inputs.target.host_name in
  let target = inputs.target in
  let boot = inputs.boot in
  let resources =
    Ash_config.resources_for_spaces ~guest_user:user config spaces
  in
  let kitty = inputs.kitty || Ash_config.global_kitty config in
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
  let workspace_host_dir = workspace_host_dir ~name:inputs.name in
  let store_strategy = inputs.nix_store_strategy in
  let shares_ro_socket =
    Option.value inputs.ro_store_socket ~default:"shares-ro.sock"
  in
  let shares_ro_host_dir = shares_ro_dir ~name:inputs.name in
  let shares_rw_host_dir = shares_rw_dir ~name:inputs.name in
  migrate_state_path
    ~old_path:(Filename.concat state_dir "workspace")
    ~new_path:workspace_host_dir;
  List.iter
    (fun entry ->
      migrate_state_path
        ~old_path:(Filename.concat shares_ro_host_dir entry)
        ~new_path:
          (Filename.concat
             (shares_system_dir ~name:inputs.name ~read_only:true)
             entry))
    [ "guest-store-state" ];
  List.iter
    (fun entry ->
      migrate_state_path
        ~old_path:(Filename.concat shares_rw_host_dir entry)
        ~new_path:
          (Filename.concat
             (shares_system_dir ~name:inputs.name ~read_only:false)
             entry))
    [ "guest-store-state"; "guest-store-upper"; "guest-store-work" ];
  Util.ensure_dir shares_ro_host_dir;
  Util.ensure_dir shares_rw_host_dir;
  Util.ensure_dir workspace_host_dir;
  let shares_rw_identity = shares_rw_identity () in
  if store_strategy = Ash_config.Shared then
    ignore
      (prepare_guest_store_dirs shares_rw_identity
         (shares_system_dir ~name:inputs.name ~read_only:false));
  let workspace_mount =
    workspace_mount ~workspace_guest_dir ~workspace_host_dir
  in
  let cwd_mount =
    {
      Ash_config.tag = "workspace_cwd";
      source = Sys.getcwd ();
      target = "/mnt/cwd";
      read_only = false;
    }
  in
  let launch_targets =
    workspace_mount.target
    :: (if inputs.mount_cwd then [ cwd_mount.target ] else [])
    @ List.map (fun (mount : Ash_config.mount) -> mount.target) resources.mounts
  in
  (if has_saved_ash_config ~name:inputs.name then
     load_runtime_mount_state ~name:inputs.name |> fun runtime ->
     List.iter
       (fun mount ->
         if List.mem mount.guest_path launch_targets then
           Log.fatal
             "runtime mount target %S conflicts with a launch-time workspace \
              or space mount; remove one of the conflicting desired mounts"
             mount.guest_path)
       runtime.mounts);
  let store_mounts =
    match store_strategy with
    | Ash_config.Shared -> []
    | Ash_config.Image ->
        [
          image_mount
            ~source:(Filename.concat state_dir "nix-store.img")
            ~size:inputs.nix_store_image_size_mib ~label:"nix-store";
        ]
  in
  let kernel_params =
    List.filter
      (fun value ->
        (not (is_nix_store_kernel_param value))
        && not (is_mdns_kernel_param value))
      boot.kernel_params
    @ nix_store_kernel_param store_strategy
      :: mdns_kernel_params ~name:inputs.name ~mac:network_mac
  in
  let mounts =
    [
      virtiofs_mount ~virtle_defaults:true ~tag:"shares-ro"
        ~source:shares_ro_host_dir ~read_only:true ~socket:shares_ro_socket
        ~bin:inputs.virtiofsd ();
      virtiofs_mount ~virtle_defaults:true ~tag:"shares-rw"
        ~source:shares_rw_host_dir ~read_only:false ~socket:"shares-rw.sock"
        ~bin:inputs.virtiofsd ();
    ]
    @ store_mounts
    @ [
        image_mount
          ~source:(Filename.concat state_dir "persist.img")
          ~size:16384 ~label:"persist";
      ]
  in
  let ssh_mounts =
    (workspace_mount :: (if inputs.mount_cwd then [ cwd_mount ] else []))
    @ resources.mounts
  in
  let ssh_wrapper =
    write_space_mount_ssh_wrapper ~name:inputs.name ~virtle:inputs.virtle
      ~manifest_path:(manifest_path ~name:inputs.name)
      ~registration_path:boot.registration ~load_registration:true
      ~ssh_exec:real_ssh_exec ssh_mounts
  in
  let kitty_wrapper =
    write_space_mount_ssh_wrapper ~kitty:true ~name:inputs.name
      ~virtle:inputs.virtle
      ~manifest_path:(manifest_path ~name:inputs.name)
      ~registration_path:boot.registration ~load_registration:true
      ~ssh_exec:kitty_ssh_exec ssh_mounts
  in
  let selected_ssh_wrapper = if kitty then kitty_wrapper else ssh_wrapper in
  let selected_ssh_exec =
    match inputs.waypipe with
    | Some waypipe ->
        [
          write_waypipe_ssh_wrapper ~waypipe ~ssh_wrapper:selected_ssh_wrapper
            ~kitty ~name:inputs.name;
        ]
    | None -> [ selected_ssh_wrapper ]
  in
  let document =
    Otoml.table
      [
        ("host_name", Otoml.string target.host_name);
        ("working_dir", Otoml.string ".");
        ("state_dir", Otoml.string virtle_state_dir);
        ( "qemu",
          Otoml.table
            [
              ( "exec",
                string_array
                  [
                    "qemu-system-{{.HostArch}}";
                    "-netdev";
                    Printf.sprintf "bridge,id=ashnet0,br=%s,helper=%s"
                      network_bridge qemu_bridge_helper;
                    "-device";
                    Printf.sprintf "virtio-net-pci,netdev=ashnet0,mac=%s"
                      network_mac;
                  ] );
            ] );
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
                 Otoml.string (string_of_kernel_serial inputs.kernel_serial) );
             ]
            @
            if kernel_params = [] then []
            else [ ("params", string_array kernel_params) ]) );
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
        ("networks", Otoml.array []);
        ("mounts", Otoml.TomlTableArray mounts);
      ]
  in
  let configured_files = List.map configured_write_file resources.write_files in
  let document =
    match document with
    | Otoml.TomlTable fields ->
        Otoml.TomlTable
          (fields @ portal_manifest_fields inputs state_dir configured_files)
    | _ -> assert false
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

let ash_config ?(runtime = empty_runtime_mount_state) (inputs : manifest_inputs)
    =
  let fields =
    [
      ("config_path", Otoml.string inputs.config_path);
      ("flake", Otoml.string inputs.flake);
      ( "override_inputs",
        string_array
          (List.map
             (fun (name, flake) -> name ^ "=" ^ flake)
             inputs.override_inputs) );
      ("name", Otoml.string inputs.name);
      ("spaces", string_array inputs.spaces);
      ( "kernel_serial",
        Otoml.string (string_of_kernel_serial inputs.kernel_serial) );
      ("mount_cwd", Otoml.boolean inputs.mount_cwd);
      ("kitty", Otoml.boolean inputs.kitty);
      ("virtiofsd", Otoml.string inputs.virtiofsd);
      ("virtle", Otoml.string inputs.virtle);
    ]
  in
  let fields =
    match inputs.waypipe with
    | Some waypipe -> fields @ [ ("waypipe", Otoml.string waypipe) ]
    | None -> fields
  in
  let fields =
    match inputs.user with
    | Some user -> fields @ [ ("user", Otoml.string user) ]
    | None -> fields
  in
  let fields =
    match inputs.nix_store_strategy with
    | Some strategy ->
        fields
        @ [
            ( "nix_store_strategy",
              Otoml.string (Ash_config.string_of_nix_store_strategy strategy) );
          ]
    | None -> fields
  in
  let fields =
    match inputs.nix_store_image_size_mib with
    | Some size -> fields @ [ ("nix_store_image_size_mib", Otoml.integer size) ]
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
    @ (match inputs.registration_path with
      | Some registration_path ->
          [
            ( "resolved",
              Otoml.table
                [ ("registration_path", Otoml.string registration_path) ] );
          ]
      | None -> [])
    @ [ ("runtime", runtime_state_table runtime) ]
  in
  "# Generated by ash. Used by `ash regenerate`.\n"
  ^ Otoml.Printer.to_string (Otoml.table tables)

let write_ash_config_unlocked ?runtime (inputs : manifest_inputs) =
  let path = ash_config_path ~name:inputs.name in
  let runtime =
    Option.value runtime ~default:(load_runtime_mount_state ~name:inputs.name)
  in
  let content = ash_config ~runtime inputs in
  Util.atomic_write_file path content;
  Log.debug "wrote ash config %s (%d bytes)" path (String.length content)

let write_ash_config (inputs : manifest_inputs) =
  with_state_lock ~name:inputs.name (fun () -> write_ash_config_unlocked inputs)

let load_ash_config ~name =
  let path = ash_config_path ~name in
  let doc = load_manifest_doc path in
  {
    config_path = string_of_doc doc [ "spawn"; "config_path" ];
    flake = string_of_doc doc [ "spawn"; "flake" ];
    override_inputs =
      Option.value
        (Otoml.find_opt doc
           (Otoml.get_array Otoml.get_string)
           [ "spawn"; "override_inputs" ])
        ~default:[]
      |> List.map (fun value ->
          match String.index_opt value '=' with
          | Some index when index > 0 && index < String.length value - 1 ->
              ( String.sub value 0 index,
                String.sub value (index + 1) (String.length value - index - 1)
              )
          | _ ->
              Log.fatal
                "invalid override input in ash-state.toml: %S (expected \
                 NAME=FLAKE)"
                value);
    name = string_of_doc doc [ "spawn"; "name" ];
    spaces = string_array_of_doc doc [ "spawn"; "spaces" ];
    user = Otoml.find_opt doc Otoml.get_string [ "spawn"; "user" ];
    kernel_serial =
      (match
         Otoml.find_opt doc Otoml.get_string [ "spawn"; "kernel_serial" ]
       with
      | Some value -> kernel_serial_of_string ~field:"spawn.kernel_serial" value
      | None -> (
          match
            Otoml.find_opt doc Otoml.get_boolean [ "spawn"; "print_serial" ]
          with
          | Some true -> Print
          | Some false | None -> Off));
    mount_cwd = bool_of_doc doc [ "spawn"; "mount_cwd" ];
    kitty =
      Option.value
        (Otoml.find_opt doc Otoml.get_boolean [ "spawn"; "kitty" ])
        ~default:false;
    waypipe = Otoml.find_opt doc Otoml.get_string [ "spawn"; "waypipe" ];
    nix_store_strategy =
      Otoml.find_opt doc Otoml.get_string [ "spawn"; "nix_store_strategy" ]
      |> Option.map
           (Ash_config.nix_store_strategy_of_string
              ~field:"spawn.nix_store_strategy");
    nix_store_image_size_mib =
      positive_integer_opt_of_doc doc [ "spawn"; "nix_store_image_size_mib" ];
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

let resolve_spawn_override_inputs ~name override_inputs =
  if override_inputs <> [] then override_inputs
  else if has_saved_ash_config ~name then (
    let saved = load_ash_config ~name in
    Log.debug "using saved override inputs for existing VM %s" name;
    saved.override_inputs)
  else []

let resolve_spawn_spaces ~name spaces =
  if spaces <> [] then spaces
  else if has_saved_ash_config ~name then (
    let saved = load_ash_config ~name in
    Log.debug "using saved spaces for existing VM %s: %s" name
      (String.concat "," saved.spaces);
    saved.spaces)
  else []

let resolve_spawn_nix_store_strategy ~name strategy =
  match strategy with
  | Some _ -> strategy
  | None when has_saved_ash_config ~name ->
      let saved = load_ash_config ~name in
      saved.nix_store_strategy
  | None -> None

let resolve_spawn_nix_store_image_size ~name size =
  let size =
    match size with
    | Some _ -> size
    | None when has_saved_ash_config ~name ->
        let saved = load_ash_config ~name in
        saved.nix_store_image_size_mib
    | None -> None
  in
  match size with
  | Some size when size <= 0 ->
      Log.fatal "nix_store_image_size_mib must be greater than zero"
  | _ -> size

let render_manifest (inputs : manifest_inputs) =
  let config = Ash_config.load_for_spaces inputs.config_path inputs.spaces in
  let portal_host, portal_dbus_proxy =
    match Ash_config.portal config with
    | Some portal when portal.enabled ->
        ( (if portal.global then None else Some (find_agent_portal_host ())),
          if portal.dbus_notifications then Some (find_portal_dbus_proxy ())
          else None )
    | Some _ | None -> (None, None)
  in
  let target = Nix.resolve_target ~flake:inputs.flake in
  let user =
    match inputs.user with
    | Some user ->
        Nix.validate_user ~override_inputs:inputs.override_inputs ~target ~user;
        user
    | None ->
        Nix.resolve_ssh_user ~override_inputs:inputs.override_inputs ~target
  in
  let gcroots_dir = gcroots_dir ~name:inputs.name in
  Util.ensure_dir gcroots_dir;
  let boot =
    Nix.resolve_boot ~override_inputs:inputs.override_inputs ~target
      ~gcroots_dir
  in
  let store_strategy =
    Option.value inputs.nix_store_strategy
      ~default:(Ash_config.global_nix_store_strategy config)
  in
  let store_image_size_mib =
    Option.value inputs.nix_store_image_size_mib
      ~default:(Ash_config.global_nix_store_image_size config)
  in
  (match store_strategy with
  | Ash_config.Shared ->
      let lower_store_state =
        Filename.concat
          (shares_system_dir ~name:inputs.name ~read_only:true)
          "guest-store-state"
      in
      Nix.prepare_lower_store ~nix_store:boot.nix_store
        ~registration:boot.registration ~state:lower_store_state
  | Ash_config.Image ->
      let origin =
        Nix.resolve_image_origin ~nix:boot.nix
          ~override_inputs:inputs.override_inputs ~target
      in
      Nix.prepare_image_store ~nix_executable:boot.nix ~toplevel:boot.toplevel
        ~registration:boot.registration
        ~registration_sha256:boot.registration_sha256
        ~closure_nar_size_bytes:boot.closure_nar_size_bytes
        ~closure_path_count:boot.closure_path_count ~origin
        ~cache_image:(nix_store_image_cache_path ~toplevel:boot.toplevel)
        ~image:(Filename.concat (state_dir inputs.name) "nix-store.img")
        ~size_mib:store_image_size_mib
        ~resize_allowed:
          (not
             (socket_accepts_connection
                (control_socket_path (virtle_state_dir inputs.name))))
        ());
  let ssh = Option.value inputs.ssh ~default:boot.ssh in
  let kitty = inputs.kitty || Ash_config.global_kitty config in
  if kitty then ignore (find_kitten ());
  let systemd_ssh_proxy =
    Option.value inputs.systemd_ssh_proxy ~default:boot.systemd_ssh_proxy
  in
  let rendered =
    render_resolved_manifest
      {
        config;
        config_path = inputs.config_path;
        flake = inputs.flake;
        target;
        boot;
        name = inputs.name;
        spaces = inputs.spaces;
        user = Some user;
        kernel_serial = inputs.kernel_serial;
        mount_cwd = inputs.mount_cwd;
        nix_store_strategy = store_strategy;
        nix_store_image_size_mib = store_image_size_mib;
        ro_store_socket = inputs.ro_store_socket;
        ssh;
        kitty;
        waypipe = inputs.waypipe;
        systemd_ssh_proxy;
        portal_host;
        portal_dbus_proxy;
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
    ?nix_store_strategy ?nix_store_image_size_mib ~config_path ?flake
    ~override_inputs ~spaces ~kernel_serial ~mount_cwd ~kitty ~waypipe () =
  let name = Option.value name ~default:(default_name ()) in
  Log.debug "using VM name: %s" name;
  let flake = Nix.storage_flake_ref (resolve_spawn_flake ~name flake) in
  let override_inputs =
    resolve_spawn_override_inputs ~name override_inputs
    |> List.map (fun (input, flake) -> (input, Nix.storage_flake_ref flake))
  in
  let spaces = resolve_spawn_spaces ~name spaces in
  let nix_store_strategy =
    resolve_spawn_nix_store_strategy ~name nix_store_strategy
  in
  let nix_store_image_size_mib =
    resolve_spawn_nix_store_image_size ~name nix_store_image_size_mib
  in
  let virtle = find_virtle virtle in
  let saved =
    if has_saved_ash_config ~name then Some (load_ash_config ~name) else None
  in
  let kitty =
    kitty
    || Option.fold ~none:false
         ~some:(fun (saved : manifest_inputs) -> saved.kitty)
         saved
  in
  if kitty then ignore (find_kitten ());
  let waypipe =
    if waypipe then Some (find_waypipe ())
    else Option.bind saved (fun (saved : manifest_inputs) -> saved.waypipe)
  in
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
      override_inputs;
      name;
      spaces;
      user;
      kernel_serial;
      mount_cwd;
      nix_store_strategy;
      nix_store_image_size_mib;
      ro_store_socket;
      ssh;
      systemd_ssh_proxy;
      registration_path = None;
      kitty;
      waypipe;
      virtiofsd;
      virtle;
    }
  in
  write_manifest_for_inputs inputs

let validate_console_lifecycle ~kernel_serial ~attach ~keep =
  match kernel_serial with
  | Console when not attach ->
      Error "--kernel-serial=console requires --attach for terminal access"
  | Console when keep ->
      Error "--kernel-serial=console cannot be combined with --keep"
  | Off | Print | Console -> Ok ()

let require_console_lifecycle ~kernel_serial ~attach ~keep =
  match validate_console_lifecycle ~kernel_serial ~attach ~keep with
  | Ok () -> ()
  | Error message -> Log.fatal "%s" message

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

let start_background ~announce ~resume ~name ~virtle ~path ~verbose =
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
  if announce then print_background_started ~name

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

let launch_background ?(announce = true) ~resume (inputs : manifest_inputs) path
    ~verbose =
  prepare_host_share_mounts inputs;
  start_background ~announce ~resume ~name:inputs.name ~virtle:inputs.virtle
    ~path ~verbose;
  wait_and_mount inputs path

let launch_background_and_attach ~resume (inputs : manifest_inputs) path
    ~verbose =
  launch_background ~resume inputs path ~verbose;
  exit
    (attach_running_code ~virtle:inputs.virtle ~name:inputs.name ~path
       ~kitty:false ~waypipe:None ~verbose ())

let start_foreground_setup (inputs : manifest_inputs) path =
  match Unix.fork () with
  | 0 -> (
      try
        wait_and_mount inputs path;
        exit 0
      with exn ->
        Log.error "foreground VM setup failed: %s" (Printexc.to_string exn);
        exit 1)
  | pid -> pid

let finish_foreground_setup pid =
  match Unix.waitpid [ Unix.WNOHANG ] pid with
  | 0, _ ->
      (try Unix.kill pid Sys.sigterm
       with Unix.Unix_error (Unix.ESRCH, _, _) -> ());
      ignore (Unix.waitpid [] pid)
  | _, Unix.WEXITED 0 -> ()
  | _, status ->
      Log.warn "foreground VM setup exited with code %d"
        (Util.process_status_code status)

let launch_foreground_attached ?cleanup_dir ~resume (inputs : manifest_inputs)
    path ~verbose =
  prepare_host_share_mounts inputs;
  let args = launch_args ~resume ~path ~verbose ~ssh:true in
  let setup_pid = start_foreground_setup inputs path in
  let code =
    Fun.protect
      ~finally:(fun () -> finish_foreground_setup setup_pid)
      (fun () -> Util.run_foreground inputs.virtle args)
  in
  Option.iter
    (fun dir ->
      Log.info "removing ephemeral VM state %s" dir;
      Util.remove_tree ~force:true dir)
    cleanup_dir;
  exit code

let spawn ?virtle ?name ?user ?ssh ?systemd_ssh_proxy ?ro_store_socket
    ?nix_store_strategy ?nix_store_image_size_mib ~config_path ?flake
    ~override_inputs ~spaces ~kernel_serial ~mount_cwd ~ephemeral ~attach ~keep
    ~kitty ~waypipe ~verbose () =
  require_console_lifecycle ~kernel_serial ~attach ~keep;
  let inputs, path =
    prepare_spawn ?virtle ?name ?user ?ssh ?systemd_ssh_proxy ?ro_store_socket
      ?nix_store_strategy ?nix_store_image_size_mib ~config_path ?flake
      ~override_inputs ~spaces ~kernel_serial ~mount_cwd ~kitty ~waypipe ()
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
  require_console_lifecycle ~kernel_serial:inputs.kernel_serial ~attach ~keep;
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

let config_default_kitty (inputs : manifest_inputs) =
  Ash_config.load_for_spaces inputs.config_path [] |> Ash_config.global_kitty

let spawn_saved_and_attach ?virtle ~name ~keep ~kitty ~waypipe ~verbose =
  let saved = saved_inputs ?virtle ~name () in
  let inputs =
    {
      saved with
      kitty = kitty || saved.kitty;
      waypipe = (if waypipe then Some (find_waypipe ()) else saved.waypipe);
    }
  in
  require_console_lifecycle ~kernel_serial:inputs.kernel_serial ~attach:true
    ~keep;
  let inputs, path = rewrite_saved_manifest inputs in
  if keep then launch_background_and_attach ~resume:None inputs path ~verbose
  else launch_foreground_attached ~resume:None inputs path ~verbose

let attach ?virtle ?name ~spawn ~keep ~kitty ~waypipe ~verbose () =
  let vms = list_vms () in
  let running = List.filter (fun vm -> vm.status = Running) vms in
  let stopped = List.filter (fun vm -> vm.status = Stopped) vms in
  match select_running_vm ?name running with
  | Some vm ->
      let saved = load_ash_config ~name:vm.name in
      let kitty = kitty || saved.kitty || config_default_kitty saved in
      let waypipe = if waypipe then Some (find_waypipe ()) else saved.waypipe in
      attach_running ?virtle ~name:vm.name
        ~path:(Filename.concat vm.path "virtle.toml")
        ~kitty ~waypipe ~verbose ()
  | None ->
      if not spawn then Log.fatal "no running VMs; use `ash ls` to list states";
      let name = select_stopped_vm_for_spawn ?name stopped in
      spawn_saved_and_attach ?virtle ~name ~keep ~kitty ~waypipe ~verbose

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
    ~mac:(network_mac vm.name)
  |> confirm_stop_with_active_ssh ~name:vm.name ~force;
  let code = Systemd_run.stop_user_unit ~name:vm.name in
  exit code

let remove_nix_store_state ~name =
  let image = Filename.concat (state_dir name) "nix-store.img" in
  let ro_system = shares_system_dir ~name ~read_only:true in
  let rw_system = shares_system_dir ~name ~read_only:false in
  let staged_store = Filename.concat ro_system "nix-store" in
  Log.debug "removing Nix store state for VM %s" name;
  ignore (try_unmount_hotmount_staging staged_store);
  List.iter
    (fun path -> Util.remove_tree ~force:true path)
    [
      staged_store;
      Filename.concat ro_system "guest-store-state";
      Filename.concat rw_system "guest-store-state";
      Filename.concat rw_system "guest-store-upper";
      Filename.concat rw_system "guest-store-work";
      Filename.concat (shares_ro_dir ~name) "guest-store-state";
      Filename.concat (shares_rw_dir ~name) "guest-store-state";
      Filename.concat (shares_rw_dir ~name) "guest-store-upper";
      Filename.concat (shares_rw_dir ~name) "guest-store-work";
    ];
  (try Unix.unlink image with Unix.Unix_error _ -> ());
  Image_metadata.remove image

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

let rebuild_db ?virtle ~name () =
  let name = Util.name_slug name in
  let config_path = ash_config_path ~name in
  if not (Sys.file_exists config_path) then
    Log.fatal "no VM named %S (expected %s)" name config_path;
  if socket_accepts_connection (control_socket_path (virtle_state_dir name))
  then
    Log.fatal
      "VM %S is running; stop it before rebuilding its Nix store database" name;
  remove_nix_store_state ~name;
  regenerate ?virtle ~name ();
  Printf.printf "rebuilt Nix store database for %s\n" name
