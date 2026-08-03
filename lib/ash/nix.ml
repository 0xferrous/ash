type target = { attr : string; host_name : string }

type boot = {
  kernel : string;
  initrd : string;
  kernel_params : string list;
  toplevel : string;
  registration : string;
  registration_sha256 : string;
  closure_nar_size_bytes : int64;
  closure_path_count : int;
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

let image_store_cache_key ~toplevel =
  Printf.sprintf "base-image-v3\n%s\n" toplevel
  |> Digest.string |> Digest.to_hex

let image_store_size_mib metadata =
  Int64.(to_int (div metadata.Image_metadata.virtual_size_bytes 1048576L))

let image_store_metadata ?registration_sha256 ?closure_nar_size_bytes
    ?closure_path_count ?origin ?cache_key ?configured_size_mib
    ?initialized_from_cache_key ~kind ~toplevel ~registration ~size_mib () =
  let now = Image_metadata.timestamp () in
  {
    Image_metadata.kind;
    image_format = Image_metadata.current_image_format;
    cache_key;
    toplevel;
    registration;
    registration_sha256;
    created_at = now;
    last_used_at = now;
    updated_at =
      (match kind with
      | Image_metadata.Cache -> None
      | Image_metadata.Vm -> Some now);
    virtual_size_bytes = Int64.mul (Int64.of_int size_mib) 1048576L;
    closure_nar_size_bytes;
    closure_path_count;
    configured_size_mib;
    initialized_from_cache_key;
    origins = Option.to_list origin;
  }

let refresh_image_store_metadata ?registration_sha256 ?closure_nar_size_bytes
    ?closure_path_count ?origin metadata ~toplevel ~registration ~size_mib =
  let now = Image_metadata.timestamp () in
  let same_closure = metadata.Image_metadata.toplevel = toplevel in
  {
    metadata with
    toplevel;
    registration;
    registration_sha256 =
      (match registration_sha256 with
      | Some _ as value -> value
      | None when same_closure -> metadata.registration_sha256
      | None -> None);
    last_used_at = now;
    updated_at =
      (match metadata.kind with
      | Image_metadata.Cache -> None
      | Image_metadata.Vm -> Some now);
    virtual_size_bytes = Int64.mul (Int64.of_int size_mib) 1048576L;
    closure_nar_size_bytes =
      (match closure_nar_size_bytes with
      | Some _ as value -> value
      | None when same_closure -> metadata.closure_nar_size_bytes
      | None -> None);
    closure_path_count =
      (match closure_path_count with
      | Some _ as value -> value
      | None when same_closure -> metadata.closure_path_count
      | None -> None);
    configured_size_mib =
      (match metadata.kind with
      | Image_metadata.Cache -> None
      | Image_metadata.Vm -> Some size_mib);
    origins =
      (match origin with
      | None -> if same_closure then metadata.origins else []
      | Some origin ->
          if same_closure then
            Image_metadata.merge_origin metadata.origins origin
          else [ origin ]);
  }

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

let write_image_store ~image ~bytes ~entries ~metrics ~metadata =
  let temporary_image = Printf.sprintf "%s.tmp-%d" image (Unix.getpid ()) in
  Util.ensure_dir (Filename.dirname image);
  (try Unix.unlink temporary_image with Unix.Unix_error _ -> ());
  try
    Image_import_core.Import.write_image ~size:bytes ~label:"nix-store"
      ~reporter:image_import_reporter ~path:temporary_image ~metrics entries;
    Image_import_core.Metrics.log ~prefix:"ash image store"
      ~reporter:image_import_reporter metrics;
    Unix.rename temporary_image image;
    Image_metadata.write image metadata;
    try Unix.unlink (Image_metadata.legacy_path image)
    with Unix.Unix_error (Unix.ENOENT, _, _) -> ()
  with exn ->
    (try Unix.unlink temporary_image with Unix.Unix_error _ -> ());
    raise exn

let create_image_store ?nix_executable ?store_paths ~toplevel ~registration
    ~image ~bytes ~metadata () =
  let entries, metrics =
    scan_image_store ?nix_executable ?store_paths ~toplevel ~registration ()
  in
  write_image_store ~image ~bytes ~entries ~metrics ~metadata

let bytes_of_mib size_mib = Int64.mul (Int64.of_int size_mib) 1048576L
let mib_of_bytes bytes = Int64.(to_int (div (add bytes 1048575L) 1048576L))

let current_cached_image ~cache_key ~toplevel ~registration ~image =
  if not (Sys.file_exists image) then None
  else
    match Image_metadata.read image with
    | Image_metadata.Current prepared
      when prepared.kind = Image_metadata.Cache
           && prepared.cache_key = Some cache_key
           && prepared.toplevel = toplevel
           && prepared.registration = registration
           && Int64.equal (Unix.LargeFile.stat image).st_size
                prepared.virtual_size_bytes ->
        Some prepared
    | Image_metadata.Current _ | Image_metadata.Legacy | Image_metadata.Invalid
    | Image_metadata.Missing ->
        None

let prepare_cached_image ?nix_executable ?store_paths ?registration_sha256
    ?closure_nar_size_bytes ?closure_path_count ?origin ~cache_key ~toplevel
    ~registration ~image () =
  match current_cached_image ~cache_key ~toplevel ~registration ~image with
  | Some prepared ->
      let size_mib = image_store_size_mib prepared in
      let prepared =
        refresh_image_store_metadata ?registration_sha256
          ?closure_nar_size_bytes ?closure_path_count ?origin prepared ~toplevel
          ~registration ~size_mib
      in
      Image_metadata.write image prepared;
      Log.debug "reusing cached %d MiB image-backed Nix store at %s" size_mib
        image;
      size_mib
  | None ->
      (try Unix.unlink image with Unix.Unix_error _ -> ());
      Image_metadata.remove image;
      let entries, metrics =
        scan_image_store ?nix_executable ?store_paths ~toplevel ~registration ()
      in
      let bytes = Image_import_core.Import.estimate_image_size entries in
      let size_mib = mib_of_bytes bytes in
      let metadata =
        image_store_metadata ?registration_sha256 ?closure_nar_size_bytes
          ?closure_path_count ?origin ~cache_key ~kind:Image_metadata.Cache
          ~toplevel ~registration ~size_mib ()
      in
      Log.info "building cached %d MiB image-backed Nix store at %s" size_mib
        image;
      write_image_store ~image ~bytes ~entries ~metrics ~metadata;
      Unix.chmod image 0o444;
      Log.info "cached %d MiB image-backed Nix store at %s" size_mib image;
      size_mib

let clone_cached_image ?copy_executable ?resize2fs ?registration_sha256
    ?closure_nar_size_bytes ?closure_path_count ?origin ~cache_key ~cache_image
    ~cache_size_mib ~toplevel ~registration ~image ~size_mib () =
  if cache_size_mib > size_mib then
    Log.fatal
      "configured Nix store image size is too small for this closure\n\n\
       Increase image_size_mib to at least %d."
      cache_size_mib;
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
    image_store_metadata ?registration_sha256 ?closure_nar_size_bytes
      ?closure_path_count ?origin ~configured_size_mib:size_mib
      ~initialized_from_cache_key:cache_key ~kind:Image_metadata.Vm ~toplevel
      ~registration ~size_mib ()
    |> Image_metadata.write image;
    (try Unix.unlink (Image_metadata.legacy_path image)
     with Unix.Unix_error (Unix.ENOENT, _, _) -> ());
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
    ~image ~metadata () =
  let entries, metrics =
    scan_image_store ?nix_executable ?store_paths ~toplevel ~registration ()
  in
  Image_import_core.Import.append_image ~reporter:image_import_reporter
    ~path:image ~metrics entries;
  Image_import_core.Metrics.log ~prefix:"ash image store update"
    ~reporter:image_import_reporter metrics;
  Image_metadata.write image metadata

let prepare_image_store ?nix_executable ?store_paths ?e2fsck ?resize2fs
    ?copy_executable ?cache_image ?registration_sha256 ?closure_nar_size_bytes
    ?closure_path_count ?origin ?(resize_allowed = true) ~toplevel ~registration
    ~image ~size_mib () =
  let bytes = bytes_of_mib size_mib in
  if Sys.file_exists image then
    match Image_metadata.read image with
    | Image_metadata.Legacy ->
        Log.fatal
          "Nix store image %s uses legacy .toplevel metadata\n\n\
           Run `ash rebuild-db` for this VM to recreate it with the current \
           image format."
          image
    | Image_metadata.Current prepared
      when prepared.kind = Image_metadata.Vm
           && prepared.toplevel = toplevel
           && prepared.registration = registration
           && image_store_size_mib prepared = size_mib ->
        if not (Int64.equal (Unix.LargeFile.stat image).st_size bytes) then
          Log.fatal
            "Nix store image %s has an unexpected backing-file size\n\n\
             Run `ash rebuild-db` for this VM to recreate the image."
            image;
        refresh_image_store_metadata ?registration_sha256
          ?closure_nar_size_bytes ?closure_path_count ?origin prepared ~toplevel
          ~registration ~size_mib
        |> Image_metadata.write image;
        Log.debug
          "image-backed Nix store already has the requested size: %d MiB at %s"
          size_mib image
    | Image_metadata.Current prepared
      when prepared.kind = Image_metadata.Vm
           && prepared.toplevel = toplevel
           && prepared.registration = registration
           && image_store_size_mib prepared < size_mib ->
        if not resize_allowed then
          Log.fatal "VM is running; stop it before growing its Nix store image";
        let prepared_size_mib = image_store_size_mib prepared in
        if
          not
            (Int64.equal (Unix.LargeFile.stat image).st_size
               prepared.virtual_size_bytes)
        then
          Log.fatal
            "Nix store image %s has an unexpected backing-file size\n\n\
             Run `ash rebuild-db` for this VM to recreate the image."
            image;
        check_existing_image ?e2fsck image;
        grow_existing_image ?resize2fs ~image ~from_size_mib:prepared_size_mib
          ~size_mib ();
        refresh_image_store_metadata ?registration_sha256
          ?closure_nar_size_bytes ?closure_path_count ?origin prepared ~toplevel
          ~registration ~size_mib
        |> Image_metadata.write image;
        Log.info "grew image-backed Nix store to %d MiB at %s" size_mib image
    | Image_metadata.Current prepared
      when prepared.kind = Image_metadata.Vm
           && prepared.toplevel = toplevel
           && prepared.registration = registration
           && image_store_size_mib prepared > size_mib ->
        Log.fatal
          "shrinking the Nix store image is not supported\n\n\
           Increase global.nix_store.image_size_mib to at least %d, or run \
           `ash rebuild-db` to recreate the image at the smaller size."
          (image_store_size_mib prepared)
    | Image_metadata.Current prepared when prepared.kind = Image_metadata.Vm
      -> (
        if not resize_allowed then
          Log.fatal
            "VM is running; stop it before updating its image-backed Nix store";
        let prepared_size_mib = image_store_size_mib prepared in
        if prepared_size_mib > size_mib then
          Log.fatal
            "shrinking the Nix store image is not supported\n\n\
             Increase global.nix_store.image_size_mib to at least %d."
            prepared_size_mib;
        if
          not
            (Int64.equal (Unix.LargeFile.stat image).st_size
               prepared.virtual_size_bytes)
        then
          Log.fatal
            "Nix store image %s has an unexpected backing-file size\n\n\
             Run `ash rebuild-db` for this VM to recreate the image."
            image;
        check_existing_image ?e2fsck image;
        grow_existing_image ?resize2fs ~image ~from_size_mib:prepared_size_mib
          ~size_mib ();
        let metadata =
          refresh_image_store_metadata ?registration_sha256
            ?closure_nar_size_bytes ?closure_path_count ?origin prepared
            ~toplevel ~registration ~size_mib
        in
        try
          append_image_store ?nix_executable ?store_paths ~toplevel
            ~registration ~image ~metadata ();
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
    | Image_metadata.Current _ | Image_metadata.Invalid | Image_metadata.Missing
      ->
        Log.fatal
          "Nix store image %s has no valid TOML metadata sidecar\n\n\
           Run `ash rebuild-db` for this VM to recreate the image."
          image
  else
    try
      match cache_image with
      | None ->
          let metadata =
            image_store_metadata ?registration_sha256 ?closure_nar_size_bytes
              ?closure_path_count ?origin ~configured_size_mib:size_mib
              ~kind:Image_metadata.Vm ~toplevel ~registration ~size_mib ()
          in
          create_image_store ?nix_executable ?store_paths ~toplevel
            ~registration ~image ~bytes ~metadata ();
          Log.info "created %d MiB image-backed Nix store at %s" size_mib image
      | Some cache_image ->
          let cache_key = image_store_cache_key ~toplevel in
          let cache_size_mib =
            prepare_cached_image ?nix_executable ?store_paths
              ?registration_sha256 ?closure_nar_size_bytes ?closure_path_count
              ?origin ~cache_key ~toplevel ~registration ~image:cache_image ()
          in
          clone_cached_image ?copy_executable ?resize2fs ?registration_sha256
            ?closure_nar_size_bytes ?closure_path_count ?origin ~cache_key
            ~cache_image ~cache_size_mib ~toplevel ~registration ~image
            ~size_mib ()
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

let add_registration_to_store ~nix ~nix_store ~out_link content =
  let temporary_dir = Filename.temp_file "ash-registration" "" in
  Sys.remove temporary_dir;
  Unix.mkdir temporary_dir 0o700;
  Fun.protect
    ~finally:(fun () -> Util.remove_tree ~force:true temporary_dir)
    (fun () ->
      let source = Filename.concat temporary_dir "registration" in
      Util.write_file source content;
      let registration_sha256 =
        Util.command_output
          (String.concat " "
             [
               Util.shell_quote nix;
               "hash";
               "file";
               "--type";
               "sha256";
               "--sri";
               Util.shell_quote source;
             ])
      in
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
      (registration, registration_sha256))

let resolve_registration ~nix ~nix_store ~toplevel ~out_link =
  let infos = query_closure_info ~nix ~toplevel in
  let content = registration_content infos in
  let registration, registration_sha256 =
    add_registration_to_store ~nix ~nix_store ~out_link content
  in
  let closure_nar_size_bytes =
    List.fold_left (fun total info -> Int64.add total info.nar_size) 0L infos
  in
  (registration, registration_sha256, closure_nar_size_bytes, List.length infos)

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

let rec canonical_json = function
  | `Assoc fields ->
      `Assoc
        (fields
        |> List.map (fun (name, value) -> (name, canonical_json value))
        |> List.sort (fun (left, _) (right, _) -> String.compare left right))
  | `List values -> `List (List.map canonical_json values)
  | value -> value

let sha256_text ~nix text =
  let path = Filename.temp_file "ash-hash" ".txt" in
  Fun.protect
    ~finally:(fun () -> try Unix.unlink path with Unix.Unix_error _ -> ())
    (fun () ->
      Util.write_file path text;
      Util.command_output
        (String.concat " "
           [
             Util.shell_quote nix;
             "hash";
             "file";
             "--type";
             "sha256";
             "--sri";
             Util.shell_quote path;
           ]))

let sanitize_flake_url value =
  match String.index_opt value ':' with
  | Some colon
    when colon + 2 < String.length value && String.sub value colon 3 = "://"
    -> (
      let authority_start = colon + 3 in
      let authority_end =
        let rec find index =
          if index >= String.length value then String.length value
          else
            match value.[index] with
            | '/' | '?' | '#' -> index
            | _ -> find (index + 1)
        in
        find authority_start
      in
      let authority =
        String.sub value authority_start (authority_end - authority_start)
      in
      match String.rindex_opt authority '@' with
      | None -> value
      | Some at ->
          String.sub value 0 authority_start
          ^ String.sub authority (at + 1) (String.length authority - at - 1)
          ^ String.sub value authority_end (String.length value - authority_end)
      )
  | _ -> value

let effective_override_inputs override_inputs =
  List.fold_left
    (fun effective (name, flake) ->
      (name, flake) :: List.remove_assoc name effective)
    [] override_inputs
  |> List.rev

let resolve_image_origin ~nix ~override_inputs ~target =
  let flake_url, _ = split_flake_ref target.attr in
  let command =
    String.concat " "
      ([ Util.shell_quote nix; "flake"; "metadata" ]
      @ (override_inputs
        |> List.concat_map (fun (name, flake) ->
            [
              "--override-input"; Util.shell_quote name; Util.shell_quote flake;
            ]))
      @ [ "--no-write-lock-file"; "--json"; Util.shell_quote flake_url ])
  in
  let metadata = Util.command_output command |> Yojson.Safe.from_string in
  let locks =
    match metadata with
    | `Assoc fields ->
        Option.value (List.assoc_opt "locks" fields) ~default:`Null
    | _ -> `Null
  in
  let lock_hash =
    canonical_json locks |> Yojson.Safe.to_string |> sha256_text ~nix
  in
  let now = Image_metadata.timestamp () in
  {
    Image_metadata.flake_url = storage_flake_ref flake_url |> sanitize_flake_url;
    nixos_configuration = target.host_name;
    lock_hash;
    override_inputs =
      effective_override_inputs override_inputs
      |> List.map (fun (name, flake) ->
          (name, storage_flake_ref flake |> sanitize_flake_url));
    first_seen_at = now;
    last_seen_at = now;
  }

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
  let ( registration,
        registration_sha256,
        closure_nar_size_bytes,
        closure_path_count ) =
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
    registration_sha256;
    closure_nar_size_bytes;
    closure_path_count;
    nix;
    nix_store;
    ssh = Filename.concat openssh "bin/ssh";
    systemd_ssh_proxy = Filename.concat systemd "lib/systemd/systemd-ssh-proxy";
  }
