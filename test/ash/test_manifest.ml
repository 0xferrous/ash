open Ash

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

let strings_field table key =
  match table_field table key with
  | Otoml.TomlArray values ->
      List.map
        (function
          | Otoml.TomlString value -> value
          | _ -> fail ("field contains a non-string: " ^ key))
        values
  | _ -> fail ("field is not a string array: " ^ key)

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
    toplevel = "/nix/store/system";
    registration = "/nix/store/closure-info/registration";
    nix = "/nix/store/nix/bin/nix";
    nix_store = "/nix/store/nix/bin/nix-store";
    ssh = "/nix/store/openssh/bin/ssh";
    systemd_ssh_proxy = "/nix/store/systemd/lib/systemd/systemd-ssh-proxy";
  }

let test_target : Nix.target =
  { attr = "../my-nix#nixosConfigurations.agent"; host_name = "agent" }

let render ?(spaces = []) ?user ?(kernel_serial = Virtle.Off)
    ?(mount_cwd = false) ?nix_store_strategy ?nix_store_image_size_mib
    ?ro_store_socket ?(kitty = false) ?waypipe
    ?(config_path = "/tmp/config.toml") ~config ~flake ~name () =
  let nix_store_strategy =
    Option.value nix_store_strategy
      ~default:(Ash_config.global_nix_store_strategy config)
  in
  let nix_store_image_size_mib =
    Option.value nix_store_image_size_mib
      ~default:(Ash_config.global_nix_store_image_size config)
  in
  Virtle.render_resolved_manifest
    {
      config;
      config_path;
      flake;
      target = test_target;
      boot = test_boot;
      name;
      spaces;
      user;
      kernel_serial;
      mount_cwd;
      nix_store_strategy;
      nix_store_image_size_mib;
      ro_store_socket;
      ssh = test_boot.ssh;
      systemd_ssh_proxy = test_boot.systemd_ssh_proxy;
      portal_host = Some "/bin/agent-portal-host";
      portal_dbus_proxy = Some "/bin/ash-dbus-proxy";
      kitty;
      waypipe;
      virtiofsd = "/bin/virtiofsd";
      virtle = "/bin/virtle";
    }

let test_spaces_to_virtle_manifest () =
  let root = temp_dir "ash-test-spaces" in
  let home = Filename.concat root "home" in
  let state = Filename.concat root "state" in
  let absolute = Filename.concat root "absolute" in
  mkdir_p home;
  mkdir_p state;
  mkdir_p absolute;
  mkdir_p (Filename.concat home "dev/fr/ash");
  mkdir_p (Filename.concat home "dev/read-only");
  Unix.putenv "HOME" home;
  Unix.putenv "XDG_STATE_HOME" state;
  let config_path = Filename.concat root "config.toml" in
  write_file config_path
    (Printf.sprintf
       {|[spaces.ash]
rw_mounts = ["~/dev/fr/ash", "~/dev/fr/ash:/home/agent/workspace/ash", %S]
ro_mounts = ["~/dev/read-only:~/src/read-only"]
|}
       absolute);
  let config = Ash_config.load config_path in
  let spaces, manifest =
    render ~config ~flake:"../my-nix#agent" ~name:"unit-test" ~spaces:[ "ash" ]
      ~kernel_serial:Virtle.Console ~mount_cwd:true ()
  in
  assert_equal "selected spaces" "ash" (String.concat "," spaces);
  let doc = parse_toml manifest in
  assert_equal "host_name" "agent" (find_string doc [ "host_name" ]);
  assert_equal "virtle state directory"
    (Filename.concat state "ash/unit-test/virtle_state")
    (find_string doc [ "state_dir" ]);
  assert_int "default memory" 4096 (find_int doc [ "machine"; "memory" ]);
  assert_int "default vcpu"
    (int_of_string (Util.command_output "nproc"))
    (find_int doc [ "machine"; "vcpu" ]);
  assert_equal "default networks disabled" ""
    (String.concat "," (find_strings doc [ "networks" ]));
  let qemu_exec = find_strings doc [ "qemu"; "exec" ] in
  assert_equal "QEMU architecture template" "qemu-system-{{.HostArch}}"
    (List.hd qemu_exec);
  assert_string_contains "Ash bridge backend" (List.nth qemu_exec 2)
    "bridge,id=ashnet0,br=ash0";
  assert_string_contains "QEMU bridge helper" (List.nth qemu_exec 2)
    "helper=/run/wrappers/bin/qemu-bridge-helper";
  assert_string_contains "stable VM MAC" (List.nth qemu_exec 4)
    ("mac=" ^ Virtle.network_mac "unit-test");
  assert_equal "kernel serial" "console"
    (find_string doc [ "kernel"; "serial" ]);
  assert_equal "Ash kernel parameters"
    (String.concat ","
       [
         "init=/nix/store/system/init";
         "root=fstab";
         "ash.nix-store=shared";
         "ash.mdns-host=unit-test";
         "ash.mdns-mac=" ^ Virtle.network_mac "unit-test";
       ])
    (String.concat "," (find_strings doc [ "kernel"; "params" ]));
  assert_equal "workspace guest_dir" "/home/agent/workspace"
    (find_string doc [ "workspace"; "guest_dir" ]);
  let wrapper = Filename.concat state "ash/unit-test/ssh-with-space-mounts" in
  assert_equal "space mount ssh wrapper" wrapper
    (List.hd (find_strings doc [ "ssh"; "exec" ]));
  if not (Sys.file_exists wrapper) then fail "space mount wrapper should exist";
  let wrapper_content =
    In_channel.with_open_text wrapper In_channel.input_all
  in
  assert_string_contains "SSH wrapper loads Nix registration" wrapper_content
    "nix-store --load-db";
  assert_string_contains "SSH wrapper uses registration path" wrapper_content
    test_boot.registration;
  let mounts = table_array doc "mounts" in
  let same_path =
    find_table_by_string mounts "target" "/home/agent/dev/fr/ash"
  in
  assert_equal "implicit guest target source"
    (Filename.concat home "dev/fr/ash")
    (string_field same_path "source");
  assert_bool "implicit mount writable" false (bool_field same_path "read_only");
  let workspace_path =
    find_table_by_string mounts "target" "/home/agent/workspace/ash"
  in
  assert_equal "explicit guest target source"
    (Filename.concat home "dev/fr/ash")
    (string_field workspace_path "source");
  let read_only =
    find_table_by_string mounts "target" "/home/agent/src/read-only"
  in
  assert_equal "read-only source"
    (Filename.concat home "dev/read-only")
    (string_field read_only "source");
  assert_bool "read-only mount" true (bool_field read_only "read_only");
  let absolute_mount = find_table_by_string mounts "target" absolute in
  assert_equal "absolute source" absolute (string_field absolute_mount "source")

let test_global_memory_config () =
  let root = temp_dir "ash-test-global-memory" in
  let home = Filename.concat root "home" in
  let state = Filename.concat root "state" in
  mkdir_p home;
  mkdir_p state;
  Unix.putenv "HOME" home;
  Unix.putenv "XDG_STATE_HOME" state;
  let config = parse_toml {|[global]
memory = 8192
|} in
  let _, manifest =
    render ~config ~flake:"../my-nix#agent" ~name:"custom-memory" ()
  in
  let doc = parse_toml manifest in
  assert_int "configured memory" 8192 (find_int doc [ "machine"; "memory" ])

let test_global_network_config () =
  let root = temp_dir "ash-test-global-network" in
  let home = Filename.concat root "home" in
  let state = Filename.concat root "state" in
  mkdir_p home;
  mkdir_p state;
  Unix.putenv "HOME" home;
  Unix.putenv "XDG_STATE_HOME" state;
  let config =
    parse_toml
      {|[global]
network_bridge = "vmbridge0"
qemu_bridge_helper = "/custom/qemu-bridge-helper"
|}
  in
  let _, manifest =
    render ~config ~flake:"../my-nix#agent" ~name:"custom-network" ()
  in
  let doc = parse_toml manifest in
  let qemu_exec = find_strings doc [ "qemu"; "exec" ] in
  assert_string_contains "configured bridge" (List.nth qemu_exec 2)
    "br=vmbridge0";
  assert_string_contains "configured bridge helper" (List.nth qemu_exec 2)
    "helper=/custom/qemu-bridge-helper"

