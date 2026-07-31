open Cmdliner

let flake_target =
  let parse value =
    try
      ignore (Image_import.Nix.toplevel_attr ~flake:value);
      Ok value
    with Invalid_argument message -> Error (`Msg message)
  in
  Arg.conv (parse, Format.pp_print_string)

let flake_arg =
  let doc =
    "Flake reference and NixOS host, such as ../my-nix#agent. The fragment is \
     resolved as nixosConfigurations.HOST."
  in
  Arg.(
    required
    & opt (some flake_target) None
    & info [ "flake" ] ~docv:"FLAKE#HOST" ~doc)

let out_arg =
  let doc = "Output path for the image." in
  Arg.(required & opt (some string) None & info [ "out" ] ~docv:"PATH" ~doc)

let jobs_arg =
  Arg.(
    value & opt int 4 & info [ "jobs" ] ~docv:"N" ~doc:"Parallel scan workers.")

let dry_run_arg =
  Arg.(value & flag & info [ "dry-run" ] ~doc:"Only scan and log metrics.")

let reporter =
  Image_import_core.Reporter.make
    ~debug:(fun message -> Ash.Log.debug "%s" message)
    ~info:(fun message -> Ash.Log.info "%s" message)

let run flake out jobs dry_run =
  let metrics = Image_import_core.Metrics.create () in
  let toplevel = Image_import.Nix.build_toplevel ~flake |> String.trim in
  Ash.Log.info "output=%s" out;
  let closure_paths = Image_import.Nix.closure_paths ~path:toplevel in
  let total_bytes = Image_import.Nix.closure_size ~path:toplevel in
  let entries =
    Image_import_core.Scan.scan_closure ~reporter ~jobs ~closure_paths
      ~target_root:"/nix/store" ~total_bytes metrics
  in
  if dry_run then print_endline (String.concat "\n" closure_paths)
  else Image_import_core.Import.write_image ~reporter ~path:out ~metrics entries;
  Image_import_core.Metrics.log ~reporter ~prefix:"nix-ext4-image" metrics

let cmd =
  Cmd.v
    (Cmd.info "nix-ext4-image" ~doc:"Import a NixOS closure into an ext4 image.")
    Term.(const run $ flake_arg $ out_arg $ jobs_arg $ dry_run_arg)

let () = exit (Cmd.eval cmd)
