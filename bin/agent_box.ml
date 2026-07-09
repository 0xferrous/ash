type config = Otoml.t

type mount = {
  tag : string;
  source : string;
  target : string;
  read_only : bool;
}

type write_file = { source : string; guest_path : string; write_back : bool }
type profile_resources = { mounts : mount list; write_files : write_file list }

let strip_comment line =
  let b = Buffer.create (String.length line) in
  let in_string = ref false in
  let escaped = ref false in
  let stopped = ref false in
  String.iter
    (fun c ->
      if not !stopped then
        if !in_string then (
          Buffer.add_char b c;
          if !escaped then escaped := false
          else if c = '\\' then escaped := true
          else if c = '"' then in_string := false)
        else
          match c with
          | '#' -> stopped := true
          | '"' ->
              in_string := true;
              Buffer.add_char b c
          | _ -> Buffer.add_char b c)
    line;
  Buffer.contents b |> String.trim

let unescape_toml_basic s =
  let b = Buffer.create (String.length s) in
  let escaped = ref false in
  String.iter
    (fun c ->
      if !escaped then (
        escaped := false;
        Buffer.add_char b
          (match c with
          | 'n' -> '\n'
          | 'r' -> '\r'
          | 't' -> '\t'
          | '"' -> '"'
          | '\\' -> '\\'
          | other -> other))
      else if c = '\\' then escaped := true
      else Buffer.add_char b c)
    s;
  Buffer.contents b

let parse_string_literal s =
  let s = String.trim s in
  let len = String.length s in
  if len >= 2 && s.[0] = '"' && s.[len - 1] = '"' then
    unescape_toml_basic (String.sub s 1 (len - 2))
  else s

let parse_string_array s =
  let s = String.trim s in
  let len = String.length s in
  let inner =
    if len >= 2 && s.[0] = '[' && s.[len - 1] = ']' then String.sub s 1 (len - 2)
    else s
  in
  let values = ref [] in
  let b = Buffer.create 64 in
  let in_string = ref false in
  let escaped = ref false in
  let push () =
    let value = Buffer.contents b |> String.trim in
    Buffer.clear b;
    if value <> "" then values := parse_string_literal value :: !values
  in
  String.iter
    (fun c ->
      if !in_string then (
        Buffer.add_char b c;
        if !escaped then escaped := false
        else if c = '\\' then escaped := true
        else if c = '"' then in_string := false)
      else
        match c with
        | '"' ->
            in_string := true;
            Buffer.add_char b c
        | ',' -> push ()
        | c -> Buffer.add_char b c)
    inner;
  push ();
  List.rev !values

let load path : config =
  let path = Util.expand_home path in
  if not (Sys.file_exists path) then (
    Printf.eprintf
      "ash: config not found: %s\n\n\
       Hint: pass --config PATH or create ~/.agent-box.toml.\n"
      path;
    exit 1);
  match Otoml.Parser.from_file_result path with
  | Ok table -> table
  | Error message ->
      Printf.eprintf "ash: failed to parse config: %s\n\n%s\n" path message;
      exit 1

let key_path key = String.split_on_char '.' key
let string key config = Otoml.find_opt config Otoml.get_string (key_path key)
let int key config = Otoml.find_opt config Otoml.get_integer (key_path key)

let strings key config =
  Otoml.find_opt config (Otoml.get_array Otoml.get_string) (key_path key)

let default_profile config =
  string "default_profile" config |> Option.value ~default:"base"

let qemu_memory config = string "runtime.qemu.memory" config
let qemu_cpus config = int "runtime.qemu.cpus" config

let ssh_user config =
  string "runtime.qemu.ssh_user" config |> Option.value ~default:"agent"

let profile_exists config profile =
  Otoml.path_exists config [ "profiles"; profile ]

let profile_extends config profile =
  strings ("profiles." ^ profile ^ ".extends") config
  |> Option.value ~default:[]

let path_tag prefix path =
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
  let name = Filename.basename path |> Util.slug |> trim_dashes in
  let name = if name = "" then "mnt" else name in
  let name = String.sub name 0 (min max_name_len (String.length name)) in
  let hash = Digest.string (prefix ^ "\000" ^ path) |> Digest.to_hex in
  name ^ "-" ^ String.sub hash 0 hash_len

