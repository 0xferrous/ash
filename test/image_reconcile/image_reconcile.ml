open Ash

let fail format = Printf.ksprintf failwith format

let read_store_paths path =
  In_channel.with_open_text path In_channel.input_lines
  |> List.map String.trim
  |> List.filter (( <> ) "")

let store_paths ~registration path =
  Filename.dirname registration :: read_store_paths path

let image_target store_path = "/store/" ^ Filename.basename store_path

let assert_image_path fs label store_path =
  let target = image_target store_path in
  if not (Ash_ext2fs.Ext2fs.exists fs ~path:target) then
    fail "%s is missing from reconciled image: %s" label target

let check_image image =
  let e2fsck = Util.get_exe None "e2fsck" in
  let code = Util.run_foreground e2fsck [ "-fn"; image ] in
  if code <> 0 then fail "e2fsck rejected reconciled image %s" image

let () =
  if Array.length Sys.argv <> 9 then
    fail
      "usage: %s IMAGE SIZE_MIB FIRST_TOPLEVEL FIRST_REGISTRATION \
       FIRST_STORE_PATHS SECOND_TOPLEVEL SECOND_REGISTRATION \
       SECOND_STORE_PATHS"
      Sys.argv.(0);
  let image = Sys.argv.(1) in
  let size_mib = int_of_string Sys.argv.(2) in
  let first_toplevel = Sys.argv.(3) in
  let first_registration = Sys.argv.(4) in
  let first_store_paths =
    store_paths ~registration:first_registration Sys.argv.(5)
  in
  let second_toplevel = Sys.argv.(6) in
  let second_registration = Sys.argv.(7) in
  let second_store_paths =
    store_paths ~registration:second_registration Sys.argv.(8)
  in
  if first_toplevel = second_toplevel then
    fail "test NixOS configurations resolved to the same toplevel";
  Nix.prepare_image_store ~store_paths:first_store_paths
    ~toplevel:first_toplevel ~registration:first_registration ~image ~size_mib
    ();
  let fs = Ash_ext2fs.Ext2fs.open_existing ~path:image in
  assert_image_path fs "first toplevel" first_toplevel;
  Ash_ext2fs.Ext2fs.close fs;
  Nix.prepare_image_store ~store_paths:second_store_paths
    ~toplevel:second_toplevel ~registration:second_registration ~image ~size_mib
    ();
  let fs = Ash_ext2fs.Ext2fs.open_existing ~path:image in
  Fun.protect
    ~finally:(fun () -> Ash_ext2fs.Ext2fs.close fs)
    (fun () ->
      assert_image_path fs "retained first toplevel" first_toplevel;
      assert_image_path fs "second toplevel" second_toplevel;
      assert_image_path fs "second registration output"
        (Filename.dirname second_registration));
  let expected_marker =
    Nix.image_store_marker_content ~toplevel:second_toplevel ~size_mib
      ~registration:second_registration
  in
  let actual_marker =
    In_channel.with_open_text (image ^ ".toplevel") In_channel.input_all
  in
  if actual_marker <> expected_marker then
    fail "unexpected reconciled image marker: %S" actual_marker;
  check_image image
