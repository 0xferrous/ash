type config = Otoml.t

type mount = {
  tag : string;
  source : string;
  target : string;
  read_only : bool;
}

type space_resources = { mounts : mount list }

let load path : config =
  let path = Util.expand_home path in
  if not (Sys.file_exists path) then
    Log.fatal "config not found: %s\n\nHint: pass --config PATH or create %s."
      path
      (Util.default_ash_config_path ());
  match Otoml.Parser.from_file_result path with
  | Ok table -> table
  | Error message -> Log.fatal "failed to parse config: %s\n\n%s" path message

let load_for_spaces path spaces =
  if spaces = [] then Otoml.table [] else load path

let strings path config =
  Otoml.find_opt config (Otoml.get_array Otoml.get_string) path

let space_exists config space = Otoml.path_exists config [ "spaces"; space ]

let path_tag space source target =
  let max_name_len = 20 in
  let hash_len = 12 in
  let trim_dashes value =
    let len = String.length value in
    let first = ref 0 in
    while !first < len && value.[!first] = '-' do
      incr first
    done;
    let last = ref (len - 1) in
    while !last >= !first && value.[!last] = '-' do
      decr last
    done;
    if !first > !last then "" else String.sub value !first (!last - !first + 1)
  in
  let name = Filename.basename source |> Util.slug |> trim_dashes in
  let name = if name = "" then "mnt" else name in
  let name = String.sub name 0 (min max_name_len (String.length name)) in
  let hash =
    Digest.string (space ^ "\000" ^ source ^ "\000" ^ target) |> Digest.to_hex
  in
  name ^ "-" ^ String.sub hash 0 hash_len

let guest_home user = if user = "root" then "/root" else "/home/" ^ user

let expand_home ~home path =
  if path = "~" then home
  else if String.starts_with ~prefix:"~/" path then
    Filename.concat home (String.sub path 2 (String.length path - 2))
  else path

let expand_guest_home ~guest_user path =
  expand_home ~home:(guest_home guest_user) path

let split_mount_spec spec =
  match String.index_opt spec ':' with
  | None -> (spec, spec)
  | Some index ->
      ( String.sub spec 0 index,
        String.sub spec (index + 1) (String.length spec - index - 1) )

let parse_mount_spec ~host_home ~guest_user ~space ~read_only spec =
  let host_path, guest_path = split_mount_spec spec in
  if host_path = "" then Error "host path is empty"
  else if guest_path = "" then Error "guest path is empty"
  else
    let source = expand_home ~home:host_home host_path in
    let target = expand_guest_home ~guest_user guest_path in
    if Filename.is_relative source then
      Error
        (Printf.sprintf "host path must be absolute or start with ~: %S"
           host_path)
    else if Filename.is_relative target then
      Error
        (Printf.sprintf "guest path must be absolute or start with ~: %S"
           guest_path)
    else Ok { tag = path_tag space source target; source; target; read_only }

let mount_of_spec ~guest_user ~space ~read_only spec =
  match
    parse_mount_spec ~host_home:(Util.home_dir ()) ~guest_user ~space ~read_only
      spec
  with
  | Error message ->
      Log.fatal "invalid mount in space %S: %s\n\nEntry: %s" space message spec
  | Ok mount ->
      if not (Sys.file_exists mount.source) then (
        Log.warn "skipping missing space path: %s" mount.source;
        None)
      else if not (Sys.is_directory mount.source) then (
        Log.warn "skipping non-directory space path: %s" mount.source;
        None)
      else Some mount

let collect_space_mounts ~guest_user config space =
  if not (space_exists config space) then
    Log.fatal "space not found in config: %s" space;
  let mounts read_only key =
    strings [ "spaces"; space; key ] config
    |> Option.value ~default:[]
    |> List.filter_map (mount_of_spec ~guest_user ~space ~read_only)
  in
  mounts true "ro_mounts" @ mounts false "rw_mounts"

let uniq_mounts (mounts : mount list) =
  let _, rev =
    List.fold_left
      (fun (seen, acc) (mount : mount) ->
        let key = (mount.source, mount.target, mount.read_only) in
        if List.mem key seen then (seen, acc) else (key :: seen, mount :: acc))
      ([], []) mounts
  in
  List.rev rev

let resources_for_spaces ~guest_user config spaces =
  let mounts =
    spaces
    |> List.concat_map (collect_space_mounts ~guest_user config)
    |> uniq_mounts
  in
  { mounts }
