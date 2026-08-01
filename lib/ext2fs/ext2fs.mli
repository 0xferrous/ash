type t

val create :
  path:string ->
  size:int64 ->
  inodes:int ->
  ?label:string ->
  ?block_size:int ->
  unit ->
  t

val open_existing : path:string -> t
val close : t -> unit
val exists : t -> path:string -> bool

val mkdir :
  t -> path:string -> mode:int -> uid:int -> gid:int -> mtime:float -> unit

val write_file :
  t ->
  path:string ->
  source:string ->
  mode:int ->
  uid:int ->
  gid:int ->
  mtime:float ->
  unit

val symlink :
  t ->
  path:string ->
  target:string ->
  mode:int ->
  uid:int ->
  gid:int ->
  mtime:float ->
  unit
