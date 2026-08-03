type kind = Cache | Vm

type origin = {
  flake_url : string;
  nixos_configuration : string;
  lock_hash : string;
  override_inputs : (string * string) list;
  first_seen_at : string;
  last_seen_at : string;
}

type t = {
  kind : kind;
  image_format : int;
  cache_key : string option;
  toplevel : string;
  registration : string;
  registration_sha256 : string option;
  created_at : string;
  last_used_at : string;
  updated_at : string option;
  virtual_size_bytes : int64;
  closure_nar_size_bytes : int64 option;
  closure_path_count : int option;
  configured_size_mib : int option;
  initialized_from_cache_key : string option;
  origins : origin list;
}

type read_result = Current of t | Legacy | Invalid | Missing

let schema_version = 1
let current_image_format = 5

let sidecar_path image =
  if Filename.check_suffix image ".img" then
    Filename.chop_suffix image ".img" ^ ".toml"
  else image ^ ".toml"

let legacy_path image = image ^ ".toplevel"

let timestamp ?(now = Unix.time ()) () =
  let tm = Unix.gmtime now in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ" (tm.tm_year + 1900)
    (tm.tm_mon + 1) tm.tm_mday tm.tm_hour tm.tm_min tm.tm_sec

let kind_string = function Cache -> "cache" | Vm -> "vm"

let kind_of_string = function
  | "cache" -> Some Cache
  | "vm" -> Some Vm
  | _ -> None

let sorted_overrides values =
  List.sort
    (fun (left_name, left_value) (right_name, right_value) ->
      match String.compare left_name right_name with
      | 0 -> String.compare left_value right_value
      | order -> order)
    values

let same_origin left right =
  left.flake_url = right.flake_url
  && left.nixos_configuration = right.nixos_configuration
  && left.lock_hash = right.lock_hash
  && sorted_overrides left.override_inputs
     = sorted_overrides right.override_inputs

let merge_origin origins origin =
  let rec loop acc = function
    | [] -> List.rev (origin :: acc)
    | existing :: rest when same_origin existing origin ->
        List.rev_append acc
          ({ existing with last_seen_at = origin.last_seen_at } :: rest)
    | existing :: rest -> loop (existing :: acc) rest
  in
  loop [] origins

let merge_origins existing additions =
  List.fold_left merge_origin existing additions

let integer64 value = Otoml.integer (Int64.to_int value)

let override_toml (name, flake_url) =
  Otoml.table
    [ ("input", Otoml.string name); ("flake_url", Otoml.string flake_url) ]

let origin_toml origin =
  Otoml.table
    [
      ("flake_url", Otoml.string origin.flake_url);
      ("nixos_configuration", Otoml.string origin.nixos_configuration);
      ("lock_hash", Otoml.string origin.lock_hash);
      ("first_seen_at", Otoml.string origin.first_seen_at);
      ("last_seen_at", Otoml.string origin.last_seen_at);
      ( "override_inputs",
        Otoml.TomlTableArray
          (sorted_overrides origin.override_inputs |> List.map override_toml) );
    ]

let add_optional name value encode fields =
  match value with
  | None -> fields
  | Some value -> fields @ [ (name, encode value) ]

let to_toml metadata =
  let fields =
    [
      ("schema_version", Otoml.integer schema_version);
      ("kind", Otoml.string (kind_string metadata.kind));
      ("image_format", Otoml.integer metadata.image_format);
      ("toplevel", Otoml.string metadata.toplevel);
      ("registration", Otoml.string metadata.registration);
      ("created_at", Otoml.string metadata.created_at);
      ("last_used_at", Otoml.string metadata.last_used_at);
      ("virtual_size_bytes", integer64 metadata.virtual_size_bytes);
    ]
  in
  fields
  |> add_optional "cache_key" metadata.cache_key Otoml.string
  |> add_optional "registration_sha256" metadata.registration_sha256
       Otoml.string
  |> add_optional "updated_at" metadata.updated_at Otoml.string
  |> add_optional "closure_nar_size_bytes" metadata.closure_nar_size_bytes
       integer64
  |> add_optional "closure_path_count" metadata.closure_path_count Otoml.integer
  |> add_optional "configured_size_mib" metadata.configured_size_mib
       Otoml.integer
  |> add_optional "initialized_from_cache_key"
       metadata.initialized_from_cache_key Otoml.string
  |> fun fields ->
  fields
  @ [
      ("origins", Otoml.TomlTableArray (List.map origin_toml metadata.origins));
    ]
  |> Otoml.table

