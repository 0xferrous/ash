open Ash_lib

let fail msg = failwith msg

let temp_dir prefix =
  let path = Filename.temp_file prefix "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  path

let write_file path content =
  Util.ensure_dir (Filename.dirname path);
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out oc)
    (fun () -> output_string oc content)

let mkdir_p = Util.ensure_dir

let parse_toml text =
  match Otoml.Parser.from_string_result text with
  | Ok doc -> doc
  | Error err -> fail ("generated manifest is invalid TOML: " ^ err)

let find_string doc path =
  match Otoml.find_opt doc Otoml.get_string path with
  | Some value -> value
  | None -> fail ("missing string: " ^ String.concat "." path)

let find_int doc path =
  match Otoml.find_opt doc Otoml.get_integer path with
  | Some value -> value
  | None -> fail ("missing int: " ^ String.concat "." path)

let find_bool doc path =
  match Otoml.find_opt doc Otoml.get_boolean path with
  | Some value -> value
  | None -> fail ("missing bool: " ^ String.concat "." path)

let table_field table key =
  match List.assoc_opt key table with
  | Some value -> value
  | None -> fail ("missing field: " ^ key)

let string_field table key =
  match table_field table key with
  | Otoml.TomlString value -> value
  | _ -> fail ("field is not string: " ^ key)

let bool_field table key =
  match table_field table key with
  | Otoml.TomlBoolean value -> value
  | _ -> fail ("field is not bool: " ^ key)

let table_array doc key =
  match Otoml.find_opt doc Otoml.get_value [ key ] with
  | Some (Otoml.TomlTableArray values) ->
      List.map
        (function
          | Otoml.TomlTable table -> table
          | _ -> fail (key ^ " contains a non-table entry"))
        values
  | Some _ -> fail (key ^ " is not a table array")
  | None -> []

let find_table_by_string tables key value =
  match
    List.find_opt
      (fun table -> List.assoc_opt key table = Some (Otoml.TomlString value))
      tables
  with
  | Some table -> table
  | None -> fail ("missing table with " ^ key ^ " = " ^ value)

let assert_equal label expected actual =
  if expected <> actual then
    fail (Printf.sprintf "%s: expected %S, got %S" label expected actual)

let assert_bool label expected actual =
  if expected <> actual then
    fail (Printf.sprintf "%s: expected %b, got %b" label expected actual)

let test_boot : Nix.boot =
  {
    kernel = "/nix/store/kernel/bzImage";
    initrd = "/nix/store/initrd/initrd";
    kernel_params = [ "init=/nix/store/system/init"; "root=fstab" ];
    ssh = "/nix/store/openssh/bin/ssh";
    systemd_ssh_proxy = "/nix/store/systemd/lib/systemd/systemd-ssh-proxy";
  }

let test_target : Nix.target =
  { attr = "../my-nix#nixosConfigurations.agent"; host_name = "agent" }

let render ?(profiles = []) ?user ?(print_serial = false) ?(mount_cwd = false)
    ~config ~flake ~name () =
  Virtie.render_resolved_manifest
    {
      config;
      flake;
      target = test_target;
      boot = test_boot;
      name;
      profiles;
      user;
      print_serial;
      mount_cwd;
      ssh = test_boot.ssh;
      systemd_ssh_proxy = test_boot.systemd_ssh_proxy;
      virtiofsd = "/bin/virtiofsd";
    }

