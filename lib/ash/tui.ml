type key = Up | Down | Toggle | Toggle_all | Confirm | Quit | Other

let read_char ?timeout () =
  let ready =
    match timeout with
    | None -> true
    | Some timeout -> (
        match Unix.select [ Unix.stdin ] [] [] timeout with
        | [], _, _ -> false
        | _ -> true)
  in
  if not ready then None
  else
    let buf = Bytes.create 1 in
    match Unix.read Unix.stdin buf 0 1 with
    | 1 -> Some (Bytes.get buf 0)
    | _ -> None

let read_key () =
  match read_char () with
  | Some ('q' | 'Q') -> Quit
  | Some '\027' -> (
      match (read_char ~timeout:0.01 (), read_char ~timeout:0.01 ()) with
      | Some '[', Some 'A' -> Up
      | Some '[', Some 'B' -> Down
      | _ -> Quit)
  | Some ('k' | 'K') -> Up
  | Some ('j' | 'J') -> Down
  | Some ' ' -> Toggle
  | Some ('a' | 'A') -> Toggle_all
  | Some ('\n' | '\r') -> Confirm
  | Some _ | None -> Other

let restore_terminal original =
  Unix.tcsetattr Unix.stdin Unix.TCSANOW original;
  output_string stdout "\027[?25h\027[0m\n";
  flush stdout

let with_raw_terminal f =
  let original = Unix.tcgetattr Unix.stdin in
  let raw = { original with Unix.c_icanon = false; c_echo = false } in
  Unix.tcsetattr Unix.stdin Unix.TCSANOW raw;
  Fun.protect ~finally:(fun () -> restore_terminal original) f

let render ~title ~help ~items ~cursor ~selected =
  let b = Buffer.create 1024 in
  Buffer.add_string b "\027[2J\027[H\027[?25l";
  Buffer.add_string b title;
  Buffer.add_string b "\n\n";
  Buffer.add_string b help;
  Buffer.add_string b "\n\n";
  Array.iteri
    (fun idx item ->
      let cursor_marker = if idx = cursor then ">" else " " in
      let selected_marker =
        match selected with
        | None -> ""
        | Some selected ->
            Printf.sprintf " [%s]" (if selected.(idx) then "x" else " ")
      in
      Buffer.add_string b
        (Printf.sprintf "%s%s %s\n" cursor_marker selected_marker item))
    items;
  Buffer.contents b

let draw ~title ~help ~items ~cursor ~selected =
  output_string stdout (render ~title ~help ~items ~cursor ~selected);
  flush stdout

let move_up ~cursor ~len = if cursor = 0 then len - 1 else cursor - 1
let move_down ~cursor ~len = if cursor = len - 1 then 0 else cursor + 1

let single_select ~title ~help ~items =
  if Array.length items = 0 then None
  else
    with_raw_terminal (fun () ->
        let cursor = ref 0 in
        let rec loop () =
          draw ~title ~help ~items ~cursor:!cursor ~selected:None;
          match read_key () with
          | Quit -> None
          | Confirm -> Some !cursor
          | Up ->
              cursor := move_up ~cursor:!cursor ~len:(Array.length items);
              loop ()
          | Down ->
              cursor := move_down ~cursor:!cursor ~len:(Array.length items);
              loop ()
          | Toggle | Toggle_all | Other -> loop ()
        in
        loop ())

let multi_select ~title ~help ~items =
  if Array.length items = 0 then []
  else
    with_raw_terminal (fun () ->
        let selected = Array.make (Array.length items) false in
        let cursor = ref 0 in
        let rec loop () =
          draw ~title ~help ~items ~cursor:!cursor ~selected:(Some selected);
          match read_key () with
          | Quit -> []
          | Confirm ->
              selected |> Array.to_list
              |> List.mapi (fun idx value -> (idx, value))
              |> List.filter_map (fun (idx, value) ->
                  if value then Some idx else None)
          | Up ->
              cursor := move_up ~cursor:!cursor ~len:(Array.length items);
              loop ()
          | Down ->
              cursor := move_down ~cursor:!cursor ~len:(Array.length items);
              loop ()
          | Toggle ->
              selected.(!cursor) <- not selected.(!cursor);
              loop ()
          | Toggle_all ->
              let all_selected = Array.for_all Fun.id selected in
              Array.fill selected 0 (Array.length selected) (not all_selected);
              loop ()
          | Other -> loop ()
        in
        loop ())
