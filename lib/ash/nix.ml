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

let image_store_cache_key ~toplevel ~registration =
  Printf.sprintf "base-image-v1\n%s\n%s\n" toplevel registration
  |> Digest.string |> Digest.to_hex

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

let rec containing_store_path path =
  let parent = Filename.dirname path in
  if parent = "/nix/store" then path
  else if parent = path || String.length parent < String.length "/nix/store"
  then invalid_arg (Printf.sprintf "path is not inside /nix/store: %s" path)
  else containing_store_path parent

let scan_image_store ?nix_executable ?store_paths ~toplevel ~registration () =
  let store_paths =
    match store_paths with
    | Some paths -> paths
    | None ->
        resolve_store_paths ?nix_executable
          [ toplevel; containing_store_path registration ]
  in
  let metrics = Image_import_core.Metrics.create () in
  let entries =
    Image_import_core.Scan.scan_closure ~reporter:image_import_reporter ~jobs:1
      ~closure_paths:store_paths ~target_root:"/store" ~total_bytes:None metrics
  in
  (entries, metrics)

let write_image_store ~toplevel ~registration ~image ~size_mib ~bytes ~entries
    ~metrics =
  let marker = image ^ ".toplevel" in
  let temporary_image = Printf.sprintf "%s.tmp-%d" image (Unix.getpid ()) in
  Util.ensure_dir (Filename.dirname image);
  (try Unix.unlink temporary_image with Unix.Unix_error _ -> ());
  try
    Image_import_core.Import.write_image ~size:bytes ~label:"nix-store"
      ~reporter:image_import_reporter ~path:temporary_image ~metrics entries;
    Image_import_core.Metrics.log ~prefix:"ash image store"
      ~reporter:image_import_reporter metrics;
    Unix.rename temporary_image image;
    Util.atomic_write_file marker
      (image_store_marker_content ~toplevel ~size_mib ~registration)
  with exn ->
    (try Unix.unlink temporary_image with Unix.Unix_error _ -> ());
    raise exn

let create_image_store ?nix_executable ?store_paths ~toplevel ~registration
    ~image ~size_mib ~bytes () =
  let entries, metrics =
    scan_image_store ?nix_executable ?store_paths ~toplevel ~registration ()
  in
  write_image_store ~toplevel ~registration ~image ~size_mib ~bytes ~entries
    ~metrics

let bytes_of_mib size_mib = Int64.mul (Int64.of_int size_mib) 1048576L
let mib_of_bytes bytes = Int64.(to_int (div (add bytes 1048575L) 1048576L))

let current_cached_image ~toplevel ~registration ~image =
  let marker = image ^ ".toplevel" in
  if not (Sys.file_exists image) then None
  else
    match
      if Sys.file_exists marker then read_image_store_marker marker else None
    with
    | Some (Current prepared)
      when prepared.toplevel = toplevel
           && prepared.registration = registration
           && Int64.equal (Unix.LargeFile.stat image).st_size
                (bytes_of_mib prepared.size_mib) ->
        Some prepared.size_mib
    | Some (Current _) | Some Legacy | None -> None

let prepare_cached_image ?nix_executable ?store_paths ~toplevel ~registration
    ~image () =
  match current_cached_image ~toplevel ~registration ~image with
  | Some size_mib ->
      Log.debug "reusing cached %d MiB image-backed Nix store at %s" size_mib
        image;
      size_mib
  | None ->
      (try Unix.unlink image with Unix.Unix_error _ -> ());
      (try Unix.unlink (image ^ ".toplevel") with Unix.Unix_error _ -> ());
      let entries, metrics =
        scan_image_store ?nix_executable ?store_paths ~toplevel ~registration ()
      in
      let bytes = Image_import_core.Import.estimate_image_size entries in
      let size_mib = mib_of_bytes bytes in
      Log.info "building cached %d MiB image-backed Nix store at %s" size_mib
        image;
      write_image_store ~toplevel ~registration ~image ~size_mib ~bytes ~entries
        ~metrics;
      Unix.chmod image 0o444;
      Log.info "cached %d MiB image-backed Nix store at %s" size_mib image;
      size_mib

