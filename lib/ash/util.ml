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

let cache_home_dir () =
  match Sys.getenv_opt "XDG_CACHE_HOME" with
  | Some path when path <> "" -> path
  | _ -> Filename.concat (home_dir ()) ".cache"

let expand_home path =
  if path = "~" then home_dir ()
  else if String.length path >= 2 && String.sub path 0 2 = "~/" then
    Filename.concat (home_dir ()) (String.sub path 2 (String.length path - 2))
  else path

let ash_config_dir () =
  Filename.concat (config_home_dir ()) (application_name ())

let default_ash_config_path () =
  Filename.concat (ash_config_dir ()) "config.toml"

let ensure_dir path =
  let rec loop path =
    if path = "" || path = "." || Sys.file_exists path then ()
    else (
      loop (Filename.dirname path);
      Unix.mkdir path 0o755)
  in
  loop path

let write_file path content =
  ensure_dir (Filename.dirname path);
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out oc)
    (fun () -> output_string oc content)

let atomic_write_file path content =
  let dir = Filename.dirname path in
  ensure_dir dir;
  let temp_path, oc =
    Filename.open_temp_file ~temp_dir:dir (Filename.basename path ^ ".tmp-") ""
  in
  try
    output_string oc content;
    flush oc;
    Unix.fsync (Unix.descr_of_out_channel oc);
    close_out oc;
    Unix.rename temp_path path
  with exn ->
    close_out_noerr oc;
    (try Unix.unlink temp_path with Unix.Unix_error _ -> ());
    raise exn

let copy_file ~src ~dst =
  ensure_dir (Filename.dirname dst);
  let ic = open_in_bin src in
  Fun.protect
    ~finally:(fun () -> close_in ic)
    (fun () ->
      let oc = open_out_bin dst in
      Fun.protect
        ~finally:(fun () -> close_out oc)
        (fun () ->
          let buffer = Bytes.create 65536 in
          let rec loop () =
            let n = input ic buffer 0 (Bytes.length buffer) in
            if n > 0 then (
              output oc buffer 0 n;
              loop ())
          in
          loop ()))

let is_executable path =
  try
    Unix.access path [ Unix.X_OK ];
    true
  with Unix.Unix_error _ -> false

let some_if condition value = if condition then Some value else None

let absolute_path path =
  if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path
  else path

let find_in_path program =
  if String.contains program '/' then
    if is_executable program then Some (absolute_path program) else None
  else
    Sys.getenv_opt "PATH" |> Option.value ~default:""
    |> String.split_on_char ':'
    |> List.filter_map (fun dir ->
        let dir = if dir = "" then "." else dir in
        let path = Filename.concat dir program in
        some_if (is_executable path) path)
    |> List.find_opt (fun _ -> true)

let get_exe ?hint ?env explicit_path default_name =
  let candidate =
    match explicit_path with
    | Some path -> path
    | None -> (
        match Option.bind env Sys.getenv_opt with
        | Some path when path <> "" -> path
        | _ -> default_name)
  in
  match find_in_path candidate with
  | Some path ->
      Log.debug "executable=%S resolved=%S" candidate path;
      path
  | None ->
      let hint =
        match hint with None -> "" | Some hint -> "\n\nHint: " ^ hint
      in
      Log.fatal ~code:127 "could not find executable %S%s" candidate hint

let shell_quote s =
  "'" ^ String.concat "'\\''" (String.split_on_char '\'' s) ^ "'"

let log_quote s = Printf.sprintf "%S" s
let log_command args = String.concat " " (List.map log_quote args)

let exec program args =
  Log.debug "exec: %s" (log_command (program :: args));
  let argv = Array.of_list (program :: args) in
  Unix.execvp program argv

let process_status_code = function
  | Unix.WEXITED code -> code
  | Unix.WSIGNALED signal -> 128 + signal
  | Unix.WSTOPPED signal -> 128 + signal

let run_foreground program args =
  Log.debug "run foreground: %s" (log_command (program :: args));
  (* Interactive children such as ssh may leave the terminal in raw/no-echo
     mode. Since callers like `spawn --ephemeral` keep ash alive after the
     child exits, save and restore the terminal so the parent shell is usable. *)
  let terminal_attrs =
    if Unix.isatty Unix.stdin then
      try Some (Unix.tcgetattr Unix.stdin) with Unix.Unix_error _ -> None
    else None
  in
  Fun.protect
    ~finally:(fun () ->
      Option.iter
        (fun attrs ->
          try Unix.tcsetattr Unix.stdin Unix.TCSANOW attrs
          with Unix.Unix_error _ -> ())
        terminal_attrs)
    (fun () ->
      let argv = Array.of_list (program :: args) in
      let pid =
        Unix.create_process program argv Unix.stdin Unix.stdout Unix.stderr
      in
      let _, status = Unix.waitpid [] pid in
      process_status_code status)