let test_no_spaces_selected_by_default () =
  let root = temp_dir "ash-test-no-spaces" in
  let home = Filename.concat root "home" in
  let state = Filename.concat root "state" in
  mkdir_p home;
  mkdir_p state;
  Unix.putenv "HOME" home;
  Unix.putenv "XDG_STATE_HOME" state;
  let config_path = Filename.concat root "missing-config.toml" in
  let config = Ash_config.load_for_spaces config_path [] in
  let spaces, manifest =
    render ~config ~flake:"../my-nix#agent" ~name:"no-spaces" ()
  in
  assert_equal "no selected spaces" "" (String.concat "," spaces);
  let doc = parse_toml manifest in
  let mounts = table_array doc "mounts" in
  assert_int "fixed mount count without spaces" 6 (List.length mounts);
  let shares_ro = find_table_by_string mounts "tag" "shares-ro" in
  assert_equal "shares ro source"
    (Filename.concat state "ash/no-spaces/shares/ro")
    (string_field shares_ro "source");
  assert_bool "shares ro mount read-only" true
    (bool_field shares_ro "read_only");
  let shares_rw = find_table_by_string mounts "tag" "shares-rw" in
  assert_equal "shares rw source"
    (Filename.concat state "ash/no-spaces/shares/rw")
    (string_field shares_rw "source");
  assert_bool "shares rw mount writable" false
    (bool_field shares_rw "read_only");
  assert_bool "shares rw configures uid ownership" true
    (Virtle.contains_substring manifest "--uid-map="
    || Virtle.contains_substring manifest "--translate-uid=");
  assert_bool "shares rw configures gid ownership" true
    (Virtle.contains_substring manifest "--gid-map="
    || Virtle.contains_substring manifest "--translate-gid=");
  assert_string_contains "ro store preserves host ownership" manifest
    "--sandbox=none";
  let guest_store_upper =
    Filename.concat state "ash/no-spaces/shares/rw/guest-store-upper"
  in
  if not (Sys.file_exists guest_store_upper) then
    fail "guest store upper dir should exist";
  assert_int "guest store upper mode" 0o1777
    ((Unix.stat guest_store_upper).st_perm land 0o7777);
  if
    not
      (Sys.file_exists
         (Filename.concat state "ash/no-spaces/shares/rw/guest-store-work"))
  then fail "guest store work dir should exist";
  assert_equal "default ssh user" "agent" (find_string doc [ "ssh"; "user" ])

let test_image_backed_nix_store_manifest () =
  let root = temp_dir "ash-test-image-store" in
  let home = Filename.concat root "home" in
  let state = Filename.concat root "state" in
  mkdir_p home;
  mkdir_p state;
  Unix.putenv "HOME" home;
  Unix.putenv "XDG_STATE_HOME" state;
  let config =
    parse_toml
      {|[global.nix_store]
strategy = "shared"
image_size_mib = 12288
|}
  in
  let _, manifest =
    render ~config ~flake:"../my-nix#agent" ~name:"image-store"
      ~nix_store_strategy:Ash_config.Image ~nix_store_image_size_mib:24576 ()
  in
  let doc = parse_toml manifest in
  let mounts = table_array doc "mounts" in
  assert_equal "image store kernel parameters"
    (String.concat ","
       [
         "init=/nix/store/system/init";
         "root=fstab";
         "ash.nix-store=image";
         "ash.mdns-host=image-store";
         "ash.mdns-mac=" ^ Virtle.network_mac "image-store";
       ])
    (String.concat "," (find_strings doc [ "kernel"; "params" ]));
  assert_int "fixed mount count with image store" 4 (List.length mounts);
  assert_bool "image store omits ro-store" false
    (List.exists
       (fun table ->
         List.assoc_opt "tag" table = Some (Otoml.TomlString "ro-store"))
       mounts);
  assert_bool "image store omits shares" false
    (List.exists
       (fun table ->
         match List.assoc_opt "tag" table with
         | Some (Otoml.TomlString ("shares-ro" | "shares-rw")) -> true
         | _ -> false)
       mounts);
  let store =
    List.find
      (fun table ->
        match List.assoc_opt "image" table with
        | Some (Otoml.TomlTable image | Otoml.TomlInlineTable image) ->
            List.assoc_opt "label" image = Some (Otoml.TomlString "nix-store")
        | _ -> false)
      mounts
  in
  assert_equal "image store source"
    (Filename.concat state "ash/image-store/nix-store.img")
    (string_field store "source");
  (match table_field store "image" with
  | Otoml.TomlTable image | Otoml.TomlInlineTable image ->
      assert_int "image store size" 24576
        (match table_field image "size" with
        | Otoml.TomlInteger size -> size
        | _ -> fail "image size is not an integer")
  | _ -> fail "image store configuration is not a table");
  assert_bool "image store target" true
    (Virtle.configured_mount_target store = Some "/nix");
  assert_bool "image store does not prepare host shares" false
    (Sys.file_exists (Filename.concat state "ash/image-store/shares"));
  let wrapper =
    In_channel.with_open_text
      (Filename.concat state "ash/image-store/ssh-with-space-mounts")
      In_channel.input_all
  in
  assert_bool "image store imports registration" true
    (Virtle.contains_substring wrapper "ash-load-nix-registration");
  let _, shared_manifest =
    render ~config ~flake:"../my-nix#agent" ~name:"shared-store" ()
  in
  let shared_mounts = table_array (parse_toml shared_manifest) "mounts" in
  assert_bool "other VM inherits global shared strategy" true
    (List.exists
       (fun table ->
         List.assoc_opt "tag" table = Some (Otoml.TomlString "ro-store"))
       shared_mounts)

let assert_mount_parse_ok label ~host_home ~guest_user ~read_only spec
    expected_source expected_target =
  match
    Ash_config.parse_mount_spec ~host_home ~guest_user ~space:"test" ~read_only
      spec
  with
  | Error message -> fail (label ^ ": unexpected parse error: " ^ message)
  | Ok (mount : Ash_config.mount) ->
      assert_equal (label ^ " source") expected_source mount.source;
      assert_equal (label ^ " target") expected_target mount.target;
      assert_bool (label ^ " read_only") read_only mount.read_only

let assert_mount_parse_error label ~host_home ~guest_user spec =
  match
    Ash_config.parse_mount_spec ~host_home ~guest_user ~space:"test"
      ~read_only:false spec
  with
  | Ok _ -> fail (label ^ ": expected parse error")
  | Error _ -> ()

let test_xdg_config_path () =
  let old_home = Sys.getenv_opt "HOME" in
  let old_xdg = Sys.getenv_opt "XDG_CONFIG_HOME" in
  let old_name = Sys.getenv_opt "ASH_NAME" in
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "HOME" (Option.value old_home ~default:"");
      Unix.putenv "XDG_CONFIG_HOME" (Option.value old_xdg ~default:"");
      Unix.putenv "ASH_NAME" (Option.value old_name ~default:""))
    (fun () ->
      Unix.putenv "HOME" "/home/tester";
      Unix.putenv "ASH_NAME" "";
      Unix.putenv "XDG_CONFIG_HOME" "/tmp/test-config";
      assert_equal "XDG config path" "/tmp/test-config/ash/config.toml"
        (Util.default_ash_config_path ());
      Unix.putenv "ASH_NAME" "nash";
      assert_equal "named XDG config path" "/tmp/test-config/nash/config.toml"
        (Util.default_ash_config_path ());
      Unix.putenv "XDG_CONFIG_HOME" "";
      assert_equal "named fallback config path"
        "/home/tester/.config/nash/config.toml"
        (Util.default_ash_config_path ()))

let test_xdg_cache_home () =
  let old_home = Sys.getenv_opt "HOME" in
  let old_xdg = Sys.getenv_opt "XDG_CACHE_HOME" in
  let old_name = Sys.getenv_opt "ASH_NAME" in
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "HOME" (Option.value old_home ~default:"");
      Unix.putenv "XDG_CACHE_HOME" (Option.value old_xdg ~default:"");
      Unix.putenv "ASH_NAME" (Option.value old_name ~default:""))
    (fun () ->
      Unix.putenv "HOME" "/home/tester";
      Unix.putenv "ASH_NAME" "";
      Unix.putenv "XDG_CACHE_HOME" "/tmp/test-cache";
      assert_equal "XDG image cache path" "/tmp/test-cache/ash/nix-store-images"
        (Virtle.nix_store_image_cache_dir ());
      Unix.putenv "ASH_NAME" "nash";
      assert_equal "named XDG image cache path"
        "/tmp/test-cache/nash/nix-store-images"
        (Virtle.nix_store_image_cache_dir ());
      Unix.putenv "XDG_CACHE_HOME" "";
      assert_equal "named fallback image cache path"
        "/home/tester/.cache/nash/nix-store-images"
        (Virtle.nix_store_image_cache_dir ()))

