type decision = Allow | Ask | Deny
type gh_policy = Ask_for_writes | Ask_for_all | Ask_for_none | Deny_all
type transport = Unix | Vsock
type method_policy = { clipboard_read_image : decision; gh_exec : gh_policy }

type t = {
  enabled : bool;
  global : bool;
  transport : transport;
  socket_path : string;
  vsock_cid : int;
  vsock_port : int;
  prompt_command : string option;
  request_timeout_ms : int;
  prompt_timeout_ms : int;
  max_inflight : int;
  prompt_queue : int;
  rate_per_minute : int;
  rate_burst : int;
  max_clipboard_bytes : int;
  allowed_mime : string list;
  defaults : method_policy;
  containers : (string * method_policy) list;
}

let home_dir () = Sys.getenv_opt "HOME" |> Option.value ~default:"."

let application_name () =
  match Sys.getenv_opt "ASH_NAME" with
  | Some name when name <> "" ->
      if name = "." || name = ".." || String.contains name '/' then
        invalid_arg "ASH_NAME must be a single directory name"
      else name
  | _ -> "ash"

let config_home_dir () =
  match Sys.getenv_opt "XDG_CONFIG_HOME" with
  | Some path when path <> "" -> path
  | _ -> Filename.concat (home_dir ()) ".config"

let expand_home path =
  if path = "~" then home_dir ()
  else if String.starts_with ~prefix:"~/" path then
    Filename.concat (home_dir ()) (String.sub path 2 (String.length path - 2))
  else path

let ash_config_dir () =
  Filename.concat (config_home_dir ()) (application_name ())

let default_socket_path () =
  Printf.sprintf "/run/user/%d/agent-portal/portal.sock" (Unix.getuid ())

let default_policy = { clipboard_read_image = Allow; gh_exec = Ask_for_writes }

let defaults () =
  {
    enabled = true;
    global = false;
    transport = Unix;
    socket_path = default_socket_path ();
    vsock_cid = 2;
    vsock_port = 4050;
    prompt_command = None;
    request_timeout_ms = 0;
    prompt_timeout_ms = 0;
    max_inflight = 32;
    prompt_queue = 64;
    rate_per_minute = 60;
    rate_burst = 10;
    max_clipboard_bytes = 20 * 1024 * 1024;
    allowed_mime = [ "image/png"; "image/jpeg"; "image/webp" ];
    defaults = default_policy;
    containers = [];
  }

let default_path () =
  match Sys.getenv_opt "AGENT_PORTAL_CONFIG" with
  | Some path when path <> "" -> path
  | _ ->
      let ash = Filename.concat (ash_config_dir ()) "config.toml" in
      if Sys.file_exists ash then ash
      else Filename.concat (home_dir ()) ".agent-box.toml"

let get document getter path default =
  Otoml.find_opt document getter path |> Option.value ~default

let decision = function
  | "allow" -> Allow
  | "ask" -> Ask
  | "deny" -> Deny
  | value -> invalid_arg ("invalid portal policy decision: " ^ value)

let transport = function
  | "unix" -> Unix
  | "vsock" -> Vsock
  | value -> invalid_arg ("invalid portal transport: " ^ value)

let uint32 name value =
  if value < 0 || Int64.of_int value > 0xffff_ffffL then
    invalid_arg (name ^ " must fit in an unsigned 32-bit integer")
  else value

let positive_uint32 name value =
  let value = uint32 name value in
  if value = 0 then invalid_arg (name ^ " must be positive") else value

let gh_policy = function
  | "ask_for_writes" | "ask" -> Ask_for_writes
  | "ask_for_all" -> Ask_for_all
  | "ask_for_none" | "allow" -> Ask_for_none
  | "deny_all" | "deny" -> Deny_all
  | value -> invalid_arg ("invalid gh.exec policy: " ^ value)