let content metadata = Otoml.Printer.to_string (to_toml metadata)

let write image metadata =
  Util.atomic_write_file (sidecar_path image) (content metadata)

let required doc getter path =
  match Otoml.find_opt doc getter path with
  | Some value -> value
  | None -> failwith ("missing metadata field " ^ String.concat "." path)

let override_of_toml doc =
  ( required doc Otoml.get_string [ "input" ],
    required doc Otoml.get_string [ "flake_url" ] )

let origin_of_toml doc =
  {
    flake_url = required doc Otoml.get_string [ "flake_url" ];
    nixos_configuration =
      required doc Otoml.get_string [ "nixos_configuration" ];
    lock_hash = required doc Otoml.get_string [ "lock_hash" ];
    first_seen_at = required doc Otoml.get_string [ "first_seen_at" ];
    last_seen_at = required doc Otoml.get_string [ "last_seen_at" ];
    override_inputs =
      Otoml.find_opt doc
        (Otoml.get_array override_of_toml)
        [ "override_inputs" ]
      |> Option.value ~default:[];
  }

let of_toml doc =
  let schema = required doc Otoml.get_integer [ "schema_version" ] in
  if schema <> schema_version then failwith "unsupported metadata schema";
  let image_format = required doc Otoml.get_integer [ "image_format" ] in
  if image_format <> current_image_format then
    failwith "unsupported image format";
  let kind =
    match required doc Otoml.get_string [ "kind" ] |> kind_of_string with
    | Some kind -> kind
    | None -> failwith "invalid metadata kind"
  in
  {
    kind;
    image_format;
    cache_key = Otoml.find_opt doc Otoml.get_string [ "cache_key" ];
    toplevel = required doc Otoml.get_string [ "toplevel" ];
    registration = required doc Otoml.get_string [ "registration" ];
    registration_sha256 =
      Otoml.find_opt doc Otoml.get_string [ "registration_sha256" ];
    created_at = required doc Otoml.get_string [ "created_at" ];
    last_used_at = required doc Otoml.get_string [ "last_used_at" ];
    updated_at = Otoml.find_opt doc Otoml.get_string [ "updated_at" ];
    virtual_size_bytes =
      required doc Otoml.get_integer [ "virtual_size_bytes" ] |> Int64.of_int;
    closure_nar_size_bytes =
      Otoml.find_opt doc Otoml.get_integer [ "closure_nar_size_bytes" ]
      |> Option.map Int64.of_int;
    closure_path_count =
      Otoml.find_opt doc Otoml.get_integer [ "closure_path_count" ];
    configured_size_mib =
      Otoml.find_opt doc Otoml.get_integer [ "configured_size_mib" ];
    initialized_from_cache_key =
      Otoml.find_opt doc Otoml.get_string [ "initialized_from_cache_key" ];
    origins =
      Otoml.find_opt doc (Otoml.get_array origin_of_toml) [ "origins" ]
      |> Option.value ~default:[];
  }

let read image =
  let sidecar = sidecar_path image in
  if Sys.file_exists sidecar then
    match Otoml.Parser.from_file_result sidecar with
    | Error _ -> Invalid
    | Ok doc -> ( try Current (of_toml doc) with _ -> Invalid)
  else if Sys.file_exists (legacy_path image) then Legacy
  else Missing

let remove image =
  List.iter
    (fun path ->
      try Unix.unlink path with Unix.Unix_error (Unix.ENOENT, _, _) -> ())
    [ sidecar_path image; legacy_path image ]