let clone_cached_image ?copy_executable ?resize2fs ~cache_image ~cache_size_mib
    ~toplevel ~registration ~image ~size_mib () =
  if cache_size_mib > size_mib then
    Log.fatal
      "configured Nix store image size is too small for this closure\n\n\
       Increase image_size_mib to at least %d."
      cache_size_mib;
  let marker = image ^ ".toplevel" in
  let temporary_image = Printf.sprintf "%s.tmp-%d" image (Unix.getpid ()) in
  Util.ensure_dir (Filename.dirname image);
  (try Unix.unlink temporary_image with Unix.Unix_error _ -> ());
  try
    Util.clone_file ?copy_executable ~src:cache_image ~dst:temporary_image ();
    Unix.chmod temporary_image 0o600;
    if cache_size_mib < size_mib then (
      let resize2fs =
        Util.get_exe
          ~hint:"resize2fs is required to grow a cached Nix store image clone."
          resize2fs "resize2fs"
      in
      Unix.LargeFile.truncate temporary_image (bytes_of_mib size_mib);
      let code = Util.run_foreground resize2fs [ temporary_image ] in
      if code <> 0 then
        failwith
          (Printf.sprintf "failed to grow cached Nix store image clone %s"
             temporary_image));
    Unix.rename temporary_image image;
    Util.atomic_write_file marker
      (image_store_marker_content ~toplevel ~size_mib ~registration);
    Log.info "cloned cached image-backed Nix store into VM state at %s" image
  with exn ->
    (try Unix.unlink temporary_image with Unix.Unix_error _ -> ());
    raise exn

let check_existing_image ?e2fsck image =
  let e2fsck =
    Util.get_exe
      ~hint:
        "e2fsck is required before modifying an existing image-backed Nix \
         store."
      e2fsck "e2fsck"
  in
  let code = Util.run_foreground e2fsck [ "-f"; "-p"; image ] in
  if code <> 0 && code <> 1 then
    Log.fatal "failed to check Nix store image %s with e2fsck" image

let grow_existing_image ?resize2fs ~image ~from_size_mib ~size_mib () =
  if from_size_mib < size_mib then (
    let resize2fs =
      Util.get_exe
        ~hint:"resize2fs is required to grow an image-backed Nix store."
        resize2fs "resize2fs"
    in
    Log.info "growing image-backed Nix store from %d MiB to %d MiB at %s"
      from_size_mib size_mib image;
    Unix.LargeFile.truncate image (bytes_of_mib size_mib);
    let code = Util.run_foreground resize2fs [ image ] in
    if code <> 0 then
      Log.fatal "failed to grow Nix store image %s with resize2fs" image)

let append_image_store ?nix_executable ?store_paths ~toplevel ~registration
    ~image ~size_mib () =
  let entries, metrics =
    scan_image_store ?nix_executable ?store_paths ~toplevel ~registration ()
  in
  Image_import_core.Import.append_image ~reporter:image_import_reporter
    ~path:image ~metrics entries;
  Image_import_core.Metrics.log ~prefix:"ash image store update"
    ~reporter:image_import_reporter metrics;
  Util.atomic_write_file (image ^ ".toplevel")
    (image_store_marker_content ~toplevel ~size_mib ~registration)

