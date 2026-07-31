open Plan

type item = {
  source : string;
  target : string;
  kind : entry_kind;
  stat : Unix.stats;
  link_target : string option;
}

let to_entry item : Plan.entry =
  {
    source = item.source;
    target = item.target;
    kind = item.kind;
    size = Int64.of_int item.stat.Unix.st_size;
    mode = item.stat.Unix.st_perm;
    uid = item.stat.Unix.st_uid;
    gid = item.stat.Unix.st_gid;
    mtime = item.stat.Unix.st_mtime;
    link_target = item.link_target;
  }

let is_dir stats = stats.Unix.st_kind = Unix.S_DIR
let is_reg stats = stats.Unix.st_kind = Unix.S_REG
let is_lnk stats = stats.Unix.st_kind = Unix.S_LNK

type progress = {
  label : string;
  started_at : float;
  total_bytes : int64 option;
  entries : int ref;
  bytes : int64 ref;
  mutable next_report : int;
}

let log_progress ~reporter progress current =
  let count = !(progress.entries) in
  if count >= progress.next_report then (
    progress.next_report <- progress.next_report + 100;
    let elapsed = max 0.001 (Unix.gettimeofday () -. progress.started_at) in
    let eps = float_of_int count /. elapsed in
    let bps = Int64.to_float !(progress.bytes) /. elapsed in
    let eta =
      match progress.total_bytes with
      | Some total when bps > 0.0 ->
          let remaining =
            if total > !(progress.bytes) then Int64.sub total !(progress.bytes)
            else 0L
          in
          Printf.sprintf "%.1fs" (Int64.to_float remaining /. bps)
      | _ -> "?"
    in
    Reporter.debug reporter
      "%s progress count=%d entries/s=%.1f bytes/s=%.1f eta=%s current=%s"
      progress.label count eps bps eta current)

let record ~reporter metrics progress item =
  Metrics.bump_jobs_seen metrics;
  progress.entries := !(progress.entries) + 1;
  (match item.kind with
  | Dir -> Metrics.bump_dirs metrics
  | File ->
      Metrics.bump_files metrics;
      Metrics.add_bytes metrics item.stat.Unix.st_size;
      progress.bytes :=
        Int64.add !(progress.bytes) (Int64.of_int item.stat.Unix.st_size)
  | Symlink -> Metrics.bump_symlinks metrics);
  log_progress ~reporter progress item.source;
  to_entry item

let rec walk ?(target_root = "") ~reporter ~progress metrics source acc =
  let st = Unix.lstat source in
  let target =
    if target_root = "" then source
    else Filename.concat target_root (Filename.basename source)
  in
  if is_dir st then
    let children =
      Sys.readdir source |> Array.to_list |> List.sort String.compare
      |> List.map (fun name -> Filename.concat source name)
    in
    let acc =
      record ~reporter metrics progress
        { source; target; kind = Dir; stat = st; link_target = None }
      :: acc
    in
    List.fold_left
      (fun acc child ->
        walk ~target_root:target ~reporter ~progress metrics child acc)
      acc children
  else if is_reg st then
    record ~reporter metrics progress
      { source; target; kind = File; stat = st; link_target = None }
    :: acc
  else if is_lnk st then
    let link_target = Some (Unix.readlink source) in
    record ~reporter metrics progress
      { source; target; kind = Symlink; stat = st; link_target }
    :: acc
  else acc

let of_root_with_progress ~reporter ~target_root ~root ~progress metrics =
  walk ~reporter ~progress metrics ~target_root root [] |> List.rev

let of_root ~root =
  let metrics = Metrics.create () in
  let progress =
    {
      label = Filename.basename root;
      started_at = Unix.gettimeofday ();
      total_bytes = None;
      entries = ref 0;
      bytes = ref 0L;
      next_report = max_int;
    }
  in
  of_root_with_progress ~reporter:Reporter.silent ~target_root:"" ~root
    ~progress metrics

let scan_closure ~reporter ~jobs ~closure_paths ~target_root ~total_bytes
    metrics =
  Reporter.info reporter "scan start roots=%d jobs=%d"
    (List.length closure_paths)
    jobs;
  Metrics.mark_scan_started metrics;
  let results : Plan.entry list =
    closure_paths
    |> List.concat_map (fun path ->
        let target = Filename.concat target_root (Filename.basename path) in
        Reporter.debug reporter "scan root source=%s target=%s" path target;
        let progress =
          {
            label = Filename.basename path;
            started_at = Unix.gettimeofday ();
            total_bytes;
            entries = ref 0;
            bytes = ref 0L;
            next_report = 100;
          }
        in
        of_root_with_progress ~reporter ~target_root ~root:path ~progress
          metrics)
    |> Plan.dedup_by_target (fun (entry : Plan.entry) -> entry.target)
  in
  Metrics.mark_scan_finished metrics;
  Reporter.info reporter "scan done entries=%d" (List.length results);
  results
