open Ctypes
open Foreign

(* Locate the shared library the same way the CLI binary is located: an
   explicit environment override first, then a default search name. *)
let library_path () =
  match Sys.getenv_opt "ASH_LIBVIRTLE" with
  | Some path -> path
  | None -> "libvirtle.so"

let library =
  lazy
    (try Dl.dlopen ~filename:(library_path ()) ~flags:[ Dl.RTLD_NOW ]
     with exn ->
       failwith
         (Printf.sprintf "load virtle library %S: %s" (library_path ())
            (Printexc.to_string exn)))

let load name typ =
  let lib = Lazy.force library in
  foreign ~from:lib name typ

(* Read a NUL-terminated C string. *)
let cstring p =
  let rec len i = if !@(p +@ i) = '\x00' then i else len (i + 1) in
  string_from_ptr ~length:(len 0) p

let version () =
  let f = load "virtle_ffi_version" (void @-> returning (ptr char)) in
  let p = f () in
  (* static string; the shim does not require a free *)
  cstring p

type manifest = int64

type launch_result = { cid : int; qmp_socket : string }

let parse data =
  let parse = load "virtle_manifest_parse" (string @-> size_t @-> ptr int64_t @-> ptr (ptr char) @-> returning int) in
  let string_free = load "virtle_string_free" (ptr char @-> returning void) in
  let handle = allocate int64_t 0L in
  let err = allocate (ptr char) (from_voidp char null) in
  if parse data (Unsigned.Size_t.of_int (String.length data)) handle err <> 0 then
    let message = cstring !@err in
    string_free !@err;
    Error message
  else Ok (!@handle)

let resolved_json m =
  let resolved_json = load "virtle_manifest_resolved_json" (int64_t @-> ptr (ptr char) @-> ptr (ptr char) @-> returning int) in
  let string_free = load "virtle_string_free" (ptr char @-> returning void) in
  let out = allocate (ptr char) (from_voidp char null) in
  let err = allocate (ptr char) (from_voidp char null) in
  if resolved_json m out err <> 0 then
    let message = cstring !@err in
    string_free !@err;
    Error message
  else
    let json = cstring !@out in
    string_free !@out;
    Ok json

let qemu_argv m ~cid ~incoming =
  let qemu_argv = load "virtle_qemu_argv" (int64_t @-> int @-> int @-> ptr (ptr (ptr char)) @-> ptr size_t @-> ptr (ptr char) @-> returning int) in
  let argv_free = load "virtle_argv_free" (ptr (ptr char) @-> size_t @-> returning void) in
  let string_free = load "virtle_string_free" (ptr char @-> returning void) in
  let argv_out = allocate (ptr (ptr char)) (from_voidp (ptr char) null) in
  let argc_out = allocate size_t (Unsigned.Size_t.zero) in
  let err = allocate (ptr char) (from_voidp char null) in
  if qemu_argv m cid (if incoming then 1 else 0) argv_out argc_out err <> 0 then
    let message = cstring !@err in
    string_free !@err;
    Error message
  else
    let argv = !@argv_out in
    let argc = Unsigned.Size_t.to_int !@argc_out in
    let args =
      Array.init argc (fun i ->
          let p = !@(argv +@ i) in
          let s = cstring p in
          s)
    in
    argv_free argv !@argc_out;
    Ok args

let launch m ~cid ~incoming =
  let launch = load "virtle_launch" (int64_t @-> int @-> int @-> ptr (ptr char) @-> ptr (ptr char) @-> returning int) in
  let string_free = load "virtle_string_free" (ptr char @-> returning void) in
  let out = allocate (ptr char) (from_voidp char null) in
  let err = allocate (ptr char) (from_voidp char null) in
  if launch m cid (if incoming then 1 else 0) out err <> 0 then
    let message = cstring !@err in
    string_free !@err;
    Error message
  else
    let json = cstring !@out in
    string_free !@out;
    match Yojson.Safe.from_string json with
    | `Assoc fields -> (
        match (List.assoc_opt "cid" fields, List.assoc_opt "qmpSocket" fields) with
        | Some (`Int cid), Some (`String qmp_socket) ->
            Ok { cid; qmp_socket }
        | _ -> Error ("unexpected launch result: " ^ json))
    | _ -> Error ("unexpected launch result: " ^ json)

let free m =
  let manifest_free = load "virtle_manifest_free" (int64_t @-> returning void) in
  manifest_free m

let with_manifest data f =
  match parse data with
  | Error _ as error -> error
  | Ok m ->
      Fun.protect ~finally:(fun () -> free m) (fun () -> Ok (f m))
