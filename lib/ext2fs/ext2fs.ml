type t

external create_raw :
  path:string -> size:int64 -> inodes:int -> label:string -> block_size:int -> t
  = "ash_ext2fs_create"

external open_existing : path:string -> t = "ash_ext2fs_open_existing"
external close : t -> unit = "ash_ext2fs_close"
external exists_raw : t -> string -> bool = "ash_ext2fs_exists"

external mkdir_raw : t -> string -> int -> int -> int -> float -> unit
  = "ash_ext2fs_mkdir_bytecode" "ash_ext2fs_mkdir"

external write_file_raw :
  t -> string -> string -> int -> int -> int -> float -> unit
  = "ash_ext2fs_write_file_bytecode" "ash_ext2fs_write_file"

external symlink_raw :
  t -> string -> string -> int -> int -> int -> float -> unit
  = "ash_ext2fs_symlink_bytecode" "ash_ext2fs_symlink"

let create ~path ~size ~inodes ?(label = "root") ?(block_size = 4096) () =
  if size < 16_777_216L then
    invalid_arg "Ext2fs.create: image must be at least 16 MiB";
  if inodes < 128 then
    invalid_arg "Ext2fs.create: at least 128 inodes are required";
  create_raw ~path ~size ~inodes ~label ~block_size

let exists t ~path = exists_raw t path
let mkdir t ~path ~mode ~uid ~gid ~mtime = mkdir_raw t path mode uid gid mtime

let write_file t ~path ~source ~mode ~uid ~gid ~mtime =
  write_file_raw t path source mode uid gid mtime

let symlink t ~path ~target ~mode ~uid ~gid ~mtime =
  symlink_raw t path target mode uid gid mtime
