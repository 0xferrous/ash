type t = { target_root : string; jobs : int }

type backend = {
  mkdir : Plan.entry -> unit;
  write_file : Plan.entry -> unit;
  symlink : Plan.entry -> unit;
}

let align_up value alignment =
  let remainder = Int64.rem value alignment in
  if remainder = 0L then value
  else Int64.add value (Int64.sub alignment remainder)

let estimate_image_size (entries : Plan.entry list) =
  let data_bytes =
    List.fold_left
      (fun total (entry : Plan.entry) ->
        match entry.kind with
        | Plan.File -> Int64.add total entry.size
        | Plan.Dir | Plan.Symlink -> total)
      0L entries
  in
  let metadata = Int64.mul (Int64.of_int (List.length entries)) 8192L in
  let headroom = Int64.div data_bytes 5L in
  let minimum_overhead = Int64.mul 128L (Int64.mul 1024L 1024L) in
  let overhead = max minimum_overhead (Int64.add metadata headroom) in
  align_up
    (Int64.add data_bytes overhead)
    (Int64.mul 4L (Int64.mul 1024L 1024L))

let estimate_inode_count ~size entries =
  let required = List.length entries + 4096 in
  (* Match the conventional ext4 density of roughly one inode per 16 KiB so
     writable images retain useful inode headroom after importing a closure. *)
  let by_size = Int64.to_int (Int64.div size 16384L) in
  let estimated = max required by_size in
  (estimated + 4095) / 4096 * 4096

let ext2fs_backend ?(skip_existing = false) fs =
  let missing (entry : Plan.entry) =
    (not skip_existing) || not (Ash_ext2fs.Ext2fs.exists fs ~path:entry.target)
  in
  {
    mkdir =
      (fun (entry : Plan.entry) ->
        Ash_ext2fs.Ext2fs.mkdir fs ~path:entry.target ~mode:entry.mode
          ~uid:entry.uid ~gid:entry.gid ~mtime:entry.mtime);
    write_file =
      (fun (entry : Plan.entry) ->
        if missing entry then
          Ash_ext2fs.Ext2fs.write_file fs ~path:entry.target
            ~source:entry.source ~mode:entry.mode ~uid:entry.uid ~gid:entry.gid
            ~mtime:entry.mtime);
    symlink =
      (fun (entry : Plan.entry) ->
        if missing entry then
          Ash_ext2fs.Ext2fs.symlink fs ~path:entry.target
            ~target:(Option.value entry.link_target ~default:"")
            ~mode:entry.mode ~uid:entry.uid ~gid:entry.gid ~mtime:entry.mtime);
  }

let import_entries ~reporter ~backend ~metrics (entries : Plan.entry list) =
  Metrics.mark_mut_started metrics;
  let total = List.length entries in
  List.iteri
    (fun index (entry : Plan.entry) ->
      if index mod 1000 = 0 then
        Reporter.debug reporter "import progress %d/%d target=%s" index total
          entry.target;
      match entry.kind with
      | Plan.Dir -> backend.mkdir entry
      | Plan.File -> backend.write_file entry
      | Plan.Symlink -> backend.symlink entry)
    entries;
  Metrics.mark_mut_finished metrics

let append_image ?(reporter = Reporter.silent) ~path ~metrics entries =
  Reporter.info reporter "image append path=%s entries=%d" path
    (List.length entries);
  let fs = Ash_ext2fs.Ext2fs.open_existing ~path in
  Fun.protect
    ~finally:(fun () -> Ash_ext2fs.Ext2fs.close fs)
    (fun () ->
      let backend = ext2fs_backend ~skip_existing:true fs in
      import_entries ~reporter ~backend ~metrics entries)

let write_image ?size ?(label = "nix-store") ?(reporter = Reporter.silent) ~path
    ~metrics entries =
  let size = Option.value size ~default:(estimate_image_size entries) in
  let inodes = estimate_inode_count ~size entries in
  Reporter.info reporter "image create path=%s size=%Ld inodes=%d label=%s" path
    size inodes label;
  let fs = Ash_ext2fs.Ext2fs.create ~path ~size ~inodes ~label () in
  Fun.protect
    ~finally:(fun () -> Ash_ext2fs.Ext2fs.close fs)
    (fun () ->
      let backend = ext2fs_backend fs in
      import_entries ~reporter ~backend ~metrics entries)
