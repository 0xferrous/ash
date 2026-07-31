type target = { attr : string; host_name : string }

type boot = {
  kernel : string;
  initrd : string;
  kernel_params : string list;
  toplevel : string;
  registration : string;
  nix : string;
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

type image_store_marker =
  | Current of { toplevel : string; size_mib : int; registration : string }
  | Legacy

let image_store_marker_content ~toplevel ~size_mib ~registration =
  Printf.sprintf "4\n%s\n%d\n%s\n" toplevel size_mib registration

let read_image_store_marker path =
  match
    In_channel.with_open_text path In_channel.input_all
    |> String.split_on_char '\n'
  with
  | "4" :: toplevel :: size :: registration :: _ -> (
      match int_of_string_opt size with
      | Some size_mib -> Some (Current { toplevel; size_mib; registration })
      | None -> None)
  | _toplevel :: _size :: _ -> Some Legacy
  | _ -> None

let image_import_reporter =
  Image_import_core.Reporter.make
    ~debug:(fun message -> Log.debug "%s" message)
    ~info:(fun message -> Log.info "%s" message)

let resolve_store_paths ?nix_executable roots =
  let nix =
    Util.get_exe
      ~hint:"nix is required to resolve an image-backed Nix store closure."
      nix_executable "nix"
  in
  let command =
    String.concat " "
      (List.map Util.shell_quote (nix :: "path-info" :: "-r" :: roots))
  in
  Util.command_output command
  |> String.split_on_char '\n' |> List.map String.trim
  |> List.filter (( <> ) "")

let prepare_image_store ?nix_executable ?store_paths ?e2fsck ?resize2fs
    ?(resize_allowed = true) ~toplevel ~registration ~image ~size_mib () =
  let marker = image ^ ".toplevel" in
  let bytes = Int64.mul (Int64.of_int size_mib) 1048576L in
  if Sys.file_exists image then
    match
      if Sys.file_exists marker then read_image_store_marker marker else None
    with
    | Some Legacy ->
        Log.fatal
          "Nix store image %s uses a legacy filesystem layout or inode policy\n\n\
           Run `ash rebuild-db` for this VM to recreate it with the current \
           image layout."
          image
    | Some (Current prepared)
      when prepared.toplevel = toplevel
           && prepared.registration = registration
           && prepared.size_mib = size_mib ->
        if not (Int64.equal (Unix.LargeFile.stat image).st_size bytes) then
          Log.fatal
            "Nix store image %s has an unexpected backing-file size\n\n\
             Run `ash rebuild-db` for this VM to recreate the image."
            image;
        Log.debug
          "image-backed Nix store already has the requested size: %d MiB at %s"
          size_mib image
    | Some (Current prepared)
      when prepared.toplevel = toplevel
           && prepared.registration = registration
           && prepared.size_mib < size_mib ->
        let prepared_size = prepared.size_mib in
        if not resize_allowed then
          Log.fatal "VM is running; stop it before growing its Nix store image";
        let current_bytes = (Unix.LargeFile.stat image).st_size in
        if Int64.compare current_bytes bytes > 0 then
          Log.fatal
            "Nix store image %s is larger than its recorded size\n\n\
             Run `ash rebuild-db` for this VM to recreate the image."
            image;
        let e2fsck =
          Util.get_exe
            ~hint:
              "e2fsck is required to check an image-backed Nix store before \
               growing it."
            e2fsck "e2fsck"
        in
        let resize2fs =
          Util.get_exe
            ~hint:"resize2fs is required to grow an image-backed Nix store."
            resize2fs "resize2fs"
        in
        Log.info "growing image-backed Nix store from %d MiB to %d MiB at %s"
          prepared_size size_mib image;
        if Int64.compare current_bytes bytes < 0 then
          Unix.LargeFile.truncate image bytes;
        (* ext4 requires an offline forced check before resize2fs when the image
           has been mounted since its previous check. Exit 1 means e2fsck
           corrected errors and is safe to continue. *)
        let check_code = Util.run_foreground e2fsck [ "-f"; "-p"; image ] in
        if check_code <> 0 && check_code <> 1 then
          Log.fatal "failed to check Nix store image %s with e2fsck" image;
        let code = Util.run_foreground resize2fs [ image ] in
        if code <> 0 then
          Log.fatal "failed to grow Nix store image %s with resize2fs" image;
        Util.atomic_write_file marker
          (image_store_marker_content ~toplevel ~size_mib ~registration);
        Log.info "grew image-backed Nix store from %d MiB to %d MiB at %s"
          prepared_size size_mib image
    | Some (Current prepared)
      when prepared.toplevel = toplevel
           && prepared.registration = registration
           && prepared.size_mib > size_mib ->
        let prepared_size = prepared.size_mib in
        Log.fatal
          "shrinking the Nix store image is not supported\n\n\
           Increase global.nix_store.image_size_mib to at least %d, or run \
           `ash rebuild-db` to recreate the image at the smaller size."
          prepared_size
    | _ ->
        Log.fatal
          "Nix store image %s was prepared for a different system closure\n\n\
           Run `ash rebuild-db` for this VM to recreate the image."
          image
  else
    let temporary_image = Printf.sprintf "%s.tmp-%d" image (Unix.getpid ()) in
    (try Unix.unlink temporary_image with Unix.Unix_error _ -> ());
    try
      let store_paths =
        match store_paths with
        | Some paths -> paths
        | None ->
            resolve_store_paths ?nix_executable
              [ toplevel; Filename.dirname registration ]
      in
      let metrics = Image_import_core.Metrics.create () in
      let entries =
        Image_import_core.Scan.scan_closure ~reporter:image_import_reporter
          ~jobs:1 ~closure_paths:store_paths ~target_root:"/store"
          ~total_bytes:None metrics
      in
      Image_import_core.Import.write_image ~size:bytes ~label:"nix-store"
        ~reporter:image_import_reporter ~path:temporary_image ~metrics entries;
      Image_import_core.Metrics.log ~prefix:"ash image store"
        ~reporter:image_import_reporter metrics;
      Unix.rename temporary_image image;
      Util.atomic_write_file marker
        (image_store_marker_content ~toplevel ~size_mib ~registration);
      Log.info "created %d MiB image-backed Nix store at %s" size_mib image
    with exn ->
      (try Unix.unlink temporary_image with Unix.Unix_error _ -> ());
      Log.fatal "failed to prepare image-backed Nix store %s: %s" image
        (Printexc.to_string exn)

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
    toplevel;
    registration;
    nix = Filename.concat nix "bin/nix";
    nix_store = Filename.concat nix "bin/nix-store";
    ssh = Filename.concat openssh "bin/ssh";
    systemd_ssh_proxy = Filename.concat systemd "lib/systemd/systemd-ssh-proxy";
  }
