let home_dir () = Sys.getenv_opt "HOME" |> Option.value ~default:"."

let expand_home path =
  if path = "~" then home_dir ()
  else if String.length path >= 2 && String.sub path 0 2 = "~/" then
    Filename.concat (home_dir ()) (String.sub path 2 (String.length path - 2))
  else path

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

let find_in_path program =
  if String.contains program '/' then some_if (is_executable program) program
  else
    Sys.getenv_opt "PATH" |> Option.value ~default:""
    |> String.split_on_char ':'
    |> List.filter_map (fun dir ->
        let dir = if dir = "" then "." else dir in
        let path = Filename.concat dir program in
        some_if (is_executable path) path)
    |> List.find_opt (fun _ -> true)

let shell_quote s =
  "'" ^ String.concat "'\\''" (String.split_on_char '\'' s) ^ "'"

let exec program args =
  Log.debug "exec: %s"
    (String.concat " " (List.map shell_quote (program :: args)));
  let argv = Array.of_list (program :: args) in
  Unix.execvp program argv

let process_status_code = function
  | Unix.WEXITED code -> code
  | Unix.WSIGNALED signal -> 128 + signal
  | Unix.WSTOPPED signal -> 128 + signal

let run_foreground program args =
  Log.debug "run foreground: %s"
    (String.concat " " (List.map shell_quote (program :: args)));
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
  let output = String.trim output in
  if status = 0 then output else failwith ("command failed: " ^ command)

let toml_quote s =
  let b = Buffer.create (String.length s + 8) in
  Buffer.add_char b '"';
  String.iter
    (function
      | '"' -> Buffer.add_string b "\\\""
      | '\\' -> Buffer.add_string b "\\\\"
      | '\n' -> Buffer.add_string b "\\n"
      | '\r' -> Buffer.add_string b "\\r"
      | '\t' -> Buffer.add_string b "\\t"
      | c -> Buffer.add_char b c)
    s;
  Buffer.add_char b '"';
  Buffer.contents b

let toml_array xs = "[" ^ String.concat ", " (List.map toml_quote xs) ^ "]"

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

let rec remove_tree path =
  if Sys.file_exists path then
    let stat = Unix.lstat path in
    match stat.st_kind with
    | Unix.S_DIR ->
        Sys.readdir path
        |> Array.iter (fun entry -> remove_tree (Filename.concat path entry));
        Unix.rmdir path
    | _ -> Unix.unlink path
