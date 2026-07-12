let write_file path content =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out oc)
    (fun () -> output_string oc content)

let ensure_dir path = if not (Sys.file_exists path) then Unix.mkdir path 0o755

let output_dir =
  if Array.length Sys.argv > 1 then Sys.argv.(1)
  else "_build/ash-command-pages-html"

let base_href = if Array.length Sys.argv > 2 then Some Sys.argv.(2) else None

let () =
  ensure_dir output_dir;
  List.iter
    (fun (page : Pages.page) ->
      let path = Filename.concat output_dir (page.file ^ ".html") in
      write_file path (Pages.render_page ?base_href page))
    Pages.all;
  write_file
    (Filename.concat output_dir "index.html")
    (Pages.render_index ?base_href Pages.all)
