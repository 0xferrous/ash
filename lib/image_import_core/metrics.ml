type t = {
  started_at : float;
  scan_started_at : float option Atomic.t;
  scan_finished_at : float option Atomic.t;
  mut_started_at : float option Atomic.t;
  mut_finished_at : float option Atomic.t;
  files : int Atomic.t;
  dirs : int Atomic.t;
  symlinks : int Atomic.t;
  bytes : int Atomic.t;
  jobs_seen : int Atomic.t;
}

let create () =
  {
    started_at = Unix.gettimeofday ();
    scan_started_at = Atomic.make None;
    scan_finished_at = Atomic.make None;
    mut_started_at = Atomic.make None;
    mut_finished_at = Atomic.make None;
    files = Atomic.make 0;
    dirs = Atomic.make 0;
    symlinks = Atomic.make 0;
    bytes = Atomic.make 0;
    jobs_seen = Atomic.make 0;
  }

let bump atom = ignore (Atomic.fetch_and_add atom 1)
let add_int atom value = ignore (Atomic.fetch_and_add atom value)
let bump_jobs_seen m = bump m.jobs_seen
let bump_dirs m = bump m.dirs
let bump_files m = bump m.files
let bump_symlinks m = bump m.symlinks
let add_bytes m value = add_int m.bytes value

let mark_started marker =
  if Atomic.get marker = None then
    Atomic.set marker (Some (Unix.gettimeofday ()))

let mark_finished marker = Atomic.set marker (Some (Unix.gettimeofday ()))
let mark_scan_started m = mark_started m.scan_started_at
let mark_scan_finished m = mark_finished m.scan_finished_at
let mark_mut_started m = mark_started m.mut_started_at
let mark_mut_finished m = mark_finished m.mut_finished_at

let duration started_at finished_at =
  match (Atomic.get started_at, Atomic.get finished_at) with
  | Some s, Some e -> Some (e -. s)
  | _ -> None

let log ?(prefix = "metrics") ?(reporter = Reporter.silent) m =
  let elapsed = Unix.gettimeofday () -. m.started_at in
  let fmt secs = Printf.sprintf "%.3fs" secs in
  Reporter.info reporter
    "%s elapsed=%s scan=%s mutate=%s dirs=%d files=%d symlinks=%d bytes=%Ld \
     jobs=%d"
    prefix (fmt elapsed)
    (match duration m.scan_started_at m.scan_finished_at with
    | Some v -> fmt v
    | None -> "-")
    (match duration m.mut_started_at m.mut_finished_at with
    | Some v -> fmt v
    | None -> "-")
    (Atomic.get m.dirs) (Atomic.get m.files) (Atomic.get m.symlinks)
    (Int64.of_int (Atomic.get m.bytes))
    (Atomic.get m.jobs_seen)