let strip_home_prefix path =
  let home = Util.home_dir () in
  let home_slash = home ^ "/" in
  if String.starts_with ~prefix:"~/" path then
    Some (String.sub path 2 (String.length path - 2))
  else if path = home then Some ""
  else if String.starts_with ~prefix:home_slash path then
    Some
      (String.sub path (String.length home_slash)
         (String.length path - String.length home_slash))
  else None

let directory_source path =
  if Sys.file_exists path && not (Sys.is_directory path) then
    Filename.dirname path
  else path

let mount_or_write_file ~read_only key ~source ~guest_path =
  if not (Sys.file_exists source) then (
    Log.warn "skipping missing profile path: %s" source;
    None)
  else if not (Sys.is_directory source) then
    Some (`WriteFile { source; guest_path; write_back = not read_only })
  else
    Some
      (`Mount
         {
           tag = path_tag (String.sub key 7 (String.length key - 7)) source;
           source;
           target = guest_path;
           read_only;
         })

let home_relative_entry ~guest_user ~read_only key source =
  let rel =
    match strip_home_prefix source with
    | Some rel -> rel
    | None ->
        if Filename.is_relative source then source else Filename.basename source
  in
  let host_source = Filename.concat (Util.home_dir ()) rel in
  let guest_path = Filename.concat ("/home/" ^ guest_user) rel in
  mount_or_write_file ~read_only key ~source:host_source ~guest_path

let absolute_entry ~read_only key source =
  let source = Util.expand_home source in
  mount_or_write_file ~read_only key ~source ~guest_path:source

let resources_of_entries entries =
  List.fold_right
    (fun entry acc ->
      match entry with
      | `Mount mount -> { acc with mounts = mount :: acc.mounts }
      | `WriteFile file -> { acc with write_files = file :: acc.write_files })
    entries
    { mounts = []; write_files = [] }

let append_resources left right =
  {
    mounts = left.mounts @ right.mounts;
    write_files = left.write_files @ right.write_files;
  }

let collect_profile_mounts ~guest_user config =
  let from_home_relative read_only profile key =
    strings ("profiles." ^ profile ^ "." ^ key) config
    |> Option.value ~default:[]
    |> List.filter_map (home_relative_entry ~guest_user ~read_only key)
  in
  let from_absolute read_only profile key =
    strings ("profiles." ^ profile ^ "." ^ key) config
    |> Option.value ~default:[]
    |> List.filter_map (absolute_entry ~read_only key)
  in
  let rec loop seen profile =
    if List.mem profile seen then (
      Log.warn "skipping cyclic profile extends: %s"
        (String.concat " -> " (List.rev (profile :: seen)));
      { mounts = []; write_files = [] })
    else if not (profile_exists config profile) then (
      Printf.eprintf "ash: profile not found in config: %s\n" profile;
      exit 1)
    else
      let inherited =
        profile_extends config profile
        |> List.map (loop (profile :: seen))
        |> List.fold_left append_resources { mounts = []; write_files = [] }
      in
      let own =
        from_home_relative true profile "mounts.ro.home_relative"
        @ from_absolute true profile "mounts.ro.absolute"
        @ from_home_relative false profile "mounts.rw.home_relative"
        @ from_absolute false profile "mounts.rw.absolute"
        @ from_home_relative false profile "mounts.o.home_relative"
        @ from_absolute false profile "mounts.o.absolute"
        |> resources_of_entries
      in
      append_resources inherited own
  in
  loop []

let uniq_mounts (mounts : mount list) =
  let _, rev =
    List.fold_left
      (fun (seen, acc) (mount : mount) ->
        if List.mem mount.source seen then (seen, acc)
        else (mount.source :: seen, mount :: acc))
      ([], []) mounts
  in
  List.rev rev

let uniq_write_files (files : write_file list) =
  let _, rev =
    List.fold_left
      (fun (seen, acc) (file : write_file) ->
        if List.mem file.guest_path seen then (seen, acc)
        else (file.guest_path :: seen, file :: acc))
      ([], []) files
  in
  List.rev rev

let resources_for_profiles ~guest_user config profiles =
  let resources =
    profiles
    |> List.map (collect_profile_mounts ~guest_user config)
    |> List.fold_left append_resources { mounts = []; write_files = [] }
  in
  {
    mounts = uniq_mounts resources.mounts;
    write_files = uniq_write_files resources.write_files;
  }
