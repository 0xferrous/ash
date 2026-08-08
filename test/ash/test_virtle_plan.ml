(* Plan parsing tests for lib/ash/virtle_plan.ml. Pure: no FFI library
   required, so these always run under plain dune test. *)

open Ash

let fail msg = failwith msg

let assert_equal_int label expected actual =
  if expected <> actual then
    fail (Printf.sprintf "%s: expected %d got %d" label expected actual)

let assert_equal_string label expected actual =
  if expected <> actual then
    fail (Printf.sprintf "%s: expected %S got %S" label expected actual)

let sample =
  {|{
  "cid": 7,
  "incoming": false,
  "stateDir": "/tmp/work",
  "qmpSocket": "/tmp/work/qmp.sock",
  "guestAgentSocket": "/tmp/work/qga.sock",
  "sshReadySocket": "",
  "qemuBinary": "qemu-system-x86_64",
  "qemuArgv": ["-name", "vm", "-m", "512"],
  "runs": [
    { "exec": ["virtiofsd", "--tag=fs"], "env": ["FOO=bar"], "dir": "/tmp/work" }
  ],
  "virtiofsSockets": ["/tmp/work/fs.sock"],
  "cleanupFiles": ["/tmp/work/qmp.sock", "/tmp/work/fs.sock"],
  "prepareDirs": ["/tmp/work"]
}|}

let test_of_json_fields () =
  let plan = Virtle_plan.of_json sample in
  assert_equal_int "cid" 7 plan.cid;
  assert_equal_string "state_dir" "/tmp/work" plan.state_dir;
  assert_equal_string "qmp_socket" "/tmp/work/qmp.sock" plan.qmp_socket;
  assert_equal_string "guest_agent_socket" "/tmp/work/qga.sock"
    plan.guest_agent_socket;
  assert_equal_string "qemu_binary" "qemu-system-x86_64" plan.qemu_binary;
  assert_equal_int "qemu_argv length" 4 (Array.length plan.qemu_argv);
  assert_equal_string "qemu_argv[0]" "-name" plan.qemu_argv.(0);
  assert_equal_int "runs length" 1 (List.length plan.runs);
  (match plan.runs with
  | [ run ] ->
      assert_equal_string "run exec[0]" "virtiofsd" run.exec.(0);
      assert_equal_string "run env[0]" "FOO=bar" run.env.(0);
      assert_equal_string "run dir" "/tmp/work" run.dir
  | _ -> fail "expected one run");
  assert_equal_int "virtiofs sockets" 1 (List.length plan.virtiofs_sockets);
  assert_equal_int "cleanup files" 2 (List.length plan.cleanup_files);
  assert_equal_int "prepare dirs" 1 (List.length plan.prepare_dirs);
  assert (not plan.incoming)

let test_of_json_malformed () =
  match (try Ok (Virtle_plan.of_json "{ not json") with _ -> Error ()) with
  | Error () -> ()
  | Ok _ -> fail "expected malformed plan to raise"

let run name test =
  Printf.printf "test %s ... %!" name;
  test ();
  Printf.printf "ok\n%!"

let () =
  run "virtle plan parses rendered plan json" test_of_json_fields;
  run "virtle plan rejects malformed json" test_of_json_malformed
