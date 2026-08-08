(* FFI tests for the virtle library bindings (lib/ash/virtle_ffi.ml). These
   require libvirtle.so to be loadable; the nix dev shell sets ASH_LIBVIRTLE
   so CI runs them, while a plain `dune test` outside nix skips them. *)

open Ash


let assert_equal label expected actual =
  if expected <> actual then
    failwith (Printf.sprintf "%s: expected %S got %S" label expected actual)

let assert_bool label expected actual =
  if expected <> actual then
    failwith (Printf.sprintf "%s: expected %b got %b" label expected actual)

let contains haystack needle =
  let hlen = String.length haystack and nlen = String.length needle in
  let rec loop i = i + nlen <= hlen && (String.sub haystack i nlen = needle || loop (i + 1)) in
  nlen = 0 || loop 0

let manifest =
  {|host_name = "ffi-test"
kernel.path = "/boot/vmlinuz"
kernel.initrd_path = "/boot/initrd"
machine.memory = 512
machine.vcpu = 2
|}

let test_parse_and_resolved_json () =
  match Virtle_ffi.parse manifest with
  | Error message -> failwith ("ffi parse: " ^ message)
  | Ok m ->
      let json =
        match Virtle_ffi.resolved_json m with
        | Error message -> failwith ("ffi resolved json: " ^ message)
        | Ok json -> json
      in
      Virtle_ffi.free m;
      assert_bool "resolved json keeps host_name" true
        (contains json "ffi-test");
      assert_bool "resolved json has qemu machine" true (contains json "microvm")

let test_qemu_argv () =
  Virtle_ffi.with_manifest manifest (fun m ->
      match Virtle_ffi.qemu_argv m ~cid:3 ~incoming:false with
      | Error message -> failwith ("ffi qemu argv: " ^ message)
      | Ok argv ->
          assert_bool "argv has -name" true
            (Array.exists (fun arg -> arg = "-name") argv);
          assert_bool "argv has the manifest host name" true
            (Array.exists (fun arg -> arg = "ffi-test") argv);
          assert_bool "argv has a vsock guest cid" true
            (Array.exists (fun arg -> contains arg "guest-cid=3") argv))
  |> function
  | Error message -> failwith ("ffi parse: " ^ message)
  | Ok () -> ()

let run name test =
  Printf.printf "test %s ... %!" name;
  test ();
  Printf.printf "ok\n%!"

let () =
  match (try Ok (Virtle_ffi.version ()) with _ -> Error ()) with
  | Error () ->
      Printf.printf
        "virtle_ffi tests skipped (libvirtle.so not available; set \
         ASH_LIBVIRTLE)\n%!"
  | Ok version ->
      assert_equal "virtle ffi version" "0.1.0" version;
      run "virtle ffi parse + resolved json" test_parse_and_resolved_json;
      run "virtle ffi qemu argv" test_qemu_argv