let clone_file ?copy_executable ~src ~dst () =
  let copy =
    get_exe
      ~hint:
        "GNU cp is required to clone a cached image-backed Nix store into VM \
         state."
      copy_executable "cp"
  in
  ensure_dir (Filename.dirname dst);
  (try Unix.unlink dst with Unix.Unix_error (Unix.ENOENT, _, _) -> ());
  let code =
    run_foreground copy [ "--reflink=auto"; "--sparse=always"; "--"; src; dst ]
  in
  if code <> 0 then (
    (try Unix.unlink dst with Unix.Unix_error _ -> ());
    failwith (Printf.sprintf "failed to clone %s to %s" src dst))

let command_output ?(debug = true) command =
  let stdout_file = Filename.temp_file "ash" ".out" in
  let stderr_file = Filename.temp_file "ash" ".err" in
  let stdout_fd =
    Unix.openfile stdout_file [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600
  in
  let stderr_fd =
    Unix.openfile stderr_file [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600
  in
  let pid =
    Fun.protect
      ~finally:(fun () ->
        Unix.close stdout_fd;
        Unix.close stderr_fd)
      (fun () ->
        Unix.create_process "/bin/sh"
          [| "/bin/sh"; "-c"; command |]
          Unix.stdin stdout_fd stderr_fd)
  in
  let _, process_status = Unix.waitpid [] pid in
  let status = process_status_code process_status in
  if debug then
    Log.debug "command=%S exit_code=%d stdout=%S stderr=%S" command status
      stdout_file stderr_file;
  let output = In_channel.with_open_text stdout_file In_channel.input_all in
  let stderr = In_channel.with_open_text stderr_file In_channel.input_all in
  let output = String.trim output in
  let stderr = String.trim stderr in
  if status = 0 then output
  else
    failwith
      (Printf.sprintf "command failed (exit %d): %s%s%s" status command
         (if output = "" then "" else "\nstdout:\n" ^ output)
         (if stderr = "" then "" else "\nstderr:\n" ^ stderr))

let slug s =
  let b = Buffer.create (String.length s) in
  String.iter
    (function
      | ('a' .. 'z' | 'A' .. 'Z' | '0' .. '9') as c -> Buffer.add_char b c
      | _ -> Buffer.add_char b '-')
    s;
  Buffer.contents b

let name_slug s =
  let b = Buffer.create (String.length s) in
  String.iter
    (function
      | ('a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '.' | '_' | '-') as c ->
          Buffer.add_char b c
      | _ -> Buffer.add_char b '-')
    s;
  Buffer.contents b

let dns_label name =
  let lowered = String.lowercase_ascii name in
  let changed = ref (lowered <> name) in
  let buffer = Buffer.create (String.length lowered) in
  String.iter
    (function
      | ('a' .. 'z' | '0' .. '9' | '-') as character ->
          Buffer.add_char buffer character
      | _ ->
          changed := true;
          Buffer.add_char buffer '-')
    lowered;
  let value = Buffer.contents buffer in
  let length = String.length value in
  let rec first i =
    if i < length && value.[i] = '-' then first (i + 1) else i
  in
  let rec last i = if i >= 0 && value.[i] = '-' then last (i - 1) else i in
  let start = first 0 in
  let stop = last (length - 1) in
  let normalized =
    if stop < start then "" else String.sub value start (stop - start + 1)
  in
  if normalized <> lowered then changed := true;
  let normalized = if normalized = "" then "vm" else normalized in
  if (not !changed) && String.length normalized <= 63 then normalized
  else
    let suffix =
      "-"
      ^ ( Digest.string name |> Digest.to_hex |> fun value ->
          String.sub value 0 8 )
    in
    let maximum_base = 63 - String.length suffix in
    let base =
      if String.length normalized <= maximum_base then normalized
      else String.sub normalized 0 maximum_base
    in
    let base_length = String.length base in
    let rec last_base i =
      if i >= 0 && base.[i] = '-' then last_base (i - 1) else i
    in
    let base_stop = last_base (base_length - 1) in
    let base =
      if base_stop < 0 then "vm" else String.sub base 0 (base_stop + 1)
    in
    base ^ suffix

let rec remove_tree ?(force = false) path =
  if Sys.file_exists path then
    if force then (
      (* Overlay/virtiofs cleanup can leave directories without owner execute
         bits (for example overlayfs work dirs). Make the tree traversable
         before rm -rf; ignore chmod failures so rm still gets a chance. *)
      let command =
        "chmod -R u+rwX -- " ^ shell_quote path
        ^ " 2>/dev/null || true; rm -rf -- " ^ shell_quote path
      in
      let status = Sys.command command in
      if status <> 0 && Sys.file_exists path then
        failwith ("failed to remove tree: " ^ path))
    else
      let stat = Unix.lstat path in
      match stat.st_kind with
      | Unix.S_DIR ->
          Sys.readdir path
          |> Array.iter (fun entry -> remove_tree (Filename.concat path entry));
          Unix.rmdir path
      | _ -> Unix.unlink path
