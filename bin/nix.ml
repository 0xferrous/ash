type target = { attr : string; host_name : string }

type boot = {
  kernel : string;
  initrd : string;
  kernel_params : string list;
  registration : string;
  ssh : string;
  systemd_ssh_proxy : string;
}

let parse_json_string_array text =
  match Yojson.Safe.from_string text with
  | `List values ->
      List.map
        (function
          | `String value -> value
          | _ -> Log.fatal "expected JSON string array from nix, got: %s" text)
        values
  | _ -> Log.fatal "expected JSON string array from nix, got: %s" text

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

let build_expr_path ~label expr =
  run_nix ~label ~attr:expr
    ("build --impure --no-link --print-out-paths --expr "
   ^ Util.shell_quote expr)

let nix_string value = Yojson.Safe.to_string (`String value)

let split_flake_ref value =
  match String.index_opt value '#' with
  | None -> (value, None)
  | Some idx ->
      let base = String.sub value 0 idx in
      let fragment =
        String.sub value (idx + 1) (String.length value - idx - 1)
      in
      (base, Some fragment)

let resolve_registration ~target ~toplevel =
  let flake, _ = split_flake_ref target.attr in
  let expr =
    Printf.sprintf
      "let flake = builtins.getFlake %s; configuration = \
       flake.nixosConfigurations.%s; in configuration.pkgs.closureInfo { \
       rootPaths = [ (builtins.storePath %s) ]; }"
      (nix_string flake)
      (nix_string target.host_name)
      (nix_string toplevel)
  in
  let output = build_expr_path ~label:"Nix store registration closure" expr in
  let registration = Filename.concat output "registration" in
  if not (Sys.file_exists registration) then
    Log.fatal
      "failed to resolve Nix store registration file\n\n\
       Closure info output: %s\n\
       Expected registration file: %s"
      output registration;
  registration

let normalize_flake_path path = Util.expand_home path

let local_flake_prefix base =
  [ "path:"; "git+file:"; "file:" ]
  |> List.find_opt (fun prefix -> String.starts_with ~prefix base)

let is_path_flake_ref base =
  base <> ""
  && (base.[0] = '/'
     || base.[0] = '~'
     || base.[0] = '.'
     || Option.is_some (local_flake_prefix base))

let resolved_flake_path path =
  let path = Util.expand_home path in
  try Unix.realpath path
  with Unix.Unix_error _ | Sys_error _ -> Util.absolute_path path

let absolute_flake_path base =
  match local_flake_prefix base with
  | Some prefix ->
      let path =
        String.sub base (String.length prefix)
          (String.length base - String.length prefix)
      in
      prefix ^ resolved_flake_path path
  | None -> resolved_flake_path base

let storage_flake_ref value =
  let base, fragment = split_flake_ref value in
  let base =
    if is_path_flake_ref base then absolute_flake_path base else base
  in
  match fragment with None -> base | Some fragment -> base ^ "#" ^ fragment

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

let rec resolve_ssh_user ~target =
  let attr = target.attr ^ ".config.services.getty.autologinUser" in
  let user = eval_raw ~label:"guest SSH user" attr in
  if user = "" then
    Log.fatal "guest SSH user resolved to an empty value\n\nNix attr: %s" attr;
  validate_user ~target ~user;
  user

and validate_user ~target ~user =
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
  let registration = resolve_registration ~target ~toplevel in
  let openssh = eval_raw ~label:"OpenSSH package" (attr ^ ".pkgs.openssh") in
  let systemd =
    eval_raw ~label:"systemd package" (attr ^ ".config.systemd.package")
  in
  let kernel_params =
    eval_json ~label:"kernel parameters" (attr ^ ".config.boot.kernelParams")
    |> parse_json_string_array
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
    registration;
    ssh = Filename.concat openssh "bin/ssh";
    systemd_ssh_proxy = Filename.concat systemd "lib/systemd/systemd-ssh-proxy";
  }