let test_cached_images_for_removal () =
  assert_equal "cached image sort fields" "modified,size"
    (Virtle.cache_rm_sorts |> Array.to_list
    |> List.map (fun (sort : Virtle.rm_target Tui.sort) -> sort.name)
    |> String.concat ",");
  let root = temp_dir "ash-test-cached-images" in
  let old_cache = Sys.getenv_opt "XDG_CACHE_HOME" in
  let old_state = Sys.getenv_opt "XDG_STATE_HOME" in
  let old_name = Sys.getenv_opt "ASH_NAME" in
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "XDG_CACHE_HOME" (Option.value old_cache ~default:"");
      Unix.putenv "XDG_STATE_HOME" (Option.value old_state ~default:"");
      Unix.putenv "ASH_NAME" (Option.value old_name ~default:"");
      Util.remove_tree ~force:true root)
    (fun () ->
      Unix.putenv "XDG_CACHE_HOME" root;
      Unix.putenv "XDG_STATE_HOME" root;
      Unix.putenv "ASH_NAME" "test-ash";
      let cache = Virtle.nix_store_image_cache_dir () in
      mkdir_p cache;
      let first_key =
        Nix.image_store_cache_key ~toplevel:"/nix/store/first-system"
          ~registration:"/nix/store/registration"
      in
      let first = Filename.concat cache (first_key ^ ".img") in
      let second =
        Filename.concat cache "22222222222222222222222222222222.img"
      in
      write_file first "first image";
      write_file (first ^ ".toplevel")
        "4\n/nix/store/first-system\n128\n/nix/store/registration\n";
      write_file second "second image";
      write_file (second ^ ".toplevel") "invalid marker\n";
      Unix.utimes first 100. 100.;
      Unix.utimes second 200. 200.;
      let vm_dir = Filename.concat (Virtle.state_base_dir ()) "vm-one" in
      mkdir_p vm_dir;
      write_file (Filename.concat vm_dir "virtle.toml") "";
      write_file
        (Filename.concat vm_dir "nix-store.img.toplevel")
        "4\n/nix/store/first-system\n256\n/nix/store/registration\n";
      write_file (Filename.concat cache "ignored.txt") "not an image";
      match Virtle.list_cached_images () with
      | [ second_info; first_info ] ->
          assert_equal "cached images sorted newest first"
            (String.concat ","
               [ "22222222222222222222222222222222"; first_key ])
            (String.concat "," [ second_info.cache_key; first_info.cache_key ]);
          assert_equal "first cached image toplevel" "/nix/store/first-system"
            (Option.value first_info.toplevel ~default:"");
          assert_bool "invalid cached image marker" true
            (Option.is_none second_info.toplevel);
          assert_equal "matching VM cache references" "vm-one"
            (String.concat "," first_info.references);
          assert_int "invalid cache has no VM references" 0
            (List.length second_info.references);
          assert_string_contains "cache list header reference column"
            Virtle.cached_image_list_header "REFS";
          let cache_row = Virtle.cached_image_list_item first_info in
          assert_string_contains "cache list row key" cache_row first_key;
          assert_string_contains "cache list row closure" cache_row
            "first-system";
          assert_string_contains "cache list row path" cache_row first;
          assert_string_contains "cached image removal item modification time"
            (Virtle.rm_item_label (Virtle.Cached_image first_info))
            (Virtle.format_time first_info.modified);
          assert_equal "cached image selected-size summary"
            (Virtle.human_size
               (Int64.add first_info.disk_bytes second_info.disk_bytes))
            (Virtle.rm_selection_summary
               [ Virtle.Cached_image first_info; Cached_image second_info ]);
          Virtle.remove_cached_image first_info;
          assert_bool "cached image removed" false (Sys.file_exists first);
          assert_bool "cached image marker removed" false
            (Sys.file_exists (first ^ ".toplevel"));
          assert_bool "other cached image retained" true
            (Sys.file_exists second)
      | images ->
          fail
            (Printf.sprintf "expected two cached images, got %d"
               (List.length images)))

let test_xdg_state_path () =
  let old_home = Sys.getenv_opt "HOME" in
  let old_xdg = Sys.getenv_opt "XDG_STATE_HOME" in
  let old_name = Sys.getenv_opt "ASH_NAME" in
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "HOME" (Option.value old_home ~default:"");
      Unix.putenv "XDG_STATE_HOME" (Option.value old_xdg ~default:"");
      Unix.putenv "ASH_NAME" (Option.value old_name ~default:""))
    (fun () ->
      Unix.putenv "HOME" "/home/tester";
      Unix.putenv "ASH_NAME" "";
      Unix.putenv "XDG_STATE_HOME" "/tmp/test-state";
      assert_equal "XDG state path" "/tmp/test-state/ash"
        (Virtle.state_base_dir ());
      Unix.putenv "ASH_NAME" "nash";
      assert_equal "named XDG state path" "/tmp/test-state/nash"
        (Virtle.state_base_dir ());
      Unix.putenv "XDG_STATE_HOME" "";
      assert_equal "named fallback state path" "/home/tester/.local/state/nash"
        (Virtle.state_base_dir ()))

let test_space_mount_spec_parsing () =
  let host_home = "/home/host" in
  assert_mount_parse_ok "tilde implicit target" ~host_home ~guest_user:"agent"
    ~read_only:false "~/dev/fr/ash" "/home/host/dev/fr/ash"
    "/home/agent/dev/fr/ash";
  assert_mount_parse_ok "tilde explicit tilde target" ~host_home
    ~guest_user:"agent" ~read_only:true "~/dev/fr/ash:~/workspace/ash"
    "/home/host/dev/fr/ash" "/home/agent/workspace/ash";
  assert_mount_parse_ok "tilde explicit absolute target" ~host_home
    ~guest_user:"agent" ~read_only:false
    "~/dev/fr/ash:/home/agent/workspace/ash" "/home/host/dev/fr/ash"
    "/home/agent/workspace/ash";
  assert_mount_parse_ok "absolute implicit target" ~host_home
    ~guest_user:"agent" ~read_only:true "/srv/source" "/srv/source"
    "/srv/source";
  assert_mount_parse_ok "absolute explicit tilde target" ~host_home
    ~guest_user:"dev" ~read_only:false "/srv/source:~/src" "/srv/source"
    "/home/dev/src";
  assert_mount_parse_ok "root guest home" ~host_home ~guest_user:"root"
    ~read_only:false "~/source:~/target" "/home/host/source" "/root/target";
  assert_mount_parse_ok "home roots" ~host_home ~guest_user:"agent"
    ~read_only:false "~:~" "/home/host" "/home/agent";
  assert_mount_parse_error "relative host" ~host_home ~guest_user:"agent"
    "relative/path";
  assert_mount_parse_error "relative guest" ~host_home ~guest_user:"agent"
    "/host/path:relative/path";
  assert_mount_parse_error "empty host" ~host_home ~guest_user:"agent"
    ":/guest/path";
  assert_mount_parse_error "empty guest" ~host_home ~guest_user:"agent"
    "/host/path:"

let expect_space_resolution label config spaces expected =
  match Ash_config.resolve_spaces config spaces with
  | Ok actual ->
      assert_equal label (String.concat "," expected) (String.concat "," actual)
  | Error message -> fail (label ^ ": unexpected error: " ^ message)

let expect_space_resolution_error label config spaces expected =
  match Ash_config.resolve_spaces config spaces with
  | Ok actual ->
      fail
        (Printf.sprintf "%s: expected error, resolved %S" label
           (String.concat "," actual))
  | Error message -> assert_string_contains label message expected

let test_space_extension_graph_traversal () =
  let config =
    parse_toml
      {|[spaces.base]
[spaces.left]
extends = ["base"]
[spaces.right]
extends = ["base"]
[spaces.app]
extends = ["left", "right"]
[spaces.extra]
extends = ["right"]
|}
  in
  expect_space_resolution "diamond traversal" config [ "app" ]
    [ "base"; "left"; "right"; "app" ];
  expect_space_resolution "multiple roots are stable and unique" config
    [ "app"; "extra"; "base" ]
    [ "base"; "left"; "right"; "app"; "extra" ];
  expect_space_resolution_error "unknown extension" config [ "missing" ]
    "space not found in config: missing";
  let unknown_parent = parse_toml {|[spaces.child]
extends = ["missing"]
|} in
  expect_space_resolution_error "unknown parent" unknown_parent [ "child" ]
    "space not found in config: missing";
  let cyclic =
    parse_toml
      {|[spaces.a]
extends = ["b"]
[spaces.b]
extends = ["c"]
[spaces.c]
extends = ["a"]
|}
  in
  expect_space_resolution_error "extension cycle" cyclic [ "a" ]
    "a -> b -> c -> a"

let test_space_extension_evaluation () =
  let root = temp_dir "ash-test-space-extension" in
  let home = Filename.concat root "home" in
  mkdir_p home;
  List.iter
    (fun name -> mkdir_p (Filename.concat home name))
    [ "base"; "left"; "right"; "app" ];
  Unix.putenv "HOME" home;
  let config =
    parse_toml
      {|[spaces.base]
rw_mounts = ["~/base:/mnt/base"]
[spaces.left]
extends = ["base"]
rw_mounts = ["~/left:/mnt/left"]
[spaces.right]
extends = ["base"]
ro_mounts = ["~/right:/mnt/right"]
[spaces.app]
extends = ["left", "right"]
rw_mounts = ["~/app:/mnt/app"]
|}
  in
  let resources =
    Ash_config.resources_for_spaces ~guest_user:"agent" config [ "app" ]
  in
  let mounts : Ash_config.mount list = resources.mounts in
  assert_equal "extended mount evaluation order"
    "/mnt/base,/mnt/left,/mnt/right,/mnt/app"
    (mounts
    |> List.map (fun (mount : Ash_config.mount) -> mount.target)
    |> String.concat ",");
  assert_int "diamond base evaluated once" 4 (List.length mounts);
  let right =
    List.find
      (fun (mount : Ash_config.mount) -> mount.target = "/mnt/right")
      mounts
  in
  assert_bool "inherited read-only mode" true right.read_only

