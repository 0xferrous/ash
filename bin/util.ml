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
  Fun.protect ~finally:(fun () -> close_out oc) (fun () -> output_string oc content)

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
  try Unix.access path [ Unix.X_OK ]; true with Unix.Unix_error _ -> false

let some_if condition value = if condition then Some value else None

let find_in_path program =
  if String.contains program '/' then some_if (is_executable program) program
  else
    Sys.getenv_opt "PATH"
    |> Option.value ~default:""
    |> String.split_on_char ':'
    |> List.filter_map (fun dir ->
           let dir = if dir = "" then "." else dir in
           let path = Filename.concat dir program in
           some_if (is_executable path) path)
    |> List.find_opt (fun _ -> true)

let shell_quote s = "'" ^ String.concat "'\\''" (String.split_on_char '\'' s) ^ "'"

let exec program args =
  Log.debug "exec: %s" (String.concat " " (List.map shell_quote (program :: args)));
  let argv = Array.of_list (program :: args) in
  Unix.execvp program argv

let command_output command =
  Log.debug "run: %s" command;
  let file = Filename.temp_file "ash" ".out" in
  let status = Sys.command (command ^ " > " ^ shell_quote file) in
  let output = In_channel.with_open_text file In_channel.input_all |> String.trim in
  Sys.remove file;
  if status = 0 then (
    Log.debug "command output: %s" output;
    output)
  else (
    Log.debug "command failed with status %d: %s" status command;
    failwith ("command failed: " ^ command))

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
      | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' as c -> Buffer.add_char b c
      | _ -> Buffer.add_char b '-')
    s;
  Buffer.contents b

let name_slug s =
  let b = Buffer.create (String.length s) in
  String.iter
    (function
      | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '.' | '_' | '-' as c -> Buffer.add_char b c
      | _ -> Buffer.add_char b '-')
    s;
  Buffer.contents b