let prepare_image_store ?nix_executable ?store_paths ?e2fsck ?resize2fs
    ?copy_executable ?cache_image ?(resize_allowed = true) ~toplevel
    ~registration ~image ~size_mib () =
  let marker = image ^ ".toplevel" in
  let bytes = bytes_of_mib size_mib in
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
        if not resize_allowed then
          Log.fatal "VM is running; stop it before growing its Nix store image";
        if
          not
            (Int64.equal (Unix.LargeFile.stat image).st_size
               (bytes_of_mib prepared.size_mib))
        then
          Log.fatal
            "Nix store image %s has an unexpected backing-file size\n\n\
             Run `ash rebuild-db` for this VM to recreate the image."
            image;
        check_existing_image ?e2fsck image;
        grow_existing_image ?resize2fs ~image ~from_size_mib:prepared.size_mib
          ~size_mib ();
        Util.atomic_write_file marker
          (image_store_marker_content ~toplevel ~size_mib ~registration);
        Log.info "grew image-backed Nix store to %d MiB at %s" size_mib image
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
    | Some (Current prepared) -> (
        if not resize_allowed then
          Log.fatal
            "VM is running; stop it before updating its image-backed Nix store";
        if prepared.size_mib > size_mib then
          Log.fatal
            "shrinking the Nix store image is not supported\n\n\
             Increase global.nix_store.image_size_mib to at least %d."
            prepared.size_mib;
        if
          not
            (Int64.equal (Unix.LargeFile.stat image).st_size
               (bytes_of_mib prepared.size_mib))
        then
          Log.fatal
            "Nix store image %s has an unexpected backing-file size\n\n\
             Run `ash rebuild-db` for this VM to recreate the image."
            image;
        check_existing_image ?e2fsck image;
        grow_existing_image ?resize2fs ~image ~from_size_mib:prepared.size_mib
          ~size_mib ();
        try
          append_image_store ?nix_executable ?store_paths ~toplevel
            ~registration ~image ~size_mib ();
          Log.info
            "updated image-backed Nix store from %s to %s while retaining \
             existing store paths"
            prepared.toplevel toplevel
        with exn ->
          Log.fatal
            "failed to update image-backed Nix store %s: %s\n\n\
             Increase image_size_mib and retry; already imported immutable \
             store paths will be reused."
            image (Printexc.to_string exn))
    | None ->
        Log.fatal
          "Nix store image %s has no valid closure marker\n\n\
           Run `ash rebuild-db` for this VM to recreate the image."
          image
  else
    try
      match cache_image with
      | None ->
          create_image_store ?nix_executable ?store_paths ~toplevel
            ~registration ~image ~size_mib ~bytes ();
          Log.info "created %d MiB image-backed Nix store at %s" size_mib image
      | Some cache_image ->
          let cache_size_mib =
            prepare_cached_image ?nix_executable ?store_paths ~toplevel
              ~registration ~image:cache_image ()
          in
          clone_cached_image ?copy_executable ?resize2fs ~cache_image
            ~cache_size_mib ~toplevel ~registration ~image ~size_mib ()
    with exn ->
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

let split_flake_ref value =
  match String.index_opt value '#' with
  | None -> (value, None)
  | Some idx ->
      let base = String.sub value 0 idx in
      let fragment =
        String.sub value (idx + 1) (String.length value - idx - 1)
      in
      (base, Some fragment)

type closure_path_info = {
  path : string;
  nar_hash : string;
  nar_size : int64;
  references : string list;
}

let json_int64 = function
  | `Int value -> Some (Int64.of_int value)
  | `Intlit value -> Int64.of_string_opt value
  | _ -> None

let closure_path_info path = function
  | `Assoc fields ->
      let field name = List.assoc_opt name fields in
      let nar_hash =
        match field "narHash" with
        | Some (`String value) -> value
        | _ -> failwith (Printf.sprintf "missing narHash for %s" path)
      in
      let nar_size =
        match Option.bind (field "narSize") json_int64 with
        | Some value -> value
        | None -> failwith (Printf.sprintf "missing narSize for %s" path)
      in
      let references =
        match field "references" with
        | Some (`List values) ->
            List.map
              (function
                | `String value -> value
                | _ ->
                    failwith
                      (Printf.sprintf "invalid reference entry for %s" path))
              values
        | _ -> failwith (Printf.sprintf "missing references for %s" path)
      in
      { path; nar_hash; nar_size; references }
  | _ -> failwith (Printf.sprintf "invalid path-info record for %s" path)