let test_agent_box_to_virtie_manifest () =
  let root = temp_dir "ash-test" in
  let home = Filename.concat root "home" in
  let state = Filename.concat root "state" in
  let abs_cache = Filename.concat root "abs-cache" in
  mkdir_p home;
  mkdir_p state;
  mkdir_p abs_cache;
  mkdir_p (Filename.concat home ".cargo");
  mkdir_p (Filename.concat home "dev/ro-project");
  write_file
    (Filename.concat home ".config/nix/nix.conf")
    "experimental-features = nix-command flakes\n";
  Unix.putenv "HOME" home;
  Unix.putenv "XDG_STATE_HOME" state;
  let config_path = Filename.concat root "agent-box.toml" in
  write_file config_path
    (Printf.sprintf
       {|default_profile = "base"

[runtime.qemu]
memory = "8G"
cpus = 4
ssh_user = "agent"

[profiles.base.mounts.ro]
home_relative = ["dev/ro-project"]

[profiles.rust]
extends = ["base"]

[profiles.rust.mounts.rw]
home_relative = [".cargo", ".config/nix/nix.conf"]
absolute = ["%s"]
|}
       abs_cache);
  let config = Agent_box.load config_path in
  let _, manifest =
    render ~config ~flake:"../my-nix#agent" ~name:"unit-test"
      ~profiles:[ "rust" ] ~print_serial:true ~mount_cwd:true ()
  in
  let doc = parse_toml manifest in
  assert_equal "host_name" "agent" (find_string doc [ "host_name" ]);
  assert_equal "state_dir"
    (Filename.concat state "ash/unit-test")
    (find_string doc [ "state_dir" ]);
  if find_int doc [ "machine"; "memory" ] <> 8192 then
    fail "memory should be 8192";
  if find_int doc [ "machine"; "vcpu" ] <> 4 then fail "vcpu should be 4";
  assert_equal "kernel serial" "print" (find_string doc [ "kernel"; "serial" ]);
  assert_bool "workspace mount_cwd" true
    (find_bool doc [ "workspace"; "mount_cwd" ]);
  assert_equal "workspace guest_dir" "/home/agent/workspace"
    (find_string doc [ "workspace"; "guest_dir" ]);
  let mounts = table_array doc "mounts" in
  let workspace = find_table_by_string mounts "tag" "workspace" in
  assert_equal "workspace source"
    (Filename.concat state "ash/unit-test/workspace")
    (string_field workspace "source");
  assert_equal "workspace target" "/home/agent/workspace"
    (string_field workspace "target");
  let ro_store = find_table_by_string mounts "tag" "ro-store" in
  assert_equal "ro-store source" "/nix/store" (string_field ro_store "source");
  assert_bool "ro-store read_only" true (bool_field ro_store "read_only");
  let cwd = find_table_by_string mounts "tag" "workspace_cwd" in
  assert_equal "cwd source" "." (string_field cwd "source");
  let cargo = find_table_by_string mounts "target" "/home/agent/.cargo" in
  assert_equal "cargo source"
    (Filename.concat home ".cargo")
    (string_field cargo "source");
  assert_bool "cargo read_only" false (bool_field cargo "read_only");
  let ro_project =
    find_table_by_string mounts "target" "/home/agent/dev/ro-project"
  in
  assert_equal "ro project source"
    (Filename.concat home "dev/ro-project")
    (string_field ro_project "source");
  assert_bool "ro project read_only" true (bool_field ro_project "read_only");
  let abs = find_table_by_string mounts "target" abs_cache in
  assert_equal "abs source" abs_cache (string_field abs "source");
  let write_files = table_array doc "write_files" in
  let nix_conf =
    find_table_by_string write_files "guest_path"
      "/home/agent/.config/nix/nix.conf"
  in
  assert_equal "write file source"
    (Filename.concat home ".config/nix/nix.conf")
    (string_field nix_conf "source");
  assert_bool "write file write_back" true (bool_field nix_conf "write_back");
  assert_equal "write file chown" "agent:users" (string_field nix_conf "chown")

let test_default_profile_without_mount_cwd () =
  let root = temp_dir "ash-test-default" in
  let home = Filename.concat root "home" in
  let state = Filename.concat root "state" in
  mkdir_p home;
  mkdir_p state;
  mkdir_p (Filename.concat home ".cache/example");
  Unix.putenv "HOME" home;
  Unix.putenv "XDG_STATE_HOME" state;
  let config_path = Filename.concat root "agent-box.toml" in
  write_file config_path
    {|default_profile = "base"

[runtime.qemu]
ssh_user = "dev"

[profiles.base.mounts.rw]
home_relative = [".cache/example"]
|};
  let config = Agent_box.load config_path in
  let profiles, manifest =
    render ~config ~flake:"../my-nix#agent" ~name:"default-profile" ()
  in
  assert_equal "selected default profile" "base" (String.concat "," profiles);
  let doc = parse_toml manifest in
  assert_equal "ssh user" "dev" (find_string doc [ "ssh"; "user" ]);
  assert_equal "workspace guest dir" "/home/dev/workspace"
    (find_string doc [ "workspace"; "guest_dir" ]);
  assert_bool "mount_cwd default" false
    (find_bool doc [ "workspace"; "mount_cwd" ]);
  let mounts = table_array doc "mounts" in
  if
    List.exists
      (fun table ->
        List.assoc_opt "tag" table = Some (Otoml.TomlString "workspace_cwd"))
      mounts
  then fail "workspace_cwd should not be emitted by default";
  let cache = find_table_by_string mounts "target" "/home/dev/.cache/example" in
  assert_equal "cache source"
    (Filename.concat home ".cache/example")
    (string_field cache "source");
  if table_array doc "write_files" <> [] then
    fail "write_files should be absent"

let test_readonly_file_write_has_no_write_back () =
  let root = temp_dir "ash-test-ro-file" in
  let home = Filename.concat root "home" in
  let state = Filename.concat root "state" in
  mkdir_p home;
  mkdir_p state;
  write_file (Filename.concat home ".gitconfig") "[user]\n  name = Test\n";
  Unix.putenv "HOME" home;
  Unix.putenv "XDG_STATE_HOME" state;
  let config_path = Filename.concat root "agent-box.toml" in
  write_file config_path
    {|default_profile = "base"

[profiles.base.mounts.ro]
home_relative = [".gitconfig"]
|};
  let config = Agent_box.load config_path in
  let _, manifest =
    render ~config ~flake:"../my-nix#agent" ~name:"ro-file" ()
  in
  let doc = parse_toml manifest in
  let write_files = table_array doc "write_files" in
  let gitconfig =
    find_table_by_string write_files "guest_path" "/home/agent/.gitconfig"
  in
  assert_equal "gitconfig source"
    (Filename.concat home ".gitconfig")
    (string_field gitconfig "source");
  if List.mem_assoc "write_back" gitconfig then
    fail "read-only file should not set write_back"

let run name test =
  Printf.printf "test %s ... %!" name;
  test ();
  Printf.printf "ok\n%!"

let () =
  run "agent-box profiles render to virtie manifest"
    test_agent_box_to_virtie_manifest;
  run "default profile renders without mount-cwd"
    test_default_profile_without_mount_cwd;
  run "read-only file write does not write back"
    test_readonly_file_write_has_no_write_back
