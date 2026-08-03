open Notty
module Term = Notty_unix.Term

type command =
  | Up
  | Down
  | Previous_pane
  | Next_pane
  | Toggle
  | Toggle_all
  | Next_sort
  | Reverse_sort
  | Confirm
  | Quit
  | Redraw
  | Ignore

type 'a sort = { name : string; compare : 'a -> 'a -> int }

type 'a pane = {
  title : string;
  columns : string;
  items : 'a array;
  label : 'a -> string;
  detail : 'a -> string;
  selection_summary : 'a list -> string;
  sorts : 'a sort array;
  initial_descending : bool;
}

type 'a row = { item : 'a; mutable selected : bool }

type 'a pane_state = {
  pane : 'a pane;
  mutable rows : 'a row array;
  mutable cursor : int;
  mutable sort_index : int;
  mutable descending : bool;
}

let sanitize_text text =
  let buffer = Buffer.create (String.length text) in
  let add _buffer _index = function
    | `Uchar uchar ->
        let code = Uchar.to_int uchar in
        if code < 0x20 || (code >= 0x7f && code <= 0x9f) then
          Uutf.Buffer.add_utf_8 buffer Uutf.u_rep
        else Uutf.Buffer.add_utf_8 buffer uchar;
        buffer
    | `Malformed _ ->
        Uutf.Buffer.add_utf_8 buffer Uutf.u_rep;
        buffer
  in
  Uutf.String.fold_utf_8 add buffer text |> Buffer.contents

let command_of_event = function
  | `Key (`Arrow `Up, _) | `Key (`ASCII ('k' | 'K'), []) -> Up
  | `Key (`Arrow `Down, _) | `Key (`ASCII ('j' | 'J'), []) -> Down
  | `Key (`Arrow `Left, _) -> Previous_pane
  | `Key (`Arrow `Right, _) | `Key (`Tab, _) -> Next_pane
  | `Key (`ASCII ' ', []) -> Toggle
  | `Key (`ASCII ('a' | 'A'), []) -> Toggle_all
  | `Key (`ASCII ('s' | 'S'), []) -> Next_sort
  | `Key (`ASCII ('r' | 'R'), []) -> Reverse_sort
  | `Key (`Enter, _) -> Confirm
  | `Key (`Escape, _) | `Key (`ASCII ('q' | 'Q'), []) -> Quit
  | `Resize _ -> Redraw
  | `End -> Quit
  | _ -> Ignore

let move_up ~cursor ~len = if cursor = 0 then len - 1 else cursor - 1
let move_down ~cursor ~len = if cursor = len - 1 then 0 else cursor + 1

let window_range ~length ~cursor ~visible =
  let visible = max 1 visible in
  let start = max 0 (min (length - visible) (cursor - visible + 1)) in
  (start, min length (start + visible))

let visible_range ~length ~cursor ~height =
  window_range ~length ~cursor ~visible:(height - 4)