let closure_path_infos text =
  match Yojson.Safe.from_string text with
  | `Assoc paths ->
      paths
      |> List.map (fun (path, info) -> closure_path_info path info)
      |> List.sort (fun left right -> String.compare left.path right.path)
  | _ -> failwith "nix path-info returned a non-object JSON value"

let registration_path_infos text =
  let rec take_references count acc lines =
    if count = 0 then (List.rev acc, lines)
    else
      match lines with
      | reference :: rest -> take_references (count - 1) (reference :: acc) rest
      | [] -> failwith "truncated Nix registration references"
  in
  let rec parse acc = function
    | [] | [ "" ] -> List.rev acc
    | path :: nar_hash :: nar_size :: _deriver :: reference_count :: rest ->
        let nar_size =
          match Int64.of_string_opt nar_size with
          | Some value -> value
          | None -> failwith (Printf.sprintf "invalid narSize for %s" path)
        in
        let reference_count =
          match int_of_string_opt reference_count with
          | Some value when value >= 0 -> value
          | _ -> failwith (Printf.sprintf "invalid reference count for %s" path)
        in
        let references, rest = take_references reference_count [] rest in
        parse ({ path; nar_hash; nar_size; references } :: acc) rest
    | _ -> failwith "truncated Nix registration record"
  in
  String.split_on_char '\n' text
  |> parse []
  |> List.sort (fun left right -> String.compare left.path right.path)

let registration_content infos =
  let buffer = Buffer.create (List.length infos * 256) in
  List.iter
    (fun info ->
      let references = List.sort String.compare info.references in
      List.iter
        (fun value ->
          Buffer.add_string buffer value;
          Buffer.add_char buffer '\n')
        ([
           info.path;
           info.nar_hash;
           Int64.to_string info.nar_size;
           "";
           string_of_int (List.length references);
         ]
        @ references))
    infos;
  Buffer.contents buffer

let query_closure_info ~nix ~toplevel =
  let command json_format =
    String.concat " "
      ([ Util.shell_quote nix; "path-info" ]
      @ json_format
      @ [ "--json"; "--recursive"; Util.shell_quote toplevel ])
  in
  let command =
    Printf.sprintf "%s 2>/dev/null || %s"
      (command [ "--json-format"; "1" ])
      (command [])
  in
  try Util.command_output command |> closure_path_infos
  with Failure message | Yojson.Json_error message ->
    Log.fatal
      "failed to query native Nix closure information\n\n\
       Toplevel: %s\n\
       Error: %s"
      toplevel message

let add_registration_to_store ~nix_store ~out_link content =
  let temporary_dir = Filename.temp_file "ash-registration" "" in
  Sys.remove temporary_dir;
  Unix.mkdir temporary_dir 0o700;
  Fun.protect
    ~finally:(fun () -> Util.remove_tree ~force:true temporary_dir)
    (fun () ->
      let source = Filename.concat temporary_dir "registration" in
      Util.write_file source content;
      let registration =
        Util.command_output
          (String.concat " "
             [
               Util.shell_quote nix_store;
               "--add-fixed";
               "sha256";
               Util.shell_quote source;
             ])
      in
      Util.ensure_dir (Filename.dirname out_link);
      (try Unix.unlink out_link with Unix.Unix_error (Unix.ENOENT, _, _) -> ());
      ignore
        (Util.command_output
           (String.concat " "
              [
                Util.shell_quote nix_store;
                "--realise";
                Util.shell_quote registration;
                "--add-root";
                Util.shell_quote out_link;
                "--indirect";
              ]));
      if not (Sys.file_exists registration) then
        Log.fatal "native Nix registration was not added to the store: %s"
          registration;
      registration)

let resolve_registration ~nix ~nix_store ~toplevel ~out_link =
  let infos = query_closure_info ~nix ~toplevel in
  let content = registration_content infos in
  add_registration_to_store ~nix_store ~out_link content

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
  let nix_package =
    eval_raw ~override_inputs ~label:"Nix package" (attr ^ ".config.nix.package")
  in
  let nix = Filename.concat nix_package "bin/nix" in
  let nix_store = Filename.concat nix_package "bin/nix-store" in
  let registration =
    resolve_registration ~nix ~nix_store ~toplevel
      ~out_link:(root "registration")
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
    nix;
    nix_store;
    ssh = Filename.concat openssh "bin/ssh";
    systemd_ssh_proxy = Filename.concat systemd "lib/systemd/systemd-ssh-proxy";
  }
