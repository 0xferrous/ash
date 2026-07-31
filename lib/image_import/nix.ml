let nix_exe () =
  match Ash.Util.find_in_path "nix" with
  | Some path -> path
  | None -> Ash.Log.fatal ~code:127 "could not find nix in PATH"

let run args =
  let cmd =
    String.concat " " (List.map Ash.Util.shell_quote (nix_exe () :: args))
  in
  Ash.Log.debug "nix: %s" cmd;
  Ash.Util.command_output cmd

let toplevel_attr ~flake =
  match String.index_opt flake '#' with
  | None ->
      invalid_arg
        "--flake must include a host fragment, for example ../my-nix#agent"
  | Some index ->
      let base = String.sub flake 0 index in
      let host =
        String.sub flake (index + 1) (String.length flake - index - 1)
      in
      if base = "" then
        invalid_arg "--flake must include a flake reference before #";
      if host = "" then invalid_arg "--flake must include a host name after #";
      if String.contains host '#' || String.contains host '.' then
        invalid_arg
          "--flake fragment must be a host name, not a full attribute path";
      base ^ "#nixosConfigurations." ^ host ^ ".config.system.build.toplevel"

let build_toplevel ~flake =
  run [ "build"; "--no-link"; "--print-out-paths"; toplevel_attr ~flake ]

let closure_paths ~path =
  run [ "path-info"; "-r"; path ]
  |> String.split_on_char '\n' |> List.map String.trim
  |> List.filter (( <> ) "")

let closure_size ~path =
  try
    let output = run [ "path-info"; "--recursive"; "--closure-size"; path ] in
    output |> String.split_on_char '\n' |> List.map String.trim
    |> List.filter (( <> ) "")
    |> List.rev |> List.hd |> String.split_on_char ' '
    |> List.filter (( <> ) "")
    |> List.rev |> List.hd |> Int64.of_string |> Option.some
  with _ -> None
