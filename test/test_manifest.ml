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

let find_strings doc path =
  match Otoml.find_opt doc (Otoml.get_array Otoml.get_string) path with
  | Some value -> value
  | None -> fail ("missing string array: " ^ String.concat "." path)

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

let assert_int label expected actual =
  if expected <> actual then
    fail (Printf.sprintf "%s: expected %d, got %d" label expected actual)

let assert_string_prefix label prefix value =
  if not (String.starts_with ~prefix value) then
    fail (Printf.sprintf "%s: expected %S to start with %S" label value prefix)

let assert_string_contains label value needle =
  let value_len = String.length value in
  let needle_len = String.length needle in
  let rec loop i =
    if i + needle_len > value_len then false
    else if String.sub value i needle_len = needle then true
    else loop (i + 1)
  in
  if not (loop 0) then
    fail (Printf.sprintf "%s: expected %S to contain %S" label value needle)

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
    ?ro_store_socket ?(kitty = false) ~config ~flake ~name () =
  Virtle.render_resolved_manifest
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
      ro_store_socket;
      ssh = test_boot.ssh;
      systemd_ssh_proxy = test_boot.systemd_ssh_proxy;
      kitty;
      virtiofsd = "/bin/virtiofsd";
      virtle = "/bin/virtle";
    }

let test_agent_box_to_virtle_manifest () =
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
  let wrapper = Filename.concat state "ash/unit-test/ssh-with-profile-mounts" in
  assert_equal "profile mount ssh wrapper" wrapper
    (List.hd (find_strings doc [ "ssh"; "exec" ]));
  let kitty_wrapper =
    Filename.concat state "ash/unit-test/ssh-with-profile-mounts-kitty"
  in
  if
    Otoml.find_opt doc
      (Otoml.get_array Otoml.get_string)
      [ "ssh"; "kitty_exec" ]
    <> None
  then fail "virtle manifest should not include unknown ssh.kitty_exec key";
  if not (Sys.file_exists wrapper) then
    fail "profile mount ssh wrapper should exist";
  if not (Sys.file_exists kitty_wrapper) then
    fail "kitty ssh wrapper should exist";
  let wrapper_content =
    In_channel.with_open_text wrapper In_channel.input_all
  in
  assert_string_contains "wrapper guest-exec" wrapper_content "rpc guest-exec";
  assert_string_contains "wrapper handles successful mount" wrapper_content
    "*'\"exitCode\":0'*)";
  assert_string_contains "wrapper handles already mounted" wrapper_content
    "*'\"exitCode\":42'*) ;;";
  assert_string_contains "wrapper execs ssh" wrapper_content
    "-o IdentitiesOnly=yes \"$@\"";
  let kitty_wrapper_content =
    In_channel.with_open_text kitty_wrapper In_channel.input_all
  in
  assert_string_contains "kitty wrapper execs kitten ssh" kitty_wrapper_content
    "exec 'kitten' 'ssh'";
  let mounts = table_array doc "mounts" in
  let workspace = find_table_by_string mounts "tag" "workspace" in
  assert_equal "workspace source"
    (Filename.concat state "ash/unit-test/workspace")
    (string_field workspace "source");
  assert_equal "workspace target" "/home/agent/workspace"
    (string_field workspace "target");
  let hotmounts = find_table_by_string mounts "tag" "hotmounts" in
  assert_equal "hotmounts source"
    (Filename.concat state "ash/unit-test/hotmounts")
    (string_field hotmounts "source");
  assert_bool "hotmounts read_only" false (bool_field hotmounts "read_only");
  let ro_store = find_table_by_string mounts "tag" "ro-store" in
  assert_equal "ro-store source" "/nix/store" (string_field ro_store "source");
  assert_bool "ro-store read_only" true (bool_field ro_store "read_only");
  let cwd = find_table_by_string mounts "tag" "workspace_cwd" in
  assert_equal "cwd source" "." (string_field cwd "source");
  let cargo = find_table_by_string mounts "target" "/home/agent/.cargo" in
  assert_equal "cargo source"
    (Filename.concat home ".cargo")
    (string_field cargo "source");
  assert_string_prefix "cargo tag" "cargo-" (string_field cargo "tag");
  if String.length (string_field cargo "tag") > 36 then
    fail "cargo tag should fit virtiofs tag length limit";
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
  let hotmounts = find_table_by_string mounts "tag" "hotmounts" in
  assert_equal "hotmounts source"
    (Filename.concat state "ash/default-profile/hotmounts")
    (string_field hotmounts "source");
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
  let wrapper = Filename.concat state "ash/ro-file/ssh-with-profile-mounts" in
  assert_equal "workspace mount ssh wrapper" wrapper
    (List.hd (find_strings doc [ "ssh"; "exec" ]));
  if not (Sys.file_exists wrapper) then
    fail "workspace mount ssh wrapper should exist";
  let write_files = table_array doc "write_files" in
  let gitconfig =
    find_table_by_string write_files "guest_path" "/home/agent/.gitconfig"
  in
  assert_equal "gitconfig source"
    (Filename.concat home ".gitconfig")
    (string_field gitconfig "source");
  if List.mem_assoc "write_back" gitconfig then
    fail "read-only file should not set write_back"