let line ~width attr text =
  I.string attr (sanitize_text text) |> I.hsnap ~align:`Left width

let with_terminal f =
  let term = Term.create ~nosig:false ~mouse:false ~bpaste:false () in
  Fun.protect ~finally:(fun () -> Term.release term) (fun () -> f term)

let render_single ~size:(width, height) ~title ~help ~labels ~cursor =
  let width = max 1 width in
  let height = max 1 height in
  let start, stop =
    visible_range ~length:(Array.length labels) ~cursor ~height
  in
  let rows =
    List.init (stop - start) (fun offset ->
        let index = start + offset in
        let marker = if index = cursor then "> " else "  " in
        let attr = if index = cursor then A.(st reverse) else A.empty in
        line ~width attr (marker ^ labels.(index)))
  in
  I.vcat
    ([
       line ~width A.(st bold) title;
       I.void width 1;
       line ~width A.(fg lightblack) help;
       I.void width 1;
     ]
    @ rows)
  |> I.vsnap ~align:`Top height |> I.hsnap ~align:`Left width

let select_one ~title ~help ~items ~label =
  if Array.length items = 0 then None
  else
    let labels = Array.map label items in
    with_terminal (fun term ->
        let cursor = ref 0 in
        let rec loop () =
          Term.image term
            (render_single ~size:(Term.size term) ~title ~help ~labels
               ~cursor:!cursor);
          match Term.event term |> command_of_event with
          | Quit -> None
          | Confirm -> Some items.(!cursor)
          | Up ->
              cursor := move_up ~cursor:!cursor ~len:(Array.length items);
              loop ()
          | Down ->
              cursor := move_down ~cursor:!cursor ~len:(Array.length items);
              loop ()
          | Previous_pane | Next_pane | Toggle | Toggle_all | Next_sort
          | Reverse_sort | Redraw | Ignore ->
              loop ()
        in
        loop ())

let sort_pane state =
  let focused =
    if Array.length state.rows = 0 then None else Some state.rows.(state.cursor)
  in
  let sort = state.pane.sorts.(state.sort_index) in
  let compare left right =
    if state.descending then sort.compare right.item left.item
    else sort.compare left.item right.item
  in
  Array.sort compare state.rows;
  match focused with
  | None -> state.cursor <- 0
  | Some focused ->
      state.cursor <-
        Array.find_index (fun row -> row == focused) state.rows
        |> Option.value ~default:0

let next_sort state =
  state.sort_index <- (state.sort_index + 1) mod Array.length state.pane.sorts;
  sort_pane state

let make_pane_state pane =
  if Array.length pane.sorts = 0 then
    invalid_arg (Printf.sprintf "TUI pane %S has no sort options" pane.title);
  let state =
    {
      pane;
      rows = Array.map (fun item -> { item; selected = false }) pane.items;
      cursor = 0;
      sort_index = 0;
      descending = pane.initial_descending;
    }
  in
  sort_pane state;
  state

let selected_rows state =
  state.rows |> Array.to_list
  |> List.filter_map (fun row -> if row.selected then Some row.item else None)

let render_pane ~width ~height ~active state =
  let width = max 1 width in
  let height = max 1 height in
  let sort = state.pane.sorts.(state.sort_index) in
  let direction = if state.descending then "↓" else "↑" in
  let selected = selected_rows state in
  let header =
    Printf.sprintf " %s  sort: %s %s  selected: %d/%d (%s) " state.pane.title
      sort.name direction (List.length selected) (Array.length state.rows)
      (state.pane.selection_summary selected)
  in
  let header_attr =
    if active then A.(st bold ++ st reverse) else A.(st bold ++ fg lightblack)
  in
  let columns =
    line ~width A.(st bold ++ fg lightblack) ("      " ^ state.pane.columns)
  in
  let row_height = max 0 (height - 2) in
  let rows =
    if Array.length state.rows = 0 then
      [ line ~width A.(fg lightblack) "  (none)" ]
    else
      let start, stop =
        window_range ~length:(Array.length state.rows) ~cursor:state.cursor
          ~visible:row_height
      in
      List.init (stop - start) (fun offset ->
          let index = start + offset in
          let row = state.rows.(index) in
          let focused = active && index = state.cursor in
          let marker =
            Printf.sprintf "%s [%s] "
              (if focused then ">" else " ")
              (if row.selected then "x" else " ")
          in
          let attr =
            let attr =
              if row.selected then A.(fg lightgreen ++ st bold) else A.empty
            in
            if focused then A.(attr ++ st reverse) else attr
          in
          line ~width attr (marker ^ state.pane.label row.item))
  in
  I.vcat (line ~width header_attr header :: columns :: rows)
  |> I.vsnap ~align:`Top height |> I.hsnap ~align:`Left width

let pane_widths ~width ~count =
  let content_width = max count (width - (count - 1)) in
  Array.init count (fun index ->
      (content_width / count) + if index < content_width mod count then 1 else 0)

let intersperse separator images =
  let rec loop = function
    | [] -> []
    | [ image ] -> [ image ]
    | image :: rest -> image :: separator :: loop rest
  in
  loop images

let focused_detail state =
  if Array.length state.rows = 0 then state.pane.title ^ ": empty"
  else
    state.pane.title ^ ": " ^ state.pane.detail state.rows.(state.cursor).item

let render_panes ~size:(width, height) ~title ~help ~states ~active =
  let width = max 1 width in
  let height = max 1 height in
  let pane_height = max 1 (height - 5) in
  let widths = pane_widths ~width ~count:(Array.length states) in
  let panes =
    states |> Array.to_list
    |> List.mapi (fun index state ->
        render_pane ~width:widths.(index) ~height:pane_height
          ~active:(index = active) state)
  in
  let separator =
    I.uchar A.(fg lightblack) (Uchar.of_int 0x2502) 1 pane_height
  in
  let pane_image = I.hcat (intersperse separator panes) in
  I.vcat
    [
      line ~width A.(st bold) title;
      line ~width A.(fg lightblack) help;
      I.void width 1;
      pane_image;
      I.void width 1;
      line ~width A.(fg lightblack) (focused_detail states.(active));
    ]
  |> I.vsnap ~align:`Top height |> I.hsnap ~align:`Left width

let select_panes ~title ~help ~panes =
  if Array.length panes = 0 then []
  else
    let states = Array.map make_pane_state panes in
    let active =
      ref
        (Array.find_index (fun state -> Array.length state.rows > 0) states
        |> Option.value ~default:0)
    in
    let active_state () = states.(!active) in
    let change_pane offset =
      active := (!active + offset + Array.length states) mod Array.length states
    in
    let selected_items () =
      states |> Array.to_list |> List.concat_map selected_rows
    in
    with_terminal (fun term ->
        let rec loop () =
          Term.image term
            (render_panes ~size:(Term.size term) ~title ~help ~states
               ~active:!active);
          match Term.event term |> command_of_event with
          | Quit -> []
          | Confirm -> selected_items ()
          | Previous_pane ->
              change_pane (-1);
              loop ()
          | Next_pane ->
              change_pane 1;
              loop ()
          | Up ->
              let state = active_state () in
              if Array.length state.rows > 0 then
                state.cursor <-
                  move_up ~cursor:state.cursor ~len:(Array.length state.rows);
              loop ()
          | Down ->
              let state = active_state () in
              if Array.length state.rows > 0 then
                state.cursor <-
                  move_down ~cursor:state.cursor ~len:(Array.length state.rows);
              loop ()
          | Toggle ->
              let state = active_state () in
              (if Array.length state.rows > 0 then
                 let row = state.rows.(state.cursor) in
                 row.selected <- not row.selected);
              loop ()
          | Toggle_all ->
              let state = active_state () in
              let all_selected =
                Array.length state.rows > 0
                && Array.for_all (fun row -> row.selected) state.rows
              in
              Array.iter
                (fun row -> row.selected <- not all_selected)
                state.rows;
              loop ()
          | Next_sort ->
              next_sort (active_state ());
              loop ()
          | Reverse_sort ->
              let state = active_state () in
              state.descending <- not state.descending;
              sort_pane state;
              loop ()
          | Redraw | Ignore -> loop ()
        in
        loop ())
