type target = { attr : string; host_name : string }

type boot = {
  kernel : string;
  initrd : string;
  kernel_params : string list;
  registration : string;
  nix_store : string;
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

let override_input_args override_inputs =
  override_inputs
  |> List.concat_map (fun (name, flake) ->
      [ "--override-input"; Util.shell_quote name; Util.shell_quote flake ])
  |> String.concat " "

let subcommand_args command override_inputs args =
  String.concat " "
    (List.filter (( <> ) "")
       [ command; override_input_args override_inputs; args ])

let uri_encode value =
  let is_unreserved = function
    | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '.' | '_' | '~' -> true
    | _ -> false
  in
  let buffer = Buffer.create (String.length value) in
  String.iter
    (fun char ->
      if is_unreserved char then Buffer.add_char buffer char
      else Buffer.add_string buffer (Printf.sprintf "%%%02X" (Char.code char)))
    value;
  Buffer.contents buffer

let local_store_uri ~real ~state =
  Printf.sprintf "local?real=%s&state=%s" (uri_encode real) (uri_encode state)

let prepare_lower_store ~nix_store ~registration ~state =
  let temporary = Printf.sprintf "%s.tmp-%d" state (Unix.getpid ()) in
  Util.remove_tree ~force:true temporary;
  Util.ensure_dir temporary;
  let store = local_store_uri ~real:"/nix/store" ~state:temporary in
  let command =
    Printf.sprintf "%s --store %s --load-db < %s"
      (Util.shell_quote nix_store)
      (Util.shell_quote store)
      (Util.shell_quote registration)
  in
  try
    ignore (Util.command_output command);
    Util.remove_tree ~force:true state;
    Unix.rename temporary state;
    Log.debug "prepared lower Nix store metadata in %s from %s" state
      registration
  with exn ->
    Util.remove_tree ~force:true temporary;
    Log.fatal "failed to prepare lower Nix store metadata in %s: %s" state
      (Printexc.to_string exn)

let run_nix ~label ~attr args =
  try Util.command_output (nix_command args)
  with Failure message ->
    Log.fatal "failed to resolve %s\n\nNix attr: %s\nError: %s" label attr
      message

let eval_raw ?(override_inputs = []) ~label attr =
  run_nix ~label ~attr
    (subcommand_args "eval" override_inputs ("--raw " ^ Util.shell_quote attr))

let eval_json ?(override_inputs = []) ~label attr =
  run_nix ~label ~attr
    (subcommand_args "eval" override_inputs ("--json " ^ Util.shell_quote attr))

let build_link_args = function
  | None -> "--no-link"
  | Some path -> "--out-link " ^ Util.shell_quote path

let build_path ?out_link ?(override_inputs = []) ~label attr =
  run_nix ~label ~attr
    (subcommand_args "build" override_inputs
       (build_link_args out_link ^ " --print-out-paths " ^ Util.shell_quote attr))

let build_expr_path ?out_link ?(override_inputs = []) ~label expr =
  run_nix ~label ~attr:expr
    (subcommand_args "build" override_inputs
       ("--impure " ^ build_link_args out_link ^ " --print-out-paths --expr "
      ^ Util.shell_quote expr))

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

let resolve_registration ~override_inputs ~target ~toplevel ~out_link =
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
  let output =
    build_expr_path ~out_link ~override_inputs
      ~label:"Nix store registration closure" expr
  in
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

let rec resolve_ssh_user ~override_inputs ~target =
  let attr = target.attr ^ ".config.services.getty.autologinUser" in
  let user = eval_raw ~override_inputs ~label:"guest SSH user" attr in
  if user = "" then
    Log.fatal "guest SSH user resolved to an empty value\n\nNix attr: %s" attr;
  validate_user ~override_inputs ~target ~user;
  user

and validate_user ~override_inputs ~target ~user =
  let attr =
    target.attr ^ ".config.users.users." ^ attr_segment user ^ ".name"
  in
  let resolved = eval_raw ~override_inputs ~label:("guest user " ^ user) attr in
  if resolved <> user then
    Log.fatal
      "guest user validation failed\n\n\
       Requested user: %s\n\
       NixOS user attr resolved to: %s"
      user resolved

let resolve_boot ~override_inputs ~target ~gcroots_dir =
  let attr = target.attr in
  let root name = Filename.concat gcroots_dir name in
  let kernel_dir =
    build_path ~out_link:(root "kernel") ~override_inputs
      ~label:"kernel build output"
      (attr ^ ".config.system.build.kernel")
  in
  let kernel_file =
    eval_raw ~override_inputs ~label:"kernel file name"
      (attr ^ ".config.system.boot.loader.kernelFile")
  in
  let initrd_output =
    build_path ~out_link:(root "initrd") ~override_inputs
      ~label:"initial ramdisk build output"
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
    build_path ~out_link:(root "toplevel") ~override_inputs
      ~label:"NixOS toplevel build output"
      (attr ^ ".config.system.build.toplevel")
  in
  let registration =
    resolve_registration ~override_inputs ~target ~toplevel
      ~out_link:(root "closure-info")
  in
  let nix =
    eval_raw ~override_inputs ~label:"Nix package" (attr ^ ".config.nix.package")
  in
  let openssh =
    eval_raw ~override_inputs ~label:"OpenSSH package" (attr ^ ".pkgs.openssh")
  in
  let systemd =
    eval_raw ~override_inputs ~label:"systemd package"
      (attr ^ ".config.systemd.package")
  in
  let kernel_params =
    eval_json ~override_inputs ~label:"kernel parameters"
      (attr ^ ".config.boot.kernelParams")
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
    nix_store = Filename.concat nix "bin/nix-store";
    ssh = Filename.concat openssh "bin/ssh";
    systemd_ssh_proxy = Filename.concat systemd "lib/systemd/systemd-ssh-proxy";
  }