let test_ro_store_socket_override () =
  let root = temp_dir "ash-test" in
  let home = Filename.concat root "home" in
  let state = Filename.concat root "state" in
  Unix.putenv "HOME" home;
  Unix.putenv "XDG_STATE_HOME" state;
  Util.ensure_dir home;
  let config_path = Filename.concat root "agent-box.toml" in
  write_file config_path
    {|default_profile = "base"

[runtime.qemu]
ssh_user = "agent"

[profiles.base]
|};
  let config = Agent_box.load config_path in
  let _, manifest =
    render ~config ~flake:"../my-nix#agent" ~name:"ro-store-socket"
      ~ro_store_socket:"/run/ro-store.sock" ()
  in
  if not (String.contains manifest '/') then
    fail "manifest should contain paths";
  assert_string_contains "ro-store socket override" manifest
    "socket = \"/run/ro-store.sock\""

let test_qga_params_use_valid_json () =
  let action =
    Qga.shell_action ~name:"test-qga"
      ~args:[ "arg with spaces"; "quote \" newline\n tab\t" ]
      {sh|printf '%s\n' "$1"|sh}
  in
  match Yojson.Safe.from_string (Qga.params action) with
  | `Assoc fields ->
      assert_equal "qga path" "/run/current-system/sw/bin/sh"
        (match List.assoc_opt "path" fields with
        | Some (`String value) -> value
        | _ -> fail "qga path missing");
      let args =
        match List.assoc_opt "args" fields with
        | Some (`List args) ->
            List.map
              (function
                | `String value -> value | _ -> fail "non-string qga arg")
              args
        | _ -> fail "qga args missing"
      in
      assert_equal "qga action name" "test-qga" (List.nth args 2);
      assert_equal "qga escaped arg" "quote \" newline\n tab\t"
        (List.nth args 4);
      assert_bool "qga captureOutput" true
        (match List.assoc_opt "captureOutput" fields with
        | Some (`Bool value) -> value
        | _ -> false)
  | _ -> fail "qga params should be a JSON object"

let test_qga_int_field_finds_nested_values () =
  let text = {|{"return":{"exitCode":42,"nested":{"cid":7}}}|} in
  assert_int "qga exitCode" 42
    (Option.value (Qga.int_field ~field:"exitCode" text) ~default:(-1));
  assert_int "qga nested cid" 7
    (Option.value (Qga.int_field ~field:"cid" text) ~default:(-1))

let test_qga_output_data_decodes_base64 () =
  let text = {|{"result":{"outData":"MiA2Cg=="}}|} in
  assert_equal "qga decoded output" "2 6\n"
    (Option.value (Qga.output_data text) ~default:"")

let test_qga_ssh_stats_action () =
  let script = List.nth Qga.ssh_stats_action.args 1 in
  assert_string_contains "ssh stats vsock" script "ss --vsock";
  assert_string_contains "ssh stats port" script "/:22$/";
  assert_string_contains "ssh stats ptys" script "^pts\\//";
  match Virtle.parse_ssh_stats "2 6\n" with
  | Some (connections, ptys) ->
      assert_int "ssh connections" 2 connections;
      assert_int "ssh ptys" 6 ptys
  | None -> fail "ssh stats output should parse"

let test_active_ssh_warning () =
  let warning = Virtle.active_ssh_warning ~name:"work" (Some (2, 6)) in
  assert_string_contains "stop ssh count"
    (Option.value warning ~default:"")
    "2 active SSH connection(s)";
  assert_string_contains "stop pty count"
    (Option.value warning ~default:"")
    "6 active PTY(s)";
  assert_bool "no warning without connections" true
    (Virtle.active_ssh_warning ~name:"work" (Some (0, 0)) = None);
  assert_bool "yes confirms stop" true (Virtle.affirmative_response "yes");
  assert_bool "uppercase y confirms stop" true (Virtle.affirmative_response "Y");
  assert_bool "empty response cancels stop" true
    (not (Virtle.affirmative_response ""));
  assert_bool "no cancels stop" true (not (Virtle.affirmative_response "no"))

let test_qga_unmount_removes_empty_mountpoint () =
  let action = Qga.unmount_action ~name:"test-unmount" ~guest_path:"/tmp/mnt" in
  let script = List.nth action.args 1 in
  assert_string_contains "unmount rmdir" script
    "rmdir \"$target\" 2>/dev/null || true"

let test_qga_mountpoint_inherits_parent_owner () =
  let action =
    Qga.hotmount_action ~name:"test-hotmount" ~read_only:false
      ~hotmounts_guest_dir:"/run/ash/hotmounts" ~source_name:"source"
      ~guest_path:"/home/agent/project"
  in
  let script = List.nth action.args 1 in
  assert_string_contains "mountpoint helper" script "install_mountpoint()";
  assert_string_contains "mountpoint parent stat" script
    "stat -c %u \"$parent\"";
  assert_string_contains "mountpoint owner install" script
    "install -d -o \"$owner\" -g \"$group\" \"$path\"";
  assert_string_contains "target uses helper" script
    "install_mountpoint \"$target\""

let test_virtiofs_cache_options () =
  let mutable_mount =
    Virtle.virtiofs_mount ~cache:"never" ~tag:"mutable" ~source:"/tmp/source"
      ~read_only:false ~socket:"mutable.sock" ~bin:"/bin/virtiofsd" ()
  in
  let default_mount =
    Virtle.virtiofs_mount ~tag:"immutable" ~source:"/nix/store" ~read_only:true
      ~socket:"immutable.sock" ~bin:"/bin/virtiofsd" ()
  in
  let args mount =
    match
      Otoml.find_opt mount
        (Otoml.get_array Otoml.get_string)
        [ "virtiofs"; "args" ]
    with
    | Some args -> args
    | None -> fail "virtiofs mount is missing daemon arguments"
  in
  assert_bool "mutable mount disables cache" true
    (List.mem "--cache=never" (args mutable_mount));
  assert_bool "immutable mount keeps default cache" false
    (List.exists (String.starts_with ~prefix:"--cache=") (args default_mount))

let test_inspect_infers_fixed_mount_targets () =
  let fields tag =
    [ ("type", Otoml.TomlString "virtiofs"); ("tag", Otoml.TomlString tag) ]
  in
  assert_bool "hotmount target" true
    (Virtle.configured_mount_target (fields "hotmounts")
    = Some "/run/ash/hotmounts");
  assert_bool "ro-store target" true
    (Virtle.configured_mount_target (fields "ro-store") = Some "/nix/store");
  assert_bool "workspace cwd target" true
    (Virtle.configured_mount_target (fields "workspace_cwd") = Some "/mnt/cwd")

let test_bindfs_disables_kernel_metadata_caches () =
  let expected = "attr_timeout=0,entry_timeout=0,negative_timeout=0" in
  let rw_args = Virtle.bindfs_args_for_mode Virtle.Read_write in
  let ro_args = Virtle.bindfs_args_for_mode Virtle.Read_only in
  assert_bool "bindfs rw has cache timeouts" true (List.mem expected rw_args);
  assert_bool "bindfs ro has cache timeouts" true (List.mem expected ro_args);
  assert_bool "bindfs ro stays read-only" true (List.mem "-r" ro_args)

let test_hotmount_host_path_normalization_cases () =
  let root = temp_dir "ash-test-hotmount-normalized" in
  let a = Filename.concat root "a" in
  let b = Filename.concat a "b" in
  let c = Filename.concat b "c" in
  let d = Filename.concat a "d" in
  let hidden = Filename.concat a ".hidden" in
  let dots_name = Filename.concat a "..literal" in
  let spaces = Filename.concat a "space directory" in
  let unicode = Filename.concat a "café" in
  List.iter mkdir_p [ c; d; hidden; dots_name; spaces; unicode ];
  let cases =
    [
      ("unchanged absolute path", d, d);
      ("trailing dot", d ^ "/.", d);
      ("trailing slash", d ^ "/", d);
      ("repeated separators", a ^ "//b///c", c);
      ("single parent", b ^ "/../d", d);
      ("multiple parents", c ^ "/../../d", d);
      ("embedded current directory", a ^ "/./b/./c", c);
      ("hidden directory", hidden, hidden);
      ("dot-prefixed directory name", dots_name, dots_name);
      ("spaces in component", spaces ^ "/.", spaces);
      ("unicode component", unicode ^ "/.", unicode);
      ("root", "/", "/");
      ("parents above root", "/../../", "/");
    ]
  in
  List.iter
    (fun (label, input, expected) ->
      assert_equal label expected (Virtle.normalize_hotmount_host_dir input))
    cases;
  let cwd = Sys.getcwd () in
  Fun.protect
    ~finally:(fun () -> Unix.chdir cwd)
    (fun () ->
      Unix.chdir root;
      assert_equal "relative path becomes absolute" d
        (Virtle.normalize_hotmount_host_dir "a/b/../d/."));
  let normalized_one = Virtle.normalize_hotmount_host_dir d in
  let normalized_two = Virtle.normalize_hotmount_host_dir (b ^ "/../d") in
  assert_equal "equivalent paths produce the same hotmount slug"
    (Virtle.hotmount_slug ~host_dir:normalized_one ~guest_path:"/mnt/project")
    (Virtle.hotmount_slug ~host_dir:normalized_two ~guest_path:"/mnt/project")

let test_hotmount_host_home_expansion_cases () =
  let root = temp_dir "ash-test-hotmount-home" in
  let home = Filename.concat root "home" in
  let project = Filename.concat home "project" in
  let sibling = Filename.concat home "sibling" in
  List.iter mkdir_p [ project; sibling ];
  let previous_home = Util.home_dir () in
  Fun.protect
    ~finally:(fun () -> Unix.putenv "HOME" previous_home)
    (fun () ->
      Unix.putenv "HOME" home;
      assert_equal "bare home expansion" home
        (Virtle.resolve_hotmount_host_path "~");
      assert_equal "home child expansion" project
        (Virtle.resolve_hotmount_host_path "~/project");
      assert_equal "home expansion before normalization" sibling
        (Virtle.resolve_hotmount_host_path "~/project/../sibling/.");
      assert_equal "absolute path bypasses home expansion" project
        (Virtle.resolve_hotmount_host_path project);
      assert_equal "named user syntax remains literal" "~someone/project"
        (Util.expand_home "~someone/project");
      assert_equal "embedded tilde remains literal" "prefix/~/project"
        (Util.expand_home "prefix/~/project"))

let test_hotmount_host_path_symlink_cases () =
  let root = temp_dir "ash-test-hotmount-symlink" in
  let other = Filename.concat root "other" in
  let target = Filename.concat other "target" in
  let child = Filename.concat target "child" in
  let sibling = Filename.concat other "sibling" in
  let link = Filename.concat root "link" in
  let link_chain = Filename.concat root "link-chain" in
  let relative_link = Filename.concat root "relative-link" in
  mkdir_p child;
  mkdir_p sibling;
  Unix.symlink target link;
  Unix.symlink link link_chain;
  Unix.symlink "other/target" relative_link;
  let cases =
    [
      ("symlink spelling", link, link);
      ("dot after symlink", link ^ "/.", link);
      ("child below symlink", link ^ "/child", link ^ "/child");
      ("normal child parent below symlink", link ^ "/child/..", link);
      ("parent crossing symlink", link ^ "/../sibling", link ^ "/../sibling");
      ("multiple parents reaching symlink", link ^ "/child/../..", link ^ "/..");
      ("symlink chain spelling", link_chain, link_chain);
      ("relative symlink spelling", relative_link, relative_link);
      ( "parent crossing relative symlink",
        relative_link ^ "/../sibling",
        relative_link ^ "/../sibling" );
      ( "parent crossing symlink chain",
        link_chain ^ "/../sibling",
        link_chain ^ "/../sibling" );
    ]
  in
  List.iter
    (fun (label, input, expected) ->
      assert_equal label expected (Virtle.normalize_hotmount_host_dir input))
    cases;
  assert_bool "normalization does not use realpath" true
    (Virtle.normalize_hotmount_host_dir link <> Unix.realpath link)

let test_hotmount_default_guest_path_matches_host_path () =
  assert_equal "default guest path" "/host/project"
    (Virtle.resolve_hotmount_guest_path ~user:"agent" ~host_dir:"/host/project"
       None)

let test_hotmount_tilde_guest_path_uses_guest_home () =
  assert_equal "tilde guest path" "/home/agent/project"
    (Virtle.resolve_hotmount_guest_path ~user:"agent" ~host_dir:"/host/project"
       (Some "~/project"));
  assert_equal "root tilde guest path" "/root/project"
    (Virtle.resolve_hotmount_guest_path ~user:"root" ~host_dir:"/host/project"
       (Some "~/project"))

let test_hotmount_metadata_roundtrip () =
  let root = temp_dir "ash-test-hotmount-metadata" in
  let host_dir = Filename.concat root "host" in
  let guest_path = "/home/agent/project" in
  let source_name = Virtle.hotmount_slug ~host_dir ~guest_path in
  let path = Filename.concat root (source_name ^ ".meta") in
  let metadata : Virtle.hotmount_metadata =
    { guest_path; host_dir; mode = Virtle.Read_only; source_name; path }
  in
  Virtle.write_hotmount_metadata_record metadata;
  match Virtle.read_hotmount_metadata path with
  | Error err -> fail ("failed to read metadata: " ^ err)
  | Ok restored ->
      assert_equal "metadata guest path" guest_path restored.guest_path;
      assert_equal "metadata host dir" host_dir restored.host_dir;
      assert_equal "metadata source name" source_name restored.source_name;
      assert_bool "metadata read-only mode" true
        (restored.mode = Virtle.Read_only)

let test_read_hotmounts_reports_valid_and_invalid_records () =
  let root = temp_dir "ash-test-read-hotmounts" in
  Unix.putenv "XDG_STATE_HOME" root;
  let name = "inventory" in
  let host_dir = Filename.concat root "host" in
  let guest_path = "/home/agent/project" in
  let source_name = Virtle.hotmount_slug ~host_dir ~guest_path in
  let metadata =
    Virtle.hotmount_metadata ~name ~source_name ~host_dir ~guest_path
      ~mode:Virtle.Read_write
  in
  Virtle.write_hotmount_metadata_record metadata;
  let invalid_path =
    Filename.concat (Virtle.hotmount_metadata_dir ~name) "broken.meta"
  in
  write_file invalid_path "broken\n";
  let state = Virtle.read_hotmounts ~name in
  assert_int "valid hotmount count" 1 (List.length state.mounts);
  assert_int "invalid hotmount count" 1 (List.length state.invalid);
  assert_equal "inventory guest path" guest_path
    (List.hd state.mounts).guest_path;
  assert_equal "invalid metadata path" invalid_path
    (fst (List.hd state.invalid))

let test_inspect_includes_config_and_hotmounts () =
  let root = temp_dir "ash-test-inspect" in
  Unix.putenv "XDG_STATE_HOME" root;
  let name = "inspect-vm" in
  let state_dir = Virtle.state_dir name in
  let host_dir = Filename.concat root "project" in
  mkdir_p state_dir;
  mkdir_p host_dir;
  write_file
    (Virtle.manifest_path ~name)
    {|memory = 2048

[[mounts]]
tag = "workspace"
type = "virtiofs"
source = "/tmp/workspace"
read_only = false
|};
  let agent_box_path = Filename.concat root "agent-box.toml" in
  write_file agent_box_path
    {|default_profile = "rust"

[profiles.rust]
[profiles.go]
|};
  write_file
    (Virtle.ash_config_path ~name)
    (Printf.sprintf
       {|[spawn]
config_path = %S
flake = "github:example/vms#agent"
profiles = ["rust", "go"]
|}
       agent_box_path);
  let guest_path = "/home/agent/project" in
  let source_name = Virtle.hotmount_slug ~host_dir ~guest_path in
  Virtle.write_hotmount_metadata_record
    (Virtle.hotmount_metadata ~name ~source_name ~host_dir ~guest_path
       ~mode:Virtle.Read_write);
  let json = Virtle.inspect_vm_json ~name in
  let open Yojson.Safe.Util in
  assert_equal "inspect name" name (json |> member "name" |> to_string);
  assert_equal "inspect status" "stopped" (json |> member "status" |> to_string);
  assert_equal "inspect flake" "github:example/vms#agent"
    (json |> member "ash" |> member "config" |> member "spawn" |> member "flake"
   |> to_string);
  assert_equal "inspect agent-box default profile" "rust"
    (json |> member "agentBox" |> member "config" |> member "default_profile"
   |> to_string);
  assert_int "inspect configured mounts" 1
    (json |> member "virtle" |> member "config" |> member "mounts" |> to_list
   |> List.length);
  assert_int "inspect hotmounts" 1
    (json |> member "hotmounts" |> member "mounts" |> to_list |> List.length);
  assert_equal "inspect hotmount guest path" guest_path
    (json |> member "hotmounts" |> member "mounts" |> index 0
   |> member "guestPath" |> to_string)

let test_atomic_write_replaces_complete_file () =
  let root = temp_dir "ash-test-atomic-write" in
  let path = Filename.concat root "record.meta" in
  Util.atomic_write_file path "old\n";
  Util.atomic_write_file path "new\ncomplete\n";
  assert_equal "atomic file contents" "new\ncomplete\n"
    (In_channel.with_open_text path In_channel.input_all);
  assert_int "atomic temp files" 1 (Array.length (Sys.readdir root))

let test_kitty_selects_kitten_ssh_wrapper () =
  let root = temp_dir "ash-test-kitty" in
  let home = Filename.concat root "home" in
  let state = Filename.concat root "state" in
  mkdir_p home;
  mkdir_p state;
  Unix.putenv "HOME" home;
  Unix.putenv "XDG_STATE_HOME" state;
  let config_path = Filename.concat root "agent-box.toml" in
  write_file config_path {|default_profile = "base"

[profiles.base]
|};
  let config = Agent_box.load config_path in
  let _, manifest =
    render ~config ~flake:"../my-nix#agent" ~name:"kitty" ~kitty:true ()
  in
  let doc = parse_toml manifest in
  let kitty_wrapper =
    Filename.concat state "ash/kitty/ssh-with-profile-mounts-kitty"
  in
  assert_equal "selected kitty wrapper" kitty_wrapper
    (List.hd (find_strings doc [ "ssh"; "exec" ]))

let test_spawn_reuses_saved_flake_when_omitted () =
  let root = temp_dir "ash-test-saved-flake" in
  Unix.putenv "XDG_STATE_HOME" root;
  let name = "existing-vm" in
  let saved_flake = "/tmp/saved-flake#agent" in
  let inputs : Virtle.manifest_inputs =
    {
      config_path = "/tmp/agent-box.toml";
      flake = saved_flake;
      name;
      profiles = [ "base" ];
      user = None;
      print_serial = false;
      mount_cwd = false;
      ro_store_socket = None;
      ssh = None;
      systemd_ssh_proxy = None;
      kitty = false;
      virtiofsd = "/bin/virtiofsd";
      virtle = "/bin/virtle";
    }
  in
  let state_path = Virtle.ash_config_path ~name in
  assert_equal "state filename" "ash-state.toml" (Filename.basename state_path);
  write_file state_path (Virtle.ash_config inputs);
  assert_equal "saved flake" saved_flake (Virtle.resolve_spawn_flake ~name None);
  assert_equal "explicit flake overrides saved" "github:owner/repo#other"
    (Virtle.resolve_spawn_flake ~name (Some "github:owner/repo#other"))

let test_nix_storage_flake_ref_absolutizes_relative_paths () =
  mkdir_p (Filename.concat (Filename.dirname (Sys.getcwd ())) "my-nix");
  mkdir_p (Filename.concat (Sys.getcwd ()) "flake");
  assert_equal "relative flake path"
    (Filename.concat (Filename.dirname (Sys.getcwd ())) "my-nix#agent")
    (Nix.storage_flake_ref "../my-nix#agent");
  assert_equal "path flake path"
    ("path:" ^ Filename.concat (Sys.getcwd ()) "flake#agent")
    (Nix.storage_flake_ref "path:./flake#agent");
  assert_equal "git file flake path"
    ("git+file:" ^ Filename.concat (Sys.getcwd ()) "flake#agent")
    (Nix.storage_flake_ref "git+file:./flake#agent");
  assert_equal "registry flake unchanged" "nixpkgs#agent"
    (Nix.storage_flake_ref "nixpkgs#agent");
  assert_equal "github flake unchanged" "github:owner/repo#agent"
    (Nix.storage_flake_ref "github:owner/repo#agent")

let test_nix_json_string_array_parser () =
  assert_equal "nix json array" "a,b c,d\ne"
    (String.concat "," (Nix.parse_json_string_array {|["a","b c","d\ne"]|}))

let test_state_sizes_ignore_hotmounts () =
  let root = temp_dir "ash-test-size" in
  let hotmounts = Filename.concat root "hotmounts" in
  let workspace = Filename.concat root "workspace" in
  mkdir_p hotmounts;
  mkdir_p workspace;
  write_file (Filename.concat hotmounts "big") (String.make (1024 * 1024) 'x');
  write_file (Filename.concat workspace "small") "x";
  assert_bool "disk usage ignores hotmounts" true
    (Virtle.disk_usage root < 524288L);
  assert_bool "apparent size ignores hotmounts" true
    (Virtle.state_path_size root < 524288L)

let run name test =
  Printf.printf "test %s ... %!" name;
  test ();
  Printf.printf "ok\n%!"

let () =
  run "agent-box profiles render to virtle manifest"
    test_agent_box_to_virtle_manifest;
  run "default profile renders without mount-cwd"
    test_default_profile_without_mount_cwd;
  run "read-only file write does not write back"
    test_readonly_file_write_has_no_write_back;
  run "ro-store socket override" test_ro_store_socket_override;
  run "kitty selects kitten ssh wrapper" test_kitty_selects_kitten_ssh_wrapper;
  run "qga params use valid json" test_qga_params_use_valid_json;
  run "qga int field finds nested values" test_qga_int_field_finds_nested_values;
  run "qga output data decodes base64" test_qga_output_data_decodes_base64;
  run "qga ssh stats action" test_qga_ssh_stats_action;
  run "stop warns about active ssh" test_active_ssh_warning;
  run "qga unmount removes empty mountpoint"
    test_qga_unmount_removes_empty_mountpoint;
  run "qga mountpoint inherits parent owner"
    test_qga_mountpoint_inherits_parent_owner;
  run "virtiofs cache options" test_virtiofs_cache_options;
  run "inspect infers fixed mount targets"
    test_inspect_infers_fixed_mount_targets;
  run "bindfs disables kernel metadata caches"
    test_bindfs_disables_kernel_metadata_caches;
  run "hotmount host path normalization cases"
    test_hotmount_host_path_normalization_cases;
  run "hotmount host home expansion cases"
    test_hotmount_host_home_expansion_cases;
  run "hotmount host path symlink cases" test_hotmount_host_path_symlink_cases;
  run "hotmount default guest path matches host path"
    test_hotmount_default_guest_path_matches_host_path;
  run "hotmount tilde guest path uses guest home"
    test_hotmount_tilde_guest_path_uses_guest_home;
  run "hotmount metadata roundtrip" test_hotmount_metadata_roundtrip;
  run "read hotmounts reports valid and invalid records"
    test_read_hotmounts_reports_valid_and_invalid_records;
  run "inspect includes config and hotmounts"
    test_inspect_includes_config_and_hotmounts;
  run "atomic write replaces complete file"
    test_atomic_write_replaces_complete_file;
  run "spawn reuses saved flake when omitted"
    test_spawn_reuses_saved_flake_when_omitted;
  run "nix storage flake refs absolutize relative paths"
    test_nix_storage_flake_ref_absolutizes_relative_paths;
  run "nix json string array parser" test_nix_json_string_array_parser;
  run "state sizes ignore hotmounts" test_state_sizes_ignore_hotmounts