let test_space_mount_deduplication_after_parsing () =
  let root = temp_dir "ash-test-space-dedup" in
  let home = Filename.concat root "home" in
  let shared = Filename.concat home "shared" in
  mkdir_p shared;
  Unix.putenv "HOME" home;
  let config =
    parse_toml
      (Printf.sprintf
         {|[spaces.base]
rw_mounts = ["~/shared:/mnt/shared"]
[spaces.left]
extends = ["base"]
rw_mounts = [%S]
[spaces.right]
extends = ["base"]
rw_mounts = ["~/shared:/mnt/shared", "~/shared:/mnt/other"]
[spaces.app]
extends = ["left", "right"]
rw_mounts = [%S]
|}
         (shared ^ ":/mnt/shared") (shared ^ ":/mnt/shared"))
  in
  let resources =
    Ash_config.resources_for_spaces ~guest_user:"agent" config [ "app" ]
  in
  let mounts : Ash_config.mount list = resources.mounts in
  assert_int "equivalent parsed mounts deduplicate" 2 (List.length mounts);
  assert_equal "deduplicated mount order" "/mnt/shared,/mnt/other"
    (mounts
    |> List.map (fun (mount : Ash_config.mount) -> mount.target)
    |> String.concat ",");
  let shared_mount = List.hd mounts in
  assert_equal "deduplication keeps first defining space tag"
    (Ash_config.path_tag "base" shared "/mnt/shared")
    shared_mount.tag

let test_space_files_render_to_write_files () =
  let root = temp_dir "ash-test-space-files" in
  let home = Filename.concat root "home" in
  let dotfile = Filename.concat home ".toolrc" in
  let script = Filename.concat home "tool" in
  let system_file = Filename.concat root "system.conf" in
  mkdir_p home;
  write_file dotfile "setting = true\n";
  write_file script "#!/bin/sh\necho tool\n";
  write_file system_file "system setting\n";
  Unix.chmod script 0o750;
  Unix.chmod system_file 0o640;
  Unix.putenv "HOME" home;
  let config =
    parse_toml
      (Printf.sprintf
         {|[portal]
enabled = true
global = false

[spaces.base]
files = ["~/.toolrc"]

[spaces.app]
extends = ["base"]
files = ["~/.toolrc", "~/tool:~/bin/tool", %S]
|}
         (system_file ^ ":/etc/system.conf"))
  in
  let resources =
    Ash_config.resources_for_spaces ~guest_user:"agent" config [ "app" ]
  in
  assert_int "space files deduplicate through inheritance" 3
    (List.length resources.write_files);
  let _, manifest =
    render ~config ~flake:"../my-nix#agent" ~name:"space-files"
      ~spaces:[ "app" ] ()
  in
  let files = table_array (parse_toml manifest) "write_files" in
  assert_int "configured and Portal write_files are combined" 5
    (List.length files);
  let dotfile = find_table_by_string files "guest_path" "/home/agent/.toolrc" in
  assert_equal "space file contents" "setting = true\n"
    (string_field dotfile "text");
  assert_equal "space file mode" "0644" (string_field dotfile "mode");
  assert_equal "guest-home file owner" "agent:users"
    (string_field dotfile "chown");
  assert_bool "space files overwrite existing guest files" true
    (bool_field dotfile "overwrite");
  let script = find_table_by_string files "guest_path" "/home/agent/bin/tool" in
  assert_equal "executable file mode is preserved" "0750"
    (string_field script "mode");
  let system = find_table_by_string files "guest_path" "/etc/system.conf" in
  assert_equal "absolute guest file mode is preserved" "0640"
    (string_field system "mode");
  assert_bool "absolute guest files retain Virtle's default owner" true
    (List.assoc_opt "chown" system = None)

let test_managed_portal_manifest () =
  let config =
    parse_toml {|[portal]
enabled = true
global = false
vsock_cid = 2
|}
  in
  let _, manifest =
    render ~config ~config_path:"/tmp/ash-portal-config.toml"
      ~flake:"../my-nix#agent" ~name:"managed-portal" ()
  in
  let doc = parse_toml manifest in
  let runs = table_array doc "run" in
  assert_int "managed portal run count" 1 (List.length runs);
  let exec = strings_field (List.hd runs) "exec" in
  assert_equal "managed portal executable" "/bin/agent-portal-host"
    (List.hd exec);
  assert_bool "managed portal config flag" true (List.mem "-c" exec);
  assert_bool "managed portal config argument" true
    (List.mem "/tmp/ash-portal-config.toml" exec);
  assert_bool "managed portal CID port option" true
    (List.mem "--vsock-port-for-cid" exec);
  assert_bool "managed portal CID port template" true (List.mem "{{.CID}}" exec);
  let files = table_array doc "write_files" in
  assert_int "managed portal environment file count" 2 (List.length files);
  let profile = List.hd files in
  assert_equal "managed portal profile path"
    "/etc/profile.d/ash-agent-portal.sh"
    (string_field profile "guest_path");
  let text = string_field profile "text" in
  assert_string_contains "managed portal exports endpoint" text
    "AGENT_PORTAL_VSOCK=managed:2";
  let nushell = List.nth files 1 in
  assert_equal "managed portal Nushell path"
    "/home/agent/.local/share/nushell/vendor/autoload/ash-agent-portal.nu"
    (string_field nushell "guest_path");
  assert_equal "managed portal Nushell owner" "agent:users"
    (string_field nushell "chown");
  assert_string_contains "managed portal sets Nushell endpoint"
    (string_field nushell "text")
    {|$env.AGENT_PORTAL_VSOCK = "managed:2"|}

let test_dbus_notifications_manifest () =
  let config =
    parse_toml
      {|[portal]
enabled = true
global = false
vsock_cid = 2

[portal.dbus]
notifications = true
|}
  in
  let _, manifest =
    render ~config ~flake:"../my-nix#agent" ~name:"dbus-notifications" ()
  in
  let doc = parse_toml manifest in
  let runs = table_array doc "run" in
  assert_int "Portal and D-Bus run count" 2 (List.length runs);
  let dbus_exec = strings_field (List.nth runs 1) "exec" in
  assert_equal "D-Bus bridge executable" "/bin/ash-dbus-proxy"
    (List.hd dbus_exec);
  assert_bool "D-Bus bridge host mode" true (List.mem "host" dbus_exec);
  assert_bool "D-Bus bridge managed port" true (List.mem "--managed" dbus_exec);
  assert_bool "D-Bus bridge expected CID" true (List.mem "{{.CID}}" dbus_exec);
  let profile = table_array doc "write_files" |> List.hd in
  assert_string_contains "guest D-Bus Unix socket address"
    (string_field profile "text")
    "DBUS_SESSION_BUS_ADDRESS=\"unix:path=${XDG_RUNTIME_DIR";
  assert_string_contains "guest D-Bus socket path"
    (string_field profile "text")
    "/ash-dbus-proxy/bus.sock"

let test_global_portal_manifest () =
  let config =
    parse_toml
      {|[portal]
enabled = true
global = true
transport = "vsock"
vsock_cid = 2
vsock_port = 44050
|}
  in
  let _, manifest =
    render ~config ~flake:"../my-nix#agent" ~name:"global-portal" ()
  in
  let doc = parse_toml manifest in
  assert_int "global portal has no managed run" 0
    (List.length (table_array doc "run"));
  let files = table_array doc "write_files" in
  assert_int "global portal environment file count" 2 (List.length files);
  assert_string_contains "global portal endpoint"
    (string_field (List.hd files) "text")
    "AGENT_PORTAL_VSOCK=2:44050";
  assert_string_contains "global portal Nushell endpoint"
    (string_field (List.nth files 1) "text")
    {|$env.AGENT_PORTAL_VSOCK = "2:44050"|}

let test_disabled_portal_manifest () =
  let config = parse_toml "[portal]\nenabled = false\n" in
  let _, manifest =
    render ~config ~flake:"../my-nix#agent" ~name:"disabled-portal" ()
  in
  let doc = parse_toml manifest in
  assert_int "disabled portal run count" 0 (List.length (table_array doc "run"));
  let files = table_array doc "write_files" in
  assert_int "disabled portal cleanup file count" 2 (List.length files);
  assert_string_contains "disabled portal clears stale endpoint"
    (string_field (List.hd files) "text")
    "unset AGENT_PORTAL_VSOCK AGENT_PORTAL_SOCKET";
  assert_string_contains "disabled portal clears stale Nushell endpoint"
    (string_field (List.nth files 1) "text")
    "hide-env --ignore-errors AGENT_PORTAL_VSOCK AGENT_PORTAL_SOCKET"

