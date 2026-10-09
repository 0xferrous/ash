type share = Ro | Rw
type identity = { uid : int; gid : int; name : string }

let share_name = function Ro -> "ro" | Rw -> "rw"

let short_digest value =
  let digest = Digest.to_hex (Digest.string value) in
  String.sub digest 0 10

let service_name ~uid ~state_base ~name share =
  let slug = Util.name_slug name in
  let slug = String.sub slug 0 (min 36 (String.length slug)) in
  Printf.sprintf "ash-virtiofs-%d-%s-%s-%s-%s" uid slug
    (short_digest state_base) (short_digest name) (share_name share)

let socket_path ~state_base ~name share =
  Filename.concat
    (Filename.concat
       (Filename.concat state_base (Util.name_slug name))
       "virtle_state")
    ("shares-" ^ share_name share ^ ".sock")

let share_path ~state_base ~name share =
  Filename.concat
    (Filename.concat
       (Filename.concat
          (Filename.concat state_base "mounts")
          (Util.name_slug name))
       "shares")
    (share_name share)

let required_exe exe =
  match Util.find_in_path exe with
  | Some path -> path
  | None -> failwith (Printf.sprintf "could not find %s" exe)

let pkexec_path () =
  let wrapper = "/run/wrappers/bin/pkexec" in
  if Sys.file_exists wrapper && Util.is_executable wrapper then wrapper
  else required_exe "pkexec"

let effective_user_id () =
  match Sys.getenv_opt "PKEXEC_UID" with
  | Some value -> (
      match int_of_string_opt value with
      | Some uid when uid > 0 -> uid
      | _ -> failwith "pkexec did not provide a valid PKEXEC_UID")
  | None -> failwith "this helper must be invoked by pkexec"

let identity_of_uid uid =
  let pw = Unix.getpwuid uid in
  { uid; gid = pw.Unix.pw_gid; name = pw.Unix.pw_name }

let path_components path =
  if String.length path > 0 && path.[0] = '/' then
    String.split_on_char '/' path |> List.filter (fun part -> part <> "")
  else failwith "expected an absolute path"

let check_safe_ancestors ~uid path =
  let components = path_components path in
  if List.mem ".." components || List.mem "." components then
    failwith "paths containing dot components are not allowed";
  let rec walk current = function
    | [] -> ()
    | component :: rest ->
        let next = Filename.concat current component in
        let stat = Unix.lstat next in
        if stat.Unix.st_kind = Unix.S_LNK then
          failwith (Printf.sprintf "refusing symlink path component %s" next);
        if stat.Unix.st_kind <> Unix.S_DIR then
          failwith (Printf.sprintf "path component is not a directory: %s" next);
        let writable_by_others = stat.Unix.st_perm land 0o022 <> 0 in
        let sticky = stat.Unix.st_perm land 0o1000 <> 0 in
        if
          writable_by_others && stat.Unix.st_uid <> uid
          && not (stat.Unix.st_uid = 0 && sticky)
        then
          failwith (Printf.sprintf "unsafe writable parent directory: %s" next);
        walk next rest
  in
  walk "/" components

let validate_user_state ~require_shares ~uid ~state_base ~name =
  if String.length state_base = 0 || state_base.[0] <> '/' then
    failwith "Ash state directory must be an absolute path";
  if String.contains state_base '\000' then failwith "invalid state directory";
  check_safe_ancestors ~uid state_base;
  let state_base_stat = Unix.stat state_base in
  if state_base_stat.Unix.st_uid <> uid then
    failwith "Ash state directory must be owned by the invoking user";
  let name = Util.name_slug name in
  let directories =
    [
      Filename.concat state_base name;
      Filename.concat (Filename.concat state_base name) "virtle_state";
    ]
    @
    if require_shares then
      [
        Filename.concat state_base "mounts";
        Filename.concat (Filename.concat state_base "mounts") name;
        Filename.concat
          (Filename.concat (Filename.concat state_base "mounts") name)
          "shares";
        share_path ~state_base ~name Ro;
        share_path ~state_base ~name Rw;
      ]
    else []
  in
  List.iter
    (fun directory ->
      check_safe_ancestors ~uid directory;
      let stat = Unix.stat directory in
      if stat.Unix.st_uid <> uid then
        failwith
          (Printf.sprintf "Ash directory must be owned by the invoking user: %s"
             directory))
    directories

let trusted_executable path =
  let real = Unix.realpath path in
  let stat = Unix.stat real in
  if
    Filename.basename real <> "virtiofsd"
    || stat.Unix.st_kind <> Unix.S_REG
    || stat.Unix.st_uid <> 0
    || stat.Unix.st_perm land 0o022 <> 0
    || not (Util.is_executable real)
  then
    failwith
      "virtiofsd must resolve to a root-owned, non-writable executable named \
       virtiofsd";
  check_safe_ancestors ~uid:0 (Filename.dirname real);
  real

