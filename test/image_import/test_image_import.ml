open Image_import_core

let fail msg = failwith msg

let assert_equal label expected actual =
  if expected <> actual then
    fail (Printf.sprintf "%s: expected %S, got %S" label expected actual)

let assert_bool label actual = if not actual then fail label

let assert_int label expected actual =
  if expected <> actual then
    fail (Printf.sprintf "%s: expected %d, got %d" label expected actual)

let temp_dir prefix =
  let path = Filename.temp_file prefix "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  path

let remove_tree path = ignore (Unix.system ("rm -rf -- " ^ Filename.quote path))

let command_output command =
  let channel = Unix.open_process_in command in
  let output = In_channel.input_all channel in
  match Unix.close_process_in channel with
  | Unix.WEXITED 0 -> output
  | status ->
      fail
        (Printf.sprintf "command failed (%s): %s\n%s"
           (match status with
           | Unix.WEXITED code -> Printf.sprintf "exit %d" code
           | Unix.WSIGNALED signal -> Printf.sprintf "signal %d" signal
           | Unix.WSTOPPED signal -> Printf.sprintf "stopped %d" signal)
           command output)

let make_tree root =
  Unix.mkdir (Filename.concat root "a") 0o755;
  Unix.mkdir (Filename.concat root "a/b") 0o755;
  let oc = open_out (Filename.concat root "a/b/c.txt") in
  output_string oc "hello";
  close_out oc;
  Unix.symlink "../b/c.txt" (Filename.concat root "a/link")

let test_flake_host_target () =
  assert_equal "flake host target"
    "../my-nix#nixosConfigurations.agent.config.system.build.toplevel"
    (Image_import.Nix.toplevel_attr ~flake:"../my-nix#agent")

let test_scan () =
  let root = temp_dir "image-import" in
  Fun.protect
    ~finally:(fun () -> remove_tree root)
    (fun () ->
      make_tree root;
      let entries = Scan.of_root ~root in
      assert_bool "scan should produce entries" (List.length entries > 0))

let entry ~source ~target ~kind ~size ~mode ~link_target =
  {
    Plan.source;
    target;
    kind;
    size;
    mode;
    uid = Unix.getuid ();
    gid = Unix.getgid ();
    mtime = 1_700_000_000.;
    link_target;
  }

let test_ext4_image () =
  let root = temp_dir "image-import-ext4" in
  Fun.protect
    ~finally:(fun () -> remove_tree root)
    (fun () ->
      let source = Filename.concat root "hello.txt" in
      let oc = open_out_bin source in
      output_string oc "hello from libext2fs\n";
      close_out oc;
      let entries =
        [
          entry ~source:root ~target:"/etc" ~kind:Plan.Dir ~size:0L ~mode:0o755
            ~link_target:None;
          entry ~source ~target:"/etc/hello.txt" ~kind:Plan.File
            ~size:(Int64.of_int (Unix.stat source).Unix.st_size)
            ~mode:0o640 ~link_target:None;
          entry ~source:"" ~target:"/hello-link" ~kind:Plan.Symlink ~size:0L
            ~mode:0o777 ~link_target:(Some "etc/hello.txt");
        ]
      in
      let image = Filename.concat root "root.img" in
      let metrics = Metrics.create () in
      Import.write_image ~size:67_108_864L ~label:"ash-test" ~path:image
        ~metrics entries;
      assert_bool "image should exist" (Sys.file_exists image);
      let e2fsck = "e2fsck -fn " ^ Filename.quote image ^ " 2>&1" in
      ignore (command_output e2fsck);
      let contents =
        command_output
          ("debugfs -R "
          ^ Filename.quote "cat /etc/hello.txt"
          ^ " " ^ Filename.quote image ^ " 2>/dev/null")
      in
      assert_equal "file contents" "hello from libext2fs\n" contents;
      let listing =
        command_output
          ("debugfs -R " ^ Filename.quote "ls -l /" ^ " " ^ Filename.quote image
         ^ " 2>/dev/null")
      in
      assert_bool "root should contain etc" (String.contains listing 'e');
      assert_bool "root should contain symlink"
        (String.starts_with ~prefix:"" listing
        && Option.is_some
             (let needle = "hello-link" in
              let n = String.length needle in
              let rec find i =
                if i + n > String.length listing then None
                else if String.sub listing i n = needle then Some i
                else find (i + 1)
              in
              find 0));
      let header =
        command_output ("dumpe2fs -h " ^ Filename.quote image ^ " 2>/dev/null")
      in
      assert_bool "filesystem should have extents"
        (Option.is_some
           (let needle = "extent" in
            let n = String.length needle in
            let rec find i =
              if i + n > String.length header then None
              else if String.sub header i n = needle then Some i
              else find (i + 1)
            in
            find 0)))

let test_writable_image_inode_density () =
  let size = Int64.mul 50_000L 1_048_576L in
  assert_int "50,000 MiB inode count" 3_203_072
    (Import.estimate_inode_count ~size [])

let test_ext4_full_inode_group () =
  let root = temp_dir "image-import-inodes" in
  Fun.protect
    ~finally:(fun () -> remove_tree root)
    (fun () ->
      let entries =
        entry ~source:root ~target:"/bulk" ~kind:Plan.Dir ~size:0L ~mode:0o755
          ~link_target:None
        :: List.init 5000 (fun index ->
            entry ~source:""
              ~target:(Printf.sprintf "/bulk/link-%05d" index)
              ~kind:Plan.Symlink ~size:0L ~mode:0o777
              ~link_target:(Some "target"))
      in
      let image = Filename.concat root "multi-group.img" in
      let metrics = Metrics.create () in
      Import.write_image ~size:134_217_728L ~label:"inode-test" ~path:image
        ~metrics entries;
      ignore (command_output ("e2fsck -fn " ^ Filename.quote image ^ " 2>&1")))

let run name test =
  Printf.printf "test %s ... %!" name;
  test ();
  print_endline "ok"

let () =
  run "flake host target" test_flake_host_target;
  run "scan" test_scan;
  run "libext2fs image" test_ext4_image;
  run "writable image inode density" test_writable_image_inode_density;
  run "libext2fs full inode group" test_ext4_full_inode_group
