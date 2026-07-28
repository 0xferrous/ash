let shell_quote value =
  "'" ^ String.concat "'\\''" (String.split_on_char '\'' value) ^ "'"

let safe_arg argument =
  String.for_all
    (function
      | 'a' .. 'z'
      | 'A' .. 'Z'
      | '0' .. '9'
      | '-' | '.' | '_' | '/' | ':' | '=' | '@' ->
          true
      | _ -> false)
    argument

let shell_join arguments =
  arguments
  |> List.map (fun argument ->
      if safe_arg argument then argument else shell_quote argument)
  |> String.concat " "

let () =
  try
    let arguments = Array.to_list Sys.argv |> List.tl in
    let client = Agent_portal.Client.create () in
    let result =
      Agent_portal.Client.gh_exec client arguments
        (Some ("gh-wrapper cmd=" ^ shell_join arguments))
        false
    in
    output_string stdout result.stdout;
    flush stdout;
    output_string stderr result.stderr;
    flush stderr;
    exit result.exit_code
  with exn ->
    Printf.eprintf "gh wrapper error: %s\n%!" (Printexc.to_string exn);
    exit 1
