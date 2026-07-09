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
      Printf.eprintf "ash: could not find executable %S\n" candidate;
      Option.iter (Printf.eprintf "\nHint: %s\n") hint;
      exit 127

let find_virtie explicit_path =
  find_exe ~hint:"install virtie into PATH, set ASH_VIRTIE, or pass --virtie PATH." ~env:"ASH_VIRTIE" explicit_path "virtie"

let find_virtiofsd () =
  find_exe ~hint:"install virtiofsd into PATH so virtie can start virtiofs mounts." None "virtiofsd"

let find_ssh explicit_path =
  find_exe ~hint:"pass a valid --ssh PATH." explicit_path "ssh"

let find_systemd_ssh_proxy explicit_path =
  find_exe ~hint:"pass a valid --systemd-ssh-proxy PATH." explicit_path "systemd-ssh-proxy"

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
    int_of_float (Float.of_string (String.trim number) *. Float.of_int multiplier)

let timestamp () =
  let tm = Unix.localtime (Unix.time ()) in
  Printf.sprintf "%04d%02d%02d%02d%02d%02d" (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday tm.tm_hour tm.tm_min tm.tm_sec

let default_name () =
  let cwd = Sys.getcwd () in
  let base = Filename.basename cwd in
  Util.name_slug (base ^ "-" ^ timestamp ())

let state_dir name =
  let base =
    match Sys.getenv_opt "XDG_STATE_HOME" with
    | Some path when path <> "" -> path
    | _ -> Filename.concat (Util.home_dir ()) ".local/state"
  in
  Filename.concat (Filename.concat base "ash") (Util.name_slug name)

let manifest_path ~name = Filename.concat (state_dir name) "virtie.toml"

let string_array xs = Otoml.array (List.map Otoml.string xs)

let virtiofs_section ~socket ~bin =
  Otoml.table
    [
      ("socket", Otoml.string socket);
      ("bin", Otoml.string bin);
      ("args", string_array [ "--socket-path={{.Socket}}"; "--shared-dir={{.MountSource}}"; "--tag={{.MountTag}}" ]);
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
  let fields = match target with None -> fields | Some target -> ("target", Otoml.string target) :: fields in
  Otoml.table (List.rev fields)

let image_mount ~source =
  Otoml.table
    [
      ("type", Otoml.string "image");
      ("source", Otoml.string source);
      ("read_only", Otoml.boolean false);
      ("image", Otoml.table [ ("size", Otoml.integer 16384); ("fs", Otoml.string "ext4"); ("create", Otoml.boolean true); ("label", Otoml.string "persist") ]);
    ]

let profile_mount ~bin (mount : Agent_box.mount) =
  virtiofs_mount ~target:mount.target ~tag:mount.tag ~source:mount.source ~read_only:mount.read_only ~socket:(mount.tag ^ ".sock") ~bin ()

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
  let fields = if file.write_back then fields @ [ ("write_back", Otoml.boolean true) ] else fields in
  Otoml.table fields

let render_resolved_manifest inputs =
  let config = inputs.config in
  let profiles =
    match inputs.profiles with
    | [] -> [ Agent_box.default_profile config ]
    | profiles -> profiles
  in
  let state_dir = state_dir inputs.name in
  let memory = Agent_box.qemu_memory config |> Option.map parse_memory_mib |> Option.value ~default:4096 in
  let vcpu = Agent_box.qemu_cpus config |> Option.value ~default:2 in
  let user = Option.value inputs.user ~default:(Agent_box.ssh_user config) in
  let target = inputs.target in
  let boot = inputs.boot in
  let resources = Agent_box.resources_for_profiles ~guest_user:user config profiles in
  let ssh = inputs.ssh in
  let systemd_ssh_proxy = inputs.systemd_ssh_proxy in
  let ssh_exec =
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
  let mounts =
    [
      virtiofs_mount ~target:workspace_guest_dir ~tag:"workspace" ~source:workspace_host_dir ~read_only:false ~socket:"workspace.sock" ~bin:inputs.virtiofsd ();
      virtiofs_mount ~tag:"ro-store" ~source:"/nix/store" ~read_only:true ~socket:"ro-store.sock" ~bin:inputs.virtiofsd ();
      image_mount ~source:(Filename.concat state_dir "persist.img");
    ]
    @ (if inputs.mount_cwd then [ virtiofs_mount ~tag:"workspace_cwd" ~source:"." ~read_only:false ~socket:"workspace-cwd.sock" ~bin:inputs.virtiofsd () ] else [])
    @ List.map (profile_mount ~bin:inputs.virtiofsd) resources.mounts
  in
  let write_files = List.map (write_file_section user) resources.write_files in
  let document =
    Otoml.table
      [
        ("host_name", Otoml.string target.host_name);
        ("working_dir", Otoml.string ".");
        ("state_dir", Otoml.string state_dir);
        ("machine", Otoml.table [ ("memory", Otoml.integer memory); ("vcpu", Otoml.integer vcpu); ("kvm", Otoml.boolean true) ]);
        ( "kernel",
          Otoml.table
            ([
               ("path", Otoml.string boot.kernel);
               ("initrd_path", Otoml.string boot.initrd);
               ("serial", Otoml.string (if inputs.print_serial then "print" else "off"));
             ]
            @ if boot.kernel_params = [] then [] else [ ("params", string_array boot.kernel_params) ]) );
        ("ssh", Otoml.table [ ("user", Otoml.string user); ("exec", string_array ssh_exec); ("ready_socket", Otoml.string "ready.sock"); ("autoprovision", Otoml.boolean true) ]);
        ("workspace", Otoml.table [ ("guest_dir", Otoml.string workspace_guest_dir); ("host_dir", Otoml.string workspace_host_dir); ("mount_cwd", Otoml.boolean inputs.mount_cwd) ]);
        ("mounts", Otoml.TomlTableArray mounts);
      ]
  in
  let document = if write_files = [] then document else Otoml.update document [ "write_files" ] (Some (Otoml.TomlTableArray write_files)) in
  let header =
    Printf.sprintf "# Generated by ash\n# flake = %s\n# host = %s\n# name = %s\n# profiles = %s\n"
      (Nix.flake_ref inputs.flake) target.host_name inputs.name (String.concat "," profiles)
  in
  (profiles, header ^ Otoml.Printer.to_string document)

let render_manifest inputs =
  let config = Agent_box.load inputs.config_path in
  let target = Nix.resolve_target ~flake:inputs.flake in
  let user = Option.value inputs.user ~default:(Agent_box.ssh_user config) in
  Nix.validate_user ~target ~user;
  let boot = Nix.resolve_boot ~target in
  let ssh = Option.value inputs.ssh ~default:boot.ssh in
  let systemd_ssh_proxy = Option.value inputs.systemd_ssh_proxy ~default:boot.systemd_ssh_proxy in
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
    }

let spawn ?virtie ?name ?user ?ssh ?systemd_ssh_proxy ~config_path ~flake ~profiles ~print_serial ~mount_cwd ~verbose () =
  let virtie = find_virtie virtie in
  let ssh = Option.map (fun path -> find_ssh (Some path)) ssh in
  let systemd_ssh_proxy = Option.map (fun path -> find_systemd_ssh_proxy (Some path)) systemd_ssh_proxy in
  let virtiofsd = find_virtiofsd () in
  let name = Option.value name ~default:(default_name ()) in
  Log.debug "using VM name: %s" name;
  let _, manifest = render_manifest { config_path; flake; name; profiles; user; print_serial; mount_cwd; ssh; systemd_ssh_proxy; virtiofsd } in
  let path = manifest_path ~name in
  Log.debug "generated virtie manifest path: %s" path;
  Util.write_file path manifest;
  Log.debug "wrote virtie manifest (%d bytes)" (String.length manifest);
  let verbose_args = List.map (fun _ -> "-v") verbose in
  Util.exec virtie ([ "--manifest"; path ] @ verbose_args @ [ "launch"; "--ssh" ])