let systemd_command () =
  match Util.find_in_path "systemd-run" with
  | Some path -> path
  | None -> failwith "could not find systemd-run in the root environment"

let systemctl_command () =
  match Util.find_in_path "systemctl" with
  | Some path -> path
  | None -> failwith "could not find systemctl in the root environment"

let unit_is_active unit =
  let systemctl = systemctl_command () in
  Util.run_foreground systemctl [ "--system"; "is-active"; "--quiet"; unit ] = 0

let unit_has_process unit =
  let systemctl = systemctl_command () in
  let command =
    String.concat " "
      (List.map Util.shell_quote
         [
           systemctl; "--system"; "show"; "--property=MainPID"; "--value"; unit;
         ])
  in
  try
    Util.command_output ~debug:false command
    |> String.trim |> int_of_string_opt
    |> Option.fold ~none:false ~some:(fun pid -> pid > 0)
  with Failure _ -> false

let stop_system_unit systemctl unit =
  let code = Util.run_foreground systemctl [ "--system"; "stop"; unit ] in
  if code <> 0 then failwith (Printf.sprintf "systemctl stop failed (%d)" code)

let socket_accepts_connection path =
  let fd = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close fd)
    (fun () ->
      try
        Unix.connect fd (Unix.ADDR_UNIX path);
        true
      with Unix.Unix_error _ -> false)

let socket_owned_by_root path =
  try
    let stat = Unix.lstat path in
    stat.Unix.st_kind = Unix.S_SOCK && stat.Unix.st_uid = 0
  with Unix.Unix_error (Unix.ENOENT, _, _) -> false

let pid_file_owned_by_root path =
  try
    let stat = Unix.lstat (path ^ ".pid") in
    stat.Unix.st_kind = Unix.S_REG && stat.Unix.st_uid = 0
  with Unix.Unix_error (Unix.ENOENT, _, _) -> false

let remove_root_socket path =
  if
    Sys.file_exists path
    || try (Unix.lstat path).Unix.st_kind = Unix.S_SOCK with _ -> false
  then
    if socket_owned_by_root path then Unix.unlink path
    else failwith (Printf.sprintf "refusing to remove non-root socket %s" path);
  let pid_path = path ^ ".pid" in
  if Sys.file_exists pid_path then
    let stat = Unix.lstat pid_path in
    if stat.Unix.st_kind <> Unix.S_REG || stat.Unix.st_uid <> 0 then
      failwith (Printf.sprintf "refusing to remove non-root pid file %s" pid_path)
    else Unix.unlink pid_path

let socket_group_arg () =
  try
    ignore (Unix.getgrnam "users");
    "users"
  with Not_found -> failwith "the 'users' group does not exist"

let user_belongs_to_socket_group () =
  try
    let group = Unix.getgrnam "users" in
    let gids = Unix.getgroups () in
    Unix.getgid () = group.Unix.gr_gid || Array.mem group.Unix.gr_gid gids
  with Not_found -> false

let rw_identity_args identity =
  [
    Printf.sprintf "--translate-uid=squash-guest:0:%d:65536" identity.uid;
    Printf.sprintf "--translate-uid=squash-host:%d:0:1" identity.uid;
    Printf.sprintf "--translate-gid=squash-guest:0:%d:65536" identity.gid;
    Printf.sprintf "--translate-gid=squash-host:%d:0:1" identity.gid;
  ]

