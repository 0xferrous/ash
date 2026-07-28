type args = { list_types : bool; mime : string option; no_newline : bool }

let usage () =
  print_endline "Usage: wl-paste [--list-types] [--type <mime>] [--no-newline]"

let parse raw =
  let rec loop args = function
    | [] -> args
    | ("--list-types" | "-l") :: rest ->
        loop { args with list_types = true } rest
    | ("--no-newline" | "-n") :: rest ->
        loop { args with no_newline = true } rest
    | ("--type" | "-t") :: mime :: rest ->
        loop { args with mime = Some mime } rest
    | ("--type" | "-t") :: [] -> failwith "--type expects a MIME type"
    | ("--help" | "-h") :: _ ->
        usage ();
        exit 0
    | flag :: _ -> failwith ("unsupported argument: " ^ flag)
  in
  loop { list_types = false; mime = None; no_newline = false } raw

let () =
  try
    let args = Array.to_list Sys.argv |> List.tl |> parse in
    ignore args.no_newline;
    let client = Agent_portal.Client.create () in
    let mime, bytes =
      Agent_portal.Client.clipboard_read_image client
        (Some
           (if args.list_types then "wl-paste --list-types"
            else "wl-paste --type"))
    in
    if args.list_types then print_endline mime
    else
      match args.mime with
      | Some requested when requested <> mime ->
          failwith
            (Printf.sprintf
               "requested MIME %s is unavailable (portal returned %s)" requested
               mime)
      | _ ->
          output_string stdout bytes;
          flush stdout
  with exn ->
    Printf.eprintf "wl-paste wrapper error: %s\n%!" (Printexc.to_string exn);
    exit 1