let method_policy table fallback =
  let document = Otoml.TomlTable table in
  {
    clipboard_read_image =
      get document Otoml.get_string [ "clipboard_read_image" ]
        (match fallback.clipboard_read_image with
        | Allow -> "allow"
        | Ask -> "ask"
        | Deny -> "deny")
      |> decision;
    gh_exec =
      get document Otoml.get_string [ "gh_exec" ]
        (match fallback.gh_exec with
        | Ask_for_writes -> "ask_for_writes"
        | Ask_for_all -> "ask_for_all"
        | Ask_for_none -> "ask_for_none"
        | Deny_all -> "deny_all")
      |> gh_policy;
  }

let policy_table document path fallback =
  match Otoml.find_opt document Otoml.get_value path with
  | Some (Otoml.TomlTable table) -> method_policy table fallback
  | Some _ -> invalid_arg (String.concat "." path ^ " must be a table")
  | None -> fallback

let container_policies document defaults =
  match
    Otoml.find_opt document Otoml.get_value [ "portal"; "policy"; "containers" ]
  with
  | None -> []
  | Some (Otoml.TomlTable entries) ->
      List.map
        (function
          | container_id, Otoml.TomlTable table ->
              (container_id, method_policy table defaults)
          | container_id, _ ->
              invalid_arg
                (Printf.sprintf "portal.policy.containers.%s must be a table"
                   container_id))
        entries
  | Some _ -> invalid_arg "portal.policy.containers must be a table"

let of_document document =
  let fallback = defaults () in
  let p name = [ "portal"; name ] in
  let nested section name = [ "portal"; section; name ] in
  let policy_defaults =
    policy_table document [ "portal"; "policy"; "defaults" ] fallback.defaults
  in
  {
    enabled = get document Otoml.get_boolean (p "enabled") fallback.enabled;
    global = get document Otoml.get_boolean (p "global") fallback.global;
    transport =
      get document Otoml.get_string (p "transport") "unix" |> transport;
    socket_path =
      get document Otoml.get_string (p "socket_path") fallback.socket_path
      |> expand_home;
    vsock_cid =
      get document Otoml.get_integer (p "vsock_cid") fallback.vsock_cid
      |> uint32 "portal.vsock_cid";
    vsock_port =
      get document Otoml.get_integer (p "vsock_port") fallback.vsock_port
      |> positive_uint32 "portal.vsock_port";
    prompt_command =
      Otoml.find_opt document Otoml.get_string (p "prompt_command");
    request_timeout_ms =
      get document Otoml.get_integer
        (nested "timeouts" "request_ms")
        fallback.request_timeout_ms;
    prompt_timeout_ms =
      get document Otoml.get_integer
        (nested "timeouts" "prompt_ms")
        fallback.prompt_timeout_ms;
    max_inflight =
      get document Otoml.get_integer
        (nested "limits" "max_inflight")
        fallback.max_inflight;
    prompt_queue =
      get document Otoml.get_integer
        (nested "limits" "prompt_queue")
        fallback.prompt_queue;
    rate_per_minute =
      get document Otoml.get_integer
        (nested "limits" "rate_per_minute")
        fallback.rate_per_minute;
    rate_burst =
      get document Otoml.get_integer
        (nested "limits" "rate_burst")
        fallback.rate_burst;
    max_clipboard_bytes =
      get document Otoml.get_integer
        (nested "limits" "max_clipboard_bytes")
        fallback.max_clipboard_bytes;
    allowed_mime =
      get document
        (Otoml.get_array Otoml.get_string)
        (nested "clipboard" "allowed_mime")
        fallback.allowed_mime;
    defaults = policy_defaults;
    containers = container_policies document policy_defaults;
  }

let load ?path () =
  let path = Option.value path ~default:(default_path ()) |> expand_home in
  if not (Sys.file_exists path) then defaults ()
  else
    match Otoml.Parser.from_file_result path with
    | Ok document -> of_document document
    | Error message ->
        failwith
          (Printf.sprintf "failed to parse portal config %s: %s" path message)

let policy_for_container config container_id =
  match
    Option.bind container_id (fun id -> List.assoc_opt id config.containers)
  with
  | Some policy -> policy
  | None -> config.defaults