let test_ro_store_socket_override () =
  let root = temp_dir "ash-test" in
  let home = Filename.concat root "home" in
  let state = Filename.concat root "state" in
  Unix.putenv "HOME" home;
  Unix.putenv "XDG_STATE_HOME" state;
  Util.ensure_dir home;
  let config_path = Filename.concat root "config.toml" in
  write_file config_path "[spaces]\n";
  let config = Ash_config.load config_path in
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
    (Option.value (Qga.output_data text) ~default:"");
  let err_text = {|{"result":{"errData":"ZXJyb3IK"}}|} in
  assert_equal "qga decoded error output" "error\n"
    (Option.value (Qga.error_data err_text) ~default:"");
  assert_equal "qga captured output falls back to stderr" "error\n"
    (Option.value (Qga.captured_output err_text) ~default:"")

let test_qga_load_nix_registration_action () =
  let registration = "/nix/store/closure-info/registration" in
  let action =
    Qga.load_nix_registration_action ~name:"test-registration" ~registration
  in
  let script = List.nth action.args 1 in
  assert_string_contains "registration import" script "nix-store --load-db";
  assert_string_contains "image store kernel parameter check" script
    "ash.nix-store=image";
  assert_string_contains "shared store kernel parameter check" script
    "ash.nix-store=shared";
  assert_string_contains "local overlay marker skips registration" script
    "/etc/ash/local-overlay-store";
  assert_string_contains "local overlay config skips registration" script
    "store*=*local-overlay://*) exit 42";
  assert_string_contains "registration marker" script
    "/run/ash/nix-registration";
  assert_string_contains "legacy registration marker uses parent" script
    {|if [ "$registration_name" = registration ]; then|};
  assert_string_contains "native registration marker uses store basename" script
    {|marker=$marker_dir/$registration_name|};
  assert_string_contains "image store creates Nix database directory" script
    "mkdir -p /nix/var/nix/db";
  assert_string_contains "marker written after import" script
    "nix-store --load-db < \"$registration\"\ntouch \"$marker\"";
  assert_equal "registration argument" registration (List.nth action.args 3)

let test_qga_vm_stats_action () =
  let mac = "02:12:34:56:78:9a" in
  let action = Qga.vm_stats_action ~mac in
  let script = List.nth action.args 1 in
  assert_string_contains "VM stats interface lookup" script
    "/sys/class/net/*/address";
  assert_string_contains "VM stats IPv4 lookup" script "ip -o -4 address show";
  assert_string_contains "VM stats vsock" script "ss --vsock";
  assert_string_contains "VM stats port" script "/:22$/";
  assert_string_contains "VM stats ptys" script "^pts\\//";
  assert_equal "VM stats MAC argument" mac (List.nth action.args 3);
  (match Virtle.parse_vm_stats "192.168.127.101 2 6\n" with
  | Some (Some ip, connections, ptys) ->
      assert_equal "VM IP" "192.168.127.101" ip;
      assert_int "ssh connections" 2 connections;
      assert_int "ssh ptys" 6 ptys
  | _ -> fail "VM stats output should parse");
  match Virtle.parse_vm_stats "- 0 0\n" with
  | Some (None, 0, 0) -> ()
  | _ -> fail "missing VM IP should parse"

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

let test_virtiofs_idmap_args () =
  assert_equal "virtiofs subordinate id mappings"
    "--uid-map=:0:1000:1:,--uid-map=:1:100000:65535:,--gid-map=:0:200000:65536:"
    (String.concat ","
       (Virtle.virtiofs_idmap_args ~uid:1000 ~subuid_start:100000
          ~subgid_start:200000))

let test_virtiofs_idmap_fallback () =
  let root = temp_dir "ash-test-idmap-fallback" in
  let identity =
    Virtle.Idmapped { uid = 1000; subuid_start = 100000; subgid_start = 200000 }
  in
  let result =
    Virtle.prepare_guest_store_dirs ~run_foreground:(fun _ _ -> 1) identity root
  in
  (match result with
  | Virtle.Squashed _ -> ()
  | Virtle.Idmapped _ -> fail "failed id mapping should fall back to squash");
  let upper = Filename.concat root "guest-store-upper" in
  assert_bool "fallback guest store upper exists" true (Sys.is_directory upper);
  assert_int "fallback guest store upper mode" 0o1777
    ((Unix.stat upper).st_perm land 0o7777)

