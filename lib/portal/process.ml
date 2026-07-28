let ensure_dir path =
  let rec loop path =
    if path = "" || path = "." || Sys.file_exists path then ()
    else (
      loop (Filename.dirname path);
      Unix.mkdir path 0o755)
  in
  loop path

let is_executable path =
  try
    Unix.access path [ Unix.X_OK ];
    true
  with Unix.Unix_error _ -> false

let absolute_path path =
  if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path
  else path

let shell_quote value =
  "'" ^ String.concat "'\\''" (String.split_on_char '\'' value) ^ "'"

let status_code = function
  | Unix.WEXITED code -> code
  | Unix.WSIGNALED signal | Unix.WSTOPPED signal -> 128 + signal

let environment_with extra =
  let values = Hashtbl.create 64 in
  Array.iter
    (fun item ->
      match String.index_opt item '=' with
      | Some index -> Hashtbl.replace values (String.sub item 0 index) item
      | None -> ())
    (Unix.environment ());
  List.iter
    (fun (name, value) -> Hashtbl.replace values name (name ^ "=" ^ value))
    extra;
  Hashtbl.to_seq_values values |> Array.of_seq

let with_temp_outputs f =
  let stdout_path = Filename.temp_file "agent-portal" ".stdout" in
  let stderr_path = Filename.temp_file "agent-portal" ".stderr" in
  Fun.protect
    ~finally:(fun () ->
      List.iter
        (fun path -> try Unix.unlink path with Unix.Unix_error _ -> ())
        [ stdout_path; stderr_path ])
    (fun () ->
      let exit_code = f stdout_path stderr_path in
      let stdout = In_channel.with_open_bin stdout_path In_channel.input_all in
      let stderr = In_channel.with_open_bin stderr_path In_channel.input_all in
      Protocol.{ exit_code; stdout; stderr })

let wait ?(timeout_ms = 0) pid =
  if timeout_ms <= 0 then
    let _, status = Unix.waitpid [] pid in
    status_code status
  else
    let deadline = Unix.gettimeofday () +. (float timeout_ms /. 1000.) in
    let rec loop () =
      let waited, status = Unix.waitpid [ Unix.WNOHANG ] pid in
      if waited <> 0 then status_code status
      else if Unix.gettimeofday () >= deadline then (
        Unix.kill pid Sys.sigkill;
        ignore (Unix.waitpid [] pid);
        124)
      else (
        Unix.sleepf 0.02;
        loop ())
    in
    loop ()

let run ?cwd ?env ?(timeout_ms = 0) program args =
  with_temp_outputs (fun stdout_path stderr_path ->
      let stdout =
        Unix.openfile stdout_path [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600
      in
      let stderr =
        Unix.openfile stderr_path [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600
      in
      match Unix.fork () with
      | 0 -> (
          try
            Unix.dup2 stdout Unix.stdout;
            Unix.dup2 stderr Unix.stderr;
            Unix.close stdout;
            Unix.close stderr;
            Option.iter Unix.chdir cwd;
            let argv = Array.of_list (program :: args) in
            match env with
            | None -> Unix.execvp program argv
            | Some extra -> Unix.execvpe program argv (environment_with extra)
          with _ -> exit 127)
      | pid ->
          Unix.close stdout;
          Unix.close stderr;
          wait ~timeout_ms pid)

let find_binary name =
  let own_dir =
    Sys.executable_name |> absolute_path |> Filename.dirname |> Unix.realpath
  in
  let candidates =
    Sys.getenv_opt "PATH" |> Option.value ~default:""
    |> String.split_on_char ':'
    |> List.map (fun directory ->
        Filename.concat (if directory = "" then "." else directory) name)
  in
  match
    List.find_opt
      (fun path ->
        is_executable path
        &&
          try Filename.dirname (Unix.realpath path) <> own_dir
          with Unix.Unix_error _ -> false)
      candidates
  with
  | Some path -> path
  | None -> failwith (Printf.sprintf "host executable not found: %s" name)

let find_host_binary ~override_env name =
  match Sys.getenv_opt override_env with
  | Some path when path <> "" -> path
  | _ -> (
      try find_binary name
      with Failure _ ->
        failwith (Printf.sprintf "host %s not found; set %s" name override_env))
