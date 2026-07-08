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
        Log.debug "resolved executable nix -> %s" path;
        path
    | None ->
        Printf.eprintf "ash: could not find executable \"nix\"\n\nHint: install Nix or run ash in an environment with nix in PATH.\n";
        exit 127)

let nix_command args = Util.shell_quote (Lazy.force nix_exe) ^ " " ^ args

let run_nix ~label ~attr args =
  try Util.command_output (nix_command args) with
  | Failure message ->
      Printf.eprintf "ash: failed to resolve %s\n\nNix attr: %s\nError: %s\n" label attr message;
      exit 1

let eval_raw ~label attr = run_nix ~label ~attr ("eval --raw " ^ Util.shell_quote attr)
let eval_json ~label attr = run_nix ~label ~attr ("eval --json " ^ Util.shell_quote attr)
let build_path ~label attr = run_nix ~label ~attr ("build --no-link --print-out-paths " ^ Util.shell_quote attr)

let flake_ref path =
  let path = Util.expand_home path in
  if Filename.basename path = "flake.nix" then Filename.dirname path else path

let nixos_attr ~flake ~host = flake_ref flake ^ "#nixosConfigurations." ^ host

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

let validate_user ~flake ~host ~user =
  let attr = nixos_attr ~flake ~host ^ ".config.users.users." ^ attr_segment user ^ ".name" in
  let resolved = eval_raw ~label:("guest user " ^ user) attr in
  if resolved <> user then (
    Printf.eprintf "ash: guest user validation failed\n\nRequested user: %s\nNixOS user attr resolved to: %s\n" user resolved;
    exit 1)

let resolve_boot ~flake ~host =
  let attr = nixos_attr ~flake ~host in
  let kernel_dir = build_path ~label:"kernel build output" (attr ^ ".config.system.build.kernel") in
  let kernel_file = eval_raw ~label:"kernel file name" (attr ^ ".config.system.boot.loader.kernelFile") in
  let initrd_output = build_path ~label:"initial ramdisk build output" (attr ^ ".config.system.build.initialRamdisk") in
  let initrd = if Sys.is_directory initrd_output then Filename.concat initrd_output "initrd" else initrd_output in
  if not (Sys.file_exists initrd) then (
    Printf.eprintf "ash: failed to resolve initrd file\n\nInitial ramdisk output: %s\nExpected initrd file: %s\n" initrd_output initrd;
    exit 1);
  let toplevel = build_path ~label:"NixOS toplevel build output" (attr ^ ".config.system.build.toplevel") in
  let openssh = eval_raw ~label:"OpenSSH package" (attr ^ ".pkgs.openssh") in
  let systemd = eval_raw ~label:"systemd package" (attr ^ ".config.systemd.package") in
  let kernel_params = eval_json ~label:"kernel parameters" (attr ^ ".config.boot.kernelParams") |> parse_string_array in
  let init_param = "init=" ^ Filename.concat toplevel "init" in
  let has_init_param = List.exists (fun param -> String.starts_with ~prefix:"init=" param) kernel_params in
  let kernel_params = if has_init_param then kernel_params else init_param :: kernel_params in
  {
    kernel = Filename.concat kernel_dir kernel_file;
    initrd;
    kernel_params;
    ssh = Filename.concat openssh "bin/ssh";
    systemd_ssh_proxy = Filename.concat systemd "lib/systemd/systemd-ssh-proxy";
  }