let run_root_service ~action ~uid ~state_base ~name ~share ~virtiofsd =
  if Unix.geteuid () <> 0 then failwith "root helper was not run as root";
  let identity = identity_of_uid uid in
  let name = Util.name_slug name in
  validate_user_state ~require_shares:(action = "start") ~uid ~state_base ~name;
  let unit = service_name ~uid ~state_base ~name share ^ ".service" in
  let socket = socket_path ~state_base ~name share in
  let shared_dir = share_path ~state_base ~name share in
  let systemctl = systemctl_command () in
  match action with
  | "start" ->
      if unit_is_active unit then (
        if not (socket_accepts_connection socket) then
          failwith
            (Printf.sprintf "%s is active but its socket is not connectable"
               unit))
      else (
        if unit_has_process unit then stop_system_unit systemctl unit;
        ignore
          (Util.run_foreground systemctl [ "--system"; "reset-failed"; unit ]);
        let executable = trusted_executable virtiofsd in
        remove_root_socket socket;
        let args =
          [
            "--system";
            "--unit";
            unit;
            "--collect";
            "--quiet";
            "--property=User=root";
            "--property=LimitNOFILE=1000000:1000000";
            "--property=CapabilityBoundingSet=CAP_CHOWN CAP_DAC_OVERRIDE \
             CAP_DAC_READ_SEARCH CAP_FOWNER CAP_FSETID CAP_SETGID CAP_SETUID \
             CAP_SETPCAP CAP_SYS_ADMIN CAP_MKNOD CAP_SETFCAP";
            "--property=AmbientCapabilities=CAP_DAC_READ_SEARCH CAP_SETPCAP \
             CAP_SYS_ADMIN";
            "--property=NoNewPrivileges=no";
            executable;
            "--socket-path=" ^ socket;
            "--shared-dir=" ^ shared_dir;
            "--tag=shares-" ^ share_name share;
            "--socket-group=" ^ socket_group_arg ();
            "--sandbox=namespace";
            "--inode-file-handles=prefer";
            "--xattr";
          ]
          @ match share with Ro -> [] | Rw -> rw_identity_args identity
        in
        let code = Util.run_foreground (systemd_command ()) args in
        if code <> 0 then
          failwith (Printf.sprintf "systemd-run failed (%d)" code))
  | "stop" ->
      if unit_is_active unit || unit_has_process unit then
        stop_system_unit systemctl unit;
      remove_root_socket socket
  | _ -> failwith "invalid root-helper action"

let share_of_string = function
  | "ro" -> Ro
  | "rw" -> Rw
  | _ -> failwith "share must be ro or rw"

let root_helper args =
  let uid = effective_user_id () in
  match args with
  | [ action; name; share; state_base; virtiofsd ] ->
      run_root_service ~action ~uid ~state_base ~name
        ~share:(share_of_string share) ~virtiofsd
  | action :: name :: state_base :: virtiofsd :: shares
    when action = "start-all" || action = "stop-all" ->
      if shares = [] then failwith "at least one share is required";
      let action = if action = "start-all" then "start" else "stop" in
      List.iter
        (fun share ->
          run_root_service ~action ~uid ~state_base ~name
            ~share:(share_of_string share) ~virtiofsd)
        shares
  | _ ->
      failwith
        "invalid helper arguments (expected ACTION NAME STATE_BASE VIRTIOFSD \
         SHARE...)"

let invoke_root_helper ~action ~name ~shares ~state_base ~virtiofsd =
  if action = "start-all" && not (user_belongs_to_socket_group ()) then
    failwith
      "your account must be a member of the 'users' group for root-managed \
       VirtioFS sockets";
  let pkexec = pkexec_path () in
  let executable =
    Option.value
      (Sys.getenv_opt "ASH_INTERNAL_EXECUTABLE")
      ~default:
        (if Filename.is_relative Sys.executable_name then
           Option.value
             (Util.find_in_path Sys.executable_name)
             ~default:(Util.absolute_path Sys.executable_name)
         else Sys.executable_name)
  in
  if not (Sys.file_exists executable) then
    failwith "cannot determine the absolute path to the ash executable";
  let args =
    [
      executable;
      "_virtiofsd_root";
      action;
      Util.name_slug name;
      Unix.realpath state_base;
      virtiofsd;
    ]
    @ List.map share_name shares
  in
  let code = Util.run_foreground pkexec args in
  if code <> 0 then failwith (Printf.sprintf "pkexec helper failed (%d)" code)

let start_all ~name ~state_base ~virtiofsd shares =
  invoke_root_helper ~action:"start-all" ~name ~shares ~state_base ~virtiofsd

let start ~name ~state_base ~virtiofsd share =
  start_all ~name ~state_base ~virtiofsd [ share ]

let service_or_socket_exists ~name ~state_base share =
  let state_base = Unix.realpath state_base in
  let uid = Unix.getuid () in
  let unit = service_name ~uid ~state_base ~name share ^ ".service" in
  let active =
    match Util.find_in_path "systemctl" with
    | None -> false
    | Some systemctl ->
        Util.run_foreground systemctl
          [ "--system"; "is-active"; "--quiet"; unit ]
        = 0
  in
  let socket = socket_path ~state_base ~name share in
  let stale_socket = socket_owned_by_root socket in
  active || stale_socket || pid_file_owned_by_root socket

let stop_all ~name ~state_base ~virtiofsd shares =
  if
    List.exists
      (fun share -> service_or_socket_exists ~name ~state_base share)
      shares
  then invoke_root_helper ~action:"stop-all" ~name ~shares ~state_base ~virtiofsd

let stop ~name ~state_base ~virtiofsd share =
  stop_all ~name ~state_base ~virtiofsd [ share ]