let test_inspect_infers_fixed_mount_targets () =
  let fields tag =
    [ ("type", Otoml.TomlString "virtiofs"); ("tag", Otoml.TomlString tag) ]
  in
  assert_bool "hotmount target" true
    (Virtle.configured_mount_target (fields "hotmounts")
    = Some "/run/ash/hotmounts");
  assert_bool "shares ro target" true
    (Virtle.configured_mount_target (fields "shares-ro")
    = Some "/run/ash/shares/ro");
  assert_bool "shares rw target" true
    (Virtle.configured_mount_target (fields "shares-rw")
    = Some "/run/ash/shares/rw");
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
  let config_path = Filename.concat root "config.toml" in
  write_file config_path
    {|[spaces.rust]
rw_mounts = []

[spaces.go]
ro_mounts = []
|};
  write_file
    (Virtle.ash_config_path ~name)
    (Printf.sprintf
       {|[spawn]
config_path = %S
flake = "github:example/vms#agent"
spaces = ["rust", "go"]
|}
       config_path);
  let guest_path = "/home/agent/project" in
  let source_name = Virtle.hotmount_slug ~host_dir ~guest_path in
  Virtle.write_hotmount_metadata_record
    (Virtle.hotmount_metadata ~name ~source_name ~host_dir ~guest_path
       ~mode:Virtle.Read_write);
  let json = Virtle.inspect_vm_json ~name in
  let open Yojson.Safe.Util in
  assert_equal "inspect name" name (json |> member "name" |> to_string);
  assert_equal "inspect status" "stopped" (json |> member "status" |> to_string);
  assert_equal "inspect control socket"
    (Filename.concat state_dir "virtle_state/virtle.sock")
    (json |> member "runtime" |> member "controlSocket" |> to_string);
  assert_equal "inspect flake" "github:example/vms#agent"
    (json |> member "ash" |> member "config" |> member "spawn" |> member "flake"
   |> to_string);
  assert_bool "inspect ash config contains rust space" true
    (json |> member "config" |> member "config" |> member "spaces"
   |> member "rust" <> `Null);
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
  let config_path = Filename.concat root "config.toml" in
  write_file config_path "[spaces]\n";
  let config = Ash_config.load config_path in
  let _, manifest =
    render ~config ~flake:"../my-nix#agent" ~name:"kitty" ~kitty:true ()
  in
  let doc = parse_toml manifest in
  let kitty_wrapper =
    Filename.concat state "ash/kitty/ssh-with-space-mounts-kitty"
  in
  assert_equal "selected kitty wrapper" kitty_wrapper
    (List.hd (find_strings doc [ "ssh"; "exec" ]))

let test_waypipe_wraps_openssh_and_kitty () =
  let root = temp_dir "ash-test-waypipe" in
  let home = Filename.concat root "home" in
  let state = Filename.concat root "state" in
  mkdir_p home;
  mkdir_p state;
  Unix.putenv "HOME" home;
  Unix.putenv "XDG_STATE_HOME" state;
  let config = parse_toml "[spaces]\n" in
  let _, manifest =
    render ~config ~flake:"../my-nix#agent" ~name:"wayland"
      ~waypipe:"/bin/waypipe" ()
  in
  let manifest_doc = parse_toml manifest in
  let exec = find_strings manifest_doc [ "ssh"; "exec" ] in
  let openssh_wrapper =
    Filename.concat state "ash/wayland/ssh-with-space-mounts"
  in
  let waypipe_wrapper = Filename.concat state "ash/wayland/ssh-with-waypipe" in
  assert_equal "Waypipe manifest wrapper" waypipe_wrapper (List.hd exec);
  assert_int "Waypipe manifest exec count" 1 (List.length exec);
  assert_bool "Virtle SSH autoprovision disabled" false
    (find_bool manifest_doc [ "ssh"; "autoprovision" ]);
  let waypipe_content =
    In_channel.with_open_text waypipe_wrapper In_channel.input_all
  in
  assert_string_contains "Waypipe executable" waypipe_content "/bin/waypipe";
  assert_string_contains "Waypipe disables GPU protocols" waypipe_content
    "--no-gpu";
  assert_string_contains "Waypipe remote binary" waypipe_content
    "'--remote-bin' 'waypipe'";
  assert_string_contains "Waypipe enables X11 compatibility" waypipe_content
    "'--xwls'";
  assert_string_contains "Waypipe wraps OpenSSH helper" waypipe_content
    openssh_wrapper;
  assert_string_contains "Waypipe forwards SSH arguments" waypipe_content
    {|'ssh' "$@"|};
  let _, kitty_manifest =
    render ~config ~flake:"../my-nix#agent" ~name:"wayland-kitty" ~kitty:true
      ~waypipe:"/bin/waypipe" ()
  in
  let kitty_exec = find_strings (parse_toml kitty_manifest) [ "ssh"; "exec" ] in
  let kitty_wrapper =
    Filename.concat state "ash/wayland-kitty/ssh-with-space-mounts-kitty"
  in
  let kitty_waypipe_wrapper =
    Filename.concat state "ash/wayland-kitty/ssh-with-waypipe-kitty"
  in
  assert_equal "Waypipe Kitty manifest wrapper" kitty_waypipe_wrapper
    (List.hd kitty_exec);
  assert_string_contains "Waypipe wraps Kitty SSH helper"
    (In_channel.with_open_text kitty_waypipe_wrapper In_channel.input_all)
    kitty_wrapper

let test_spawn_reuses_saved_flake_when_omitted () =
  let root = temp_dir "ash-test-saved-flake" in
  Unix.putenv "XDG_STATE_HOME" root;
  let name = "existing-vm" in
  let saved_flake = "/tmp/saved-flake#agent" in
  let inputs : Virtle.manifest_inputs =
    {
      config_path = "/tmp/ash-config.toml";
      flake = saved_flake;
      override_inputs =
        [ ("ash", "/tmp/local-ash"); ("nixpkgs", "github:NixOS/nixpkgs") ];
      name;
      spaces = [ "base" ];
      user = None;
      kernel_serial = Virtle.Console;
      mount_cwd = false;
      nix_store_strategy = Some Ash_config.Image;
      nix_store_image_size_mib = Some 32768;
      ro_store_socket = None;
      ssh = None;
      systemd_ssh_proxy = None;
      registration_path = Some "/nix/store/closure-info/registration";
      kitty = false;
      waypipe = Some "/bin/waypipe";
      virtiofsd = "/bin/virtiofsd";
      virtle = "/bin/virtle";
    }
  in
  let state_path = Virtle.ash_config_path ~name in
  assert_equal "state filename" "ash-state.toml" (Filename.basename state_path);
  write_file state_path (Virtle.ash_config inputs);
  let saved = Virtle.load_ash_config ~name in
  assert_equal "saved registration path" "/nix/store/closure-info/registration"
    (Option.value saved.registration_path ~default:"");
  assert_bool "saved kernel serial" true (saved.kernel_serial = Virtle.Console);
  assert_equal "saved Waypipe executable" "/bin/waypipe"
    (Option.value saved.waypipe ~default:"");
  assert_equal "saved flake" saved_flake (Virtle.resolve_spawn_flake ~name None);
  assert_bool "saved Nix store strategy" true
    (Virtle.resolve_spawn_nix_store_strategy ~name None = Some Ash_config.Image);
  assert_int "saved Nix store image size" 32768
    (Option.value
       (Virtle.resolve_spawn_nix_store_image_size ~name None)
       ~default:0);
  assert_bool "explicit Nix store strategy overrides saved" true
    (Virtle.resolve_spawn_nix_store_strategy ~name (Some Ash_config.Shared)
    = Some Ash_config.Shared);
  assert_int "explicit Nix store image size overrides saved" 65536
    (Option.value
       (Virtle.resolve_spawn_nix_store_image_size ~name (Some 65536))
       ~default:0);
  assert_equal "explicit flake overrides saved" "github:owner/repo#other"
    (Virtle.resolve_spawn_flake ~name (Some "github:owner/repo#other"));
  assert_equal "saved override inputs"
    "ash=/tmp/local-ash,nixpkgs=github:NixOS/nixpkgs"
    (Virtle.resolve_spawn_override_inputs ~name []
    |> List.map (fun (input, flake) -> input ^ "=" ^ flake)
    |> String.concat ",");
  assert_equal "explicit override inputs replace saved" "ash=path:../ash"
    (Virtle.resolve_spawn_override_inputs ~name [ ("ash", "path:../ash") ]
    |> List.map (fun (input, flake) -> input ^ "=" ^ flake)
    |> String.concat ",");
  assert_equal "saved spaces" "base"
    (String.concat "," (Virtle.resolve_spawn_spaces ~name []));
  assert_equal "explicit spaces override saved" "rust,go"
    (String.concat "," (Virtle.resolve_spawn_spaces ~name [ "rust"; "go" ]));
  let legacy_name = "legacy-serial-vm" in
  write_file
    (Virtle.ash_config_path ~name:legacy_name)
    "[spawn]\n\
     config_path = '/tmp/ash-config.toml'\n\
     flake = '/tmp/saved-flake#agent'\n\
     override_inputs = []\n\
     name = 'legacy-serial-vm'\n\
     spaces = []\n\
     print_serial = true\n\
     mount_cwd = false\n\
     kitty = false\n\
     virtiofsd = '/bin/virtiofsd'\n\
     virtle = '/bin/virtle'\n";
  assert_bool "legacy print_serial loads as print" true
    ((Virtle.load_ash_config ~name:legacy_name).kernel_serial = Virtle.Print);
  assert_equal "new VM has no default spaces" ""
    (String.concat "," (Virtle.resolve_spawn_spaces ~name:"new-vm" []))

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

let test_nix_override_input_args () =
  assert_equal "Nix override input arguments"
    "--override-input 'ash' 'path:../ash' --override-input 'nixpkgs' \
     'github:NixOS/nixpkgs'"
    (Nix.override_input_args
       [ ("ash", "path:../ash"); ("nixpkgs", "github:NixOS/nixpkgs") ]);
  assert_equal "Nix eval override input placement"
    "eval --override-input 'ash' 'path:../ash' --raw 'flake#attr'"
    (Nix.subcommand_args "eval" [ ("ash", "path:../ash") ] "--raw 'flake#attr'")

let test_nix_local_store_uri () =
  assert_equal "local store URI encodes paths"
    "local?real=%2Fnix%2Fstore&state=%2Fstate%2Fwith%20spaces"
    (Nix.local_store_uri ~real:"/nix/store" ~state:"/state/with spaces")

let test_native_closure_info () =
  let json =
    {|{
  "/nix/store/b": {
    "narHash": "sha256-b",
    "narSize": 2,
    "references": ["/nix/store/z", "/nix/store/a"]
  },
  "/nix/store/a": {
    "narHash": "sha256-a",
    "narSize": 1,
    "references": []
  }
}|}
  in
  let infos = Nix.closure_path_infos json in
  assert_equal "native closure paths are deterministic"
    "/nix/store/a,/nix/store/b"
    (infos
    |> List.map (fun (info : Nix.closure_path_info) -> info.path)
    |> String.concat ",");
  let expected_registration =
    "/nix/store/a\n\
     sha256-a\n\
     1\n\n\
     0\n\
     /nix/store/b\n\
     sha256-b\n\
     2\n\n\
     2\n\
     /nix/store/a\n\
     /nix/store/z\n"
  in
  assert_equal "native registration serialization" expected_registration
    (Nix.registration_content infos);
  assert_equal "nixpkgs registration parser canonicalization"
    expected_registration
    (Nix.registration_path_infos expected_registration
    |> Nix.registration_content);
  assert_equal "nested registration store object" "/nix/store/hash-closure-info"
    (Nix.containing_store_path "/nix/store/hash-closure-info/registration");
  assert_equal "direct registration store object" "/nix/store/hash-registration"
    (Nix.containing_store_path "/nix/store/hash-registration");
  let root = temp_dir "ash-test-native-closure-info" in
  let nix = Filename.concat root "nix" in
  let args_log = Filename.concat root "args" in
  write_file nix
    "#!/bin/sh\n\
     printf '%s\\n' \"$*\" >> \"$ASH_TEST_NIX_PATH_INFO_ARGS\"\n\
     cat <<'JSON'\n\
     {\"/nix/store/a\":{\"narHash\":\"sha256-a\",\"narSize\":1,\"references\":[]}}\n\
     JSON\n";
  Unix.chmod nix 0o755;
  Unix.putenv "ASH_TEST_NIX_PATH_INFO_ARGS" args_log;
  let queried = Nix.query_closure_info ~nix ~toplevel:"/nix/store/system" in
  assert_int "native closure info uses one Nix process" 1
    (In_channel.with_open_text args_log In_channel.input_lines |> List.length);
  assert_equal "native closure query result" "/nix/store/a"
    (List.hd queried : Nix.closure_path_info).path

let test_prepare_lower_store () =
  let root = temp_dir "ash-test-lower-store" in
  let bin = Filename.concat root "bin" in
  let registration = Filename.concat root "registration" in
  let state = Filename.concat root "state with spaces" in
  let args_log = Filename.concat root "args" in
  let stdin_log = Filename.concat root "stdin" in
  mkdir_p bin;
  write_file registration "registration-data\n";
  let nix_store = Filename.concat bin "nix-store" in
  write_file nix_store
    "#!/bin/sh\n\
     printf '%s\\n' \"$@\" > \"$ASH_TEST_NIX_STORE_ARGS\"\n\
     cat > \"$ASH_TEST_NIX_STORE_STDIN\"\n";
  Unix.chmod nix_store 0o755;
  Unix.putenv "ASH_TEST_NIX_STORE_ARGS" args_log;
  Unix.putenv "ASH_TEST_NIX_STORE_STDIN" stdin_log;
  Nix.prepare_lower_store ~nix_store ~registration ~state;
  assert_bool "lower store state created" true (Sys.is_directory state);
  assert_equal "lower store registration input" "registration-data\n"
    (In_channel.with_open_text stdin_log In_channel.input_all);
  let args = In_channel.with_open_text args_log In_channel.input_all in
  assert_string_contains "lower store load-db argument" args "--load-db";
  assert_string_contains "lower store URI uses host store" args
    "local?real=%2Fnix%2Fstore&state=";
  assert_string_contains "lower store URI encodes state path" args
    "%2Fstate%20with%20spaces.tmp-"

let test_prepare_image_store () =
  let root = temp_dir "ash-test-image-store-prepare" in
  let bin = Filename.concat root "bin" in
  let sources = Filename.concat root "sources" in
  let system_source = Filename.concat sources "system" in
  let registration_source = Filename.concat sources "closure-info" in
  let image = Filename.concat root "nix-store.img" in
  let second_image = Filename.concat root "second/nix-store.img" in
  let cache_image = Filename.concat root "cache/nix-store.img" in
  let nix_args = Filename.concat root "nix-args" in
  let copy_args = Filename.concat root "copy-args" in
  let e2fsck_args = Filename.concat root "e2fsck-args" in
  let resize2fs_args = Filename.concat root "resize2fs-args" in
  mkdir_p bin;
  write_file (Filename.concat system_source "bin/init") "system-init\n";
  write_file
    (Filename.concat registration_source "registration")
    "registration-data\n";
  let nix = Filename.concat bin "nix" in
  write_file nix
    "#!/bin/sh\n\
     printf '%s\\n' \"$@\" >> \"$ASH_TEST_NIX_ARGS\"\n\
     printf '%s\\n' \"$ASH_TEST_SYSTEM_SOURCE\" \
     \"$ASH_TEST_REGISTRATION_SOURCE\"\n";
  let copy = Filename.concat bin "cp" in
  let real_copy = Util.get_exe None "cp" in
  write_file copy
    ("#!/bin/sh\nprintf '%s\\n' \"$@\" >> \"$ASH_TEST_COPY_ARGS\"\nexec "
   ^ Util.shell_quote real_copy ^ " \"$@\"\n");
  let e2fsck = Filename.concat bin "e2fsck" in
  write_file e2fsck
    "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$ASH_TEST_E2FSCK_ARGS\"\n";
  let resize2fs = Filename.concat bin "resize2fs" in
  write_file resize2fs
    "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$ASH_TEST_RESIZE2FS_ARGS\"\n";
  List.iter (fun path -> Unix.chmod path 0o755) [ nix; copy; e2fsck; resize2fs ];
  Unix.putenv "ASH_TEST_NIX_ARGS" nix_args;
  Unix.putenv "ASH_TEST_COPY_ARGS" copy_args;
  Unix.putenv "ASH_TEST_SYSTEM_SOURCE" system_source;
  Unix.putenv "ASH_TEST_REGISTRATION_SOURCE" registration_source;
  Unix.putenv "ASH_TEST_E2FSCK_ARGS" e2fsck_args;
  Unix.putenv "ASH_TEST_RESIZE2FS_ARGS" resize2fs_args;
  Nix.prepare_image_store ~nix_executable:nix ~copy_executable:copy ~resize2fs
    ~toplevel:"/nix/store/system"
    ~registration:"/nix/store/closure-info/registration" ~cache_image ~image
    ~size_mib:256 ();
  assert_bool "cached image store created" true (Sys.file_exists cache_image);
  assert_bool "image store created" true (Sys.file_exists image);
  assert_bool "image store marker created" true
    (Sys.file_exists (image ^ ".toplevel"));
  assert_equal "image store marker"
    "4\n/nix/store/system\n256\n/nix/store/closure-info/registration\n"
    (In_channel.with_open_text (image ^ ".toplevel") In_channel.input_all);
  assert_bool "image store is correctly sized" true
    (Int64.equal (Unix.LargeFile.stat image).st_size 268435456L);
  assert_bool "cached base is smaller than writable VM image" true
    (Int64.compare (Unix.LargeFile.stat cache_image).st_size
       (Unix.LargeFile.stat image).st_size
    < 0);
  let closure_args = In_channel.with_open_text nix_args In_channel.input_all in
  assert_string_contains "image store resolves closure" closure_args
    "path-info\n-r\n";
  assert_string_contains "image store includes toplevel" closure_args
    "/nix/store/system";
  assert_string_contains "image store includes registration output" closure_args
    "/nix/store/closure-info";
  let system_contents =
    Util.command_output
      ("debugfs -R "
      ^ Filename.quote "cat /store/system/bin/init"
      ^ " " ^ Filename.quote image ^ " 2>/dev/null")
  in
  assert_equal "image store system contents" "system-init" system_contents;
  let registration_contents =
    Util.command_output
      ("debugfs -R "
      ^ Filename.quote "cat /store/closure-info/registration"
      ^ " " ^ Filename.quote image ^ " 2>/dev/null")
  in
  assert_equal "image store registration contents" "registration-data"
    registration_contents;
  Nix.prepare_image_store ~nix_executable:nix ~copy_executable:copy ~resize2fs
    ~toplevel:"/nix/store/system"
    ~registration:"/nix/store/closure-info/registration" ~cache_image
    ~image:second_image ~size_mib:384 ();
  assert_bool "different-sized image store cloned from cache" true
    (Sys.file_exists second_image);
  assert_bool "different-sized image store is correctly sized" true
    (Int64.equal (Unix.LargeFile.stat second_image).st_size 402653184L);
  let closure_resolutions =
    In_channel.with_open_text nix_args In_channel.input_lines
    |> List.filter (fun line -> line = "path-info")
    |> List.length
  in
  assert_int "closure scanned once for cached images" 1 closure_resolutions;
  let copy_invocations =
    In_channel.with_open_text copy_args In_channel.input_all
  in
  assert_string_contains "cached image clone requests reflink" copy_invocations
    "--reflink=auto";
  assert_string_contains "cached image clone preserves sparse layout"
    copy_invocations "--sparse=always";
  assert_bool "cached images are independent files" true
    ((Unix.stat image).st_ino <> (Unix.stat second_image).st_ino);
  ignore (Util.command_output ("e2fsck -fn " ^ Filename.quote image ^ " 2>&1"));
  Nix.prepare_image_store ~e2fsck ~resize2fs ~toplevel:"/nix/store/system"
    ~registration:"/nix/store/closure-info/registration" ~image ~size_mib:512 ();
  assert_bool "image store grows backing file" true
    (Int64.equal (Unix.LargeFile.stat image).st_size 536870912L);
  assert_equal "grown image store marker"
    "4\n/nix/store/system\n512\n/nix/store/closure-info/registration\n"
    (In_channel.with_open_text (image ^ ".toplevel") In_channel.input_all);
  assert_equal "e2fsck receives forced preen arguments"
    ("-f\n-p\n" ^ image ^ "\n")
    (In_channel.with_open_text e2fsck_args In_channel.input_all);
  assert_equal "resize2fs receives image path" (image ^ "\n")
    (In_channel.with_open_text resize2fs_args In_channel.input_all);
  let updated_system_source = Filename.concat sources "system-v2" in
  let updated_registration_source = Filename.concat sources "closure-info-v2" in
  write_file
    (Filename.concat updated_system_source "bin/init")
    "updated-system-init\n";
  write_file
    (Filename.concat updated_registration_source "registration")
    "updated-registration-data\n";
  Unix.putenv "ASH_TEST_SYSTEM_SOURCE" updated_system_source;
  Unix.putenv "ASH_TEST_REGISTRATION_SOURCE" updated_registration_source;
  Nix.prepare_image_store ~nix_executable:nix ~e2fsck ~resize2fs
    ~toplevel:"/nix/store/system-v2"
    ~registration:"/nix/store/closure-info-v2/registration" ~image ~size_mib:512
    ();
  assert_equal "updated image store marker"
    "4\n/nix/store/system-v2\n512\n/nix/store/closure-info-v2/registration\n"
    (In_channel.with_open_text (image ^ ".toplevel") In_channel.input_all);
  let retained_contents =
    Util.command_output
      ("debugfs -R "
      ^ Filename.quote "cat /store/system/bin/init"
      ^ " " ^ Filename.quote image ^ " 2>/dev/null")
  in
  assert_equal "closure update retains old store paths" "system-init"
    retained_contents;
  let updated_contents =
    Util.command_output
      ("debugfs -R "
      ^ Filename.quote "cat /store/system-v2/bin/init"
      ^ " " ^ Filename.quote image ^ " 2>/dev/null")
  in
  assert_equal "closure update imports new store paths" "updated-system-init"
    updated_contents

let test_nix_json_string_array_parser () =
  assert_equal "nix json array" "a,b c,d\ne"
    (String.concat "," (Nix.parse_json_string_array {|["a","b c","d\ne"]|}))

let test_scp_args () =
  let args =
    Virtle.scp_args ~wrapper:"/state/ssh-wrapper" ~identity:"/state/id"
      ~host_name:"vsock/7" ~recursive:true ~source:"src dir"
      ~destination:"user@ash-vm-7:~/dst dir"
  in
  assert_equal "scp args"
    "-S,/state/ssh-wrapper,-i,/state/id,-o,IdentitiesOnly=yes,-o,HostName=vsock/7,-r,--,src \
     dir,user@ash-vm-7:~/dst dir"
    (String.concat "," args)

let test_remove_nix_store_state () =
  let root = temp_dir "ash-test-rebuild-db" in
  let previous = Sys.getenv_opt "XDG_STATE_HOME" in
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "XDG_STATE_HOME" (Option.value previous ~default:""))
    (fun () ->
      Unix.putenv "XDG_STATE_HOME" root;
      let name = "work" in
      let shares = Virtle.shares_dir ~name in
      let preserved =
        Filename.concat (Virtle.state_dir name) "workspace/keep"
      in
      write_file (Filename.concat shares "ro/guest-store-state/db.sqlite") "db";
      write_file
        (Filename.concat shares "rw/guest-store-upper/store-path")
        "path";
      write_file preserved "keep";
      let image = Filename.concat (Virtle.state_dir name) "nix-store.img" in
      write_file image "image";
      write_file (image ^ ".toplevel") "/nix/store/system\n";
      Virtle.remove_nix_store_state ~name;
      assert_bool "Nix store shares removed" false (Sys.file_exists shares);
      assert_bool "Nix store image removed" false (Sys.file_exists image);
      assert_bool "Nix store image marker removed" false
        (Sys.file_exists (image ^ ".toplevel"));
      assert_bool "other VM state preserved" true (Sys.file_exists preserved))

let test_state_sizes_ignore_hotmounts () =
  let root = temp_dir "ash-test-size" in
  let hotmounts = Filename.concat root "hotmounts" in
  let shares = Filename.concat root "shares" in
  let workspace = Filename.concat root "workspace" in
  mkdir_p hotmounts;
  mkdir_p shares;
  mkdir_p workspace;
  write_file (Filename.concat hotmounts "big") (String.make (1024 * 1024) 'x');
  write_file (Filename.concat shares "big") (String.make (1024 * 1024) 'x');
  write_file (Filename.concat workspace "small") "x";
  assert_bool "disk usage ignores hotmounts and shares" true
    (Virtle.disk_usage root < 524288L);
  assert_bool "apparent size ignores hotmounts and shares" true
    (Virtle.state_path_size root < 524288L)

let test_mdns_dns_labels () =
  assert_equal "simple DNS label" "work" (Util.dns_label "work");
  let transformed = Util.dns_label "Work_VM" in
  assert_bool "transformed DNS label is bounded" true
    (String.length transformed <= 63);
  assert_string_contains "transformed DNS label has readable prefix" transformed
    "work-vm-";
  assert_bool "normalization avoids collisions" true
    (Util.dns_label "Work_VM" <> Util.dns_label "work-vm")

let test_tui_text_sanitization () =
  assert_equal "valid UTF-8 is preserved" "café" (Tui.sanitize_text "café");
  assert_equal "invalid and control characters are replaced" "��"
    (Tui.sanitize_text "\255\n")

let test_tui_visible_range () =
  let start, stop = Tui.visible_range ~length:20 ~cursor:0 ~height:10 in
  assert_int "initial TUI viewport start" 0 start;
  assert_int "initial TUI viewport stop" 6 stop;
  let start, stop = Tui.visible_range ~length:20 ~cursor:9 ~height:10 in
  assert_int "scrolled TUI viewport start" 4 start;
  assert_int "scrolled TUI viewport stop" 10 stop;
  let start, stop = Tui.visible_range ~length:3 ~cursor:2 ~height:20 in
  assert_int "short TUI viewport start" 0 start;
  assert_int "short TUI viewport stop" 3 stop

let test_tui_pane_sorting_preserves_selection () =
  let pane : string Tui.pane =
    {
      title = "items";
      columns = "VALUE";
      items = [| "b"; "aaa"; "cc" |];
      label = Fun.id;
      detail = Fun.id;
      selection_summary = (fun selected -> string_of_int (List.length selected));
      sorts =
        [|
          {
            name = "length";
            compare =
              (fun left right ->
                Int.compare (String.length left) (String.length right));
          };
          { name = "name"; compare = String.compare };
        |];
      bulk_actions =
        [| { key = 'u'; select = (fun item -> String.length item = 2) } |];
      initial_descending = true;
    }
  in
  let state = Tui.make_pane_state pane in
  assert_equal "descending pane sort" "aaa" state.rows.(0).item;
  state.rows.(0).selected <- true;
  Tui.next_sort state;
  assert_bool "cycling sort preserves direction" true state.descending;
  state.descending <- false;
  Tui.sort_pane state;
  assert_equal "ascending pane sort" "aaa" state.rows.(0).item;
  assert_bool "selection follows sorted item" true state.rows.(0).selected;
  Tui.apply_bulk_action state 'u';
  assert_equal "bulk selection preserves and adds matches" "aaa,cc"
    (Tui.selected_rows state |> String.concat ",")

let run name test =
  Printf.printf "test %s ... %!" name;
  test ();
  Printf.printf "ok\n%!"

let () =
  run "spaces render to virtle manifest" test_spaces_to_virtle_manifest;
  run "global memory config" test_global_memory_config;
  run "global network config" test_global_network_config;
  run "no spaces selected by default" test_no_spaces_selected_by_default;
  run "image-backed Nix store manifest" test_image_backed_nix_store_manifest;
  run "XDG config path" test_xdg_config_path;
  run "XDG cache home" test_xdg_cache_home;
  run "cached images for removal" test_cached_images_for_removal;
  run "XDG state path" test_xdg_state_path;
  run "space mount spec parsing" test_space_mount_spec_parsing;
  run "space extension graph traversal" test_space_extension_graph_traversal;
  run "space extension evaluation" test_space_extension_evaluation;
  run "space mount deduplication after parsing"
    test_space_mount_deduplication_after_parsing;
  run "space files render to write_files" test_space_files_render_to_write_files;
  run "managed portal manifest" test_managed_portal_manifest;
  run "D-Bus notifications manifest" test_dbus_notifications_manifest;
  run "global portal manifest" test_global_portal_manifest;
  run "disabled portal manifest" test_disabled_portal_manifest;
  run "ro-store socket override" test_ro_store_socket_override;
  run "kitty selects kitten ssh wrapper" test_kitty_selects_kitten_ssh_wrapper;
  run "waypipe wraps OpenSSH and Kitty" test_waypipe_wraps_openssh_and_kitty;
  run "qga params use valid json" test_qga_params_use_valid_json;
  run "qga int field finds nested values" test_qga_int_field_finds_nested_values;
  run "qga output data decodes base64" test_qga_output_data_decodes_base64;
  run "qga loads Nix registration" test_qga_load_nix_registration_action;
  run "qga VM stats action" test_qga_vm_stats_action;
  run "stop warns about active ssh" test_active_ssh_warning;
  run "qga unmount removes empty mountpoint"
    test_qga_unmount_removes_empty_mountpoint;
  run "qga mountpoint inherits parent owner"
    test_qga_mountpoint_inherits_parent_owner;
  run "virtiofs cache options" test_virtiofs_cache_options;
  run "virtiofs subordinate id mappings" test_virtiofs_idmap_args;
  run "virtiofs idmap fallback" test_virtiofs_idmap_fallback;
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
  run "nix override input arguments" test_nix_override_input_args;
  run "nix local store URI" test_nix_local_store_uri;
  run "native closure info" test_native_closure_info;
  run "prepare lower store" test_prepare_lower_store;
  run "prepare image store" test_prepare_image_store;
  run "nix json string array parser" test_nix_json_string_array_parser;
  run "scp arguments" test_scp_args;
  run "remove Nix store state" test_remove_nix_store_state;
  run "state sizes ignore hotmounts" test_state_sizes_ignore_hotmounts;
  run "TUI text sanitization" test_tui_text_sanitization;
  run "TUI visible range" test_tui_visible_range;
  run "TUI pane sorting preserves selection"
    test_tui_pane_sorting_preserves_selection;
  run "mDNS DNS labels" test_mdns_dns_labels
