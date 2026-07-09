type target = { attr : string; host_name : string }

type boot = {
  kernel : string;
  initrd : string;
  kernel_params : string list;
  ssh : string;
  systemd_ssh_proxy : string;
}

let parse_string_array = Agent_box.parse_string_array

let nix_exe =
  lazy
    (match Util.find_in_path "nix" with
    | Some path ->
        Log.debug "executable=%S resolved=%S" "nix" path;
        path
    | None ->
        Log.fatal ~code:127
          "could not find executable \"nix\"\n\n\
           Hint: install Nix or run ash in an environment with nix in PATH.")

let nix_command args = Util.shell_quote (Lazy.force nix_exe) ^ " " ^ args

let run_nix ~label ~attr args =
  try Util.command_output (nix_command args)
  with Failure message ->
    Log.fatal "failed to resolve %s\n\nNix attr: %s\nError: %s" label attr
      message

let eval_raw ~label attr =
  run_nix ~label ~attr ("eval --raw " ^ Util.shell_quote attr)

let eval_json ~label attr =
  run_nix ~label ~attr ("eval --json " ^ Util.shell_quote attr)

let build_path ~label attr =
  run_nix ~label ~attr
    ("build --no-link --print-out-paths " ^ Util.shell_quote attr)

let split_flake_ref value =
  match String.index_opt value '#' with
  | None -> (value, None)
  | Some idx ->
      let base = String.sub value 0 idx in
      let fragment =
        String.sub value (idx + 1) (String.length value - idx - 1)
      in
      (base, Some fragment)

let normalize_flake_path path = Util.expand_home path

let flake_ref path =
  let base, fragment = split_flake_ref path in
  let base = normalize_flake_path base in
  match fragment with None -> base | Some fragment -> base ^ "#" ^ fragment

let resolve_target ~flake =
  let base, fragment = split_flake_ref flake in
  if Filename.basename base = "flake.nix" then
    Log.fatal
      "--flake must point to a flake directory, not flake.nix\n\n\
       Hint: use --flake %s#HOST instead."
      (Filename.dirname base);
  let base = normalize_flake_path base in
  match fragment with
  | Some host when host <> "" && not (String.contains host '.') ->
      { attr = base ^ "#nixosConfigurations." ^ host; host_name = host }
  | Some fragment ->
      Log.fatal
        "unsupported flake attr fragment: %s\n\n\
         Hint: use --flake FLAKE#HOST, for example ../my-nix#agent."
        fragment
  | None ->
      Log.fatal
        "--flake must include a host fragment\n\n\
         Hint: use --flake FLAKE#HOST, for example ../my-nix#agent."

let attr_segment segment =
  let b = Buffer.create (String.length segment + 8) in
  Buffer.add_char b '"';
  String.iter
    (function
      | '"' -> Buffer.add_string b "\\\""
      | '\\' -> Buffer.add_string b "\\\\"
      | c -> Buffer.add_char b c)
    segment;
  Buffer.add_char b '"';
  Buffer.contents b

let validate_user ~target ~user =
  let attr =
    target.attr ^ ".config.users.users." ^ attr_segment user ^ ".name"
  in
  let resolved = eval_raw ~label:("guest user " ^ user) attr in
  if resolved <> user then
    Log.fatal
      "guest user validation failed\n\n\
       Requested user: %s\n\
       NixOS user attr resolved to: %s"
      user resolved

let resolve_boot ~target =
  let attr = target.attr in
  let kernel_dir =
    build_path ~label:"kernel build output"
      (attr ^ ".config.system.build.kernel")
  in
  let kernel_file =
    eval_raw ~label:"kernel file name"
      (attr ^ ".config.system.boot.loader.kernelFile")
  in
  let initrd_output =
    build_path ~label:"initial ramdisk build output"
      (attr ^ ".config.system.build.initialRamdisk")
  in
  let initrd =
    if Sys.is_directory initrd_output then
      Filename.concat initrd_output "initrd"
    else initrd_output
  in
  if not (Sys.file_exists initrd) then
    Log.fatal
      "failed to resolve initrd file\n\n\
       Initial ramdisk output: %s\n\
       Expected initrd file: %s"
      initrd_output initrd;
  let toplevel =
    build_path ~label:"NixOS toplevel build output"
      (attr ^ ".config.system.build.toplevel")
  in
  let openssh = eval_raw ~label:"OpenSSH package" (attr ^ ".pkgs.openssh") in
  let systemd =
    eval_raw ~label:"systemd package" (attr ^ ".config.systemd.package")
  in
  let kernel_params =
    eval_json ~label:"kernel parameters" (attr ^ ".config.boot.kernelParams")
    |> parse_string_array
  in
  let init_param = "init=" ^ Filename.concat toplevel "init" in
  let has_init_param =
    List.exists
      (fun param -> String.starts_with ~prefix:"init=" param)
      kernel_params
  in
  let kernel_params =
    if has_init_param then kernel_params else init_param :: kernel_params
  in
  {
    kernel = Filename.concat kernel_dir kernel_file;
    initrd;
    kernel_params;
    ssh = Filename.concat openssh "bin/ssh";
    systemd_ssh_proxy = Filename.concat systemd "lib/systemd/systemd-ssh-proxy";
  }
