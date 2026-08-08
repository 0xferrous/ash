(* Plan parsing and guest-agent tests for lib/ash/virtle_plan.ml. Pure: no
   FFI library required, so these always run under plain dune test. *)

open Ash

let fail msg = failwith msg

let assert_equal_int label expected actual =
  if expected <> actual then
    fail (Printf.sprintf "%s: expected %d got %d" label expected actual)

let assert_equal_string label expected actual =
  if expected <> actual then
    fail (Printf.sprintf "%s: expected %S got %S" label expected actual)

let assert_bool label expected actual =
  if expected <> actual then
    fail (Printf.sprintf "%s: expected %b got %b" label expected actual)

let contains haystack needle =
  let hlen = String.length haystack and nlen = String.length needle in
  let rec loop i =
    i + nlen <= hlen && (String.sub haystack i nlen = needle || loop (i + 1))
  in
  nlen = 0 || loop 0

let sample =
  {|{
  "cid": 7,
  "incoming": false,
  "stateDir": "/tmp/work",
  "qmpSocket": "/tmp/work/qmp.sock",
  "guestAgentSocket": "/tmp/work/qga.sock",
  "sshReadySocket": "/tmp/work/ready.sock",
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
  assert_equal_string "ssh_ready_socket" "/tmp/work/ready.sock"
    plan.ssh_ready_socket;
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
  match try Ok (Virtle_plan.of_json "{ not json") with _ -> Error () with
  | Error () -> ()
  | Ok _ -> fail "expected malformed plan to raise"

(* A fake guest agent that speaks just enough of the QGA protocol to serve a
   guest-exec with captured output and a guest-shutdown. *)
let socket_read_line fd =
  let buffer = Bytes.create 4096 in
  let rec read acc =
    let n = Unix.read fd buffer 0 (Bytes.length buffer) in
    if n <= 0 then acc
    else
      let chunk = Bytes.sub_string buffer 0 n in
      let acc = acc ^ chunk in
      if String.contains chunk '\n' then acc else read acc
  in
  read ""

let socket_write_line fd payload =
  ignore
    (Unix.write_substring fd (payload ^ "\n") 0 (String.length payload + 1))

let fake_qga_server ~connections socket_path =
  let listener = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Unix.bind listener (Unix.ADDR_UNIX socket_path);
  Unix.listen listener 8;
  let serve () =
    let rec loop remaining =
      if remaining <= 0 then ()
      else
        match Unix.accept listener with
        | fd, _ ->
            let request = socket_read_line fd in
            (try
               if contains request "\"execute\":\"guest-exec-status\"" then
                 socket_write_line fd
                   {|{"return":{"exited":true,"exitcode":0,"out-data":"b3V0","err-data":"ZXJy"}}|}
               else if contains request "\"execute\":\"guest-exec\"" then
                 socket_write_line fd {|{"return":{"pid":7}}|}
               else if contains request "\"execute\":\"guest-shutdown\"" then
                 socket_write_line fd {|{"return":{}}|}
             with Unix.Unix_error _ -> ());
            Unix.close fd;
            loop (remaining - 1)
        | exception Unix.Unix_error _ -> ()
    in
    loop connections
  in
  (Thread.create serve (), listener)

let with_temp_dir f =
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      ("ash-plan-test-" ^ string_of_int (Unix.getpid ()))
  in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error _ -> ());
  Fun.protect
    ~finally:(fun () -> Util.remove_tree ~force:true dir)
    (fun () -> f dir)

let test_qga_guest_exec () =
  with_temp_dir (fun dir ->
      let socket_path = Filename.concat dir "qga.sock" in
      let thread, listener = fake_qga_server ~connections:2 socket_path in
      match
        Virtle_plan.qga_guest_exec ~socket:socket_path ~path:"/bin/echo"
          ~args:[ "hi" ] ~timeout_seconds:5.
      with
      | Error message -> fail ("qga guest-exec: " ^ message)
      | Ok response ->
          assert_bool "exitCode present" true
            (contains response "\"exitCode\":0");
          assert_bool "outData is the base64 of out" true
            (contains response "\"outData\":\"b3V0\"");
          assert_bool "errData is the base64 of err" true
            (contains response "\"errData\":\"ZXJy\"");
          Unix.close listener;
          Thread.join thread)

let test_qga_guest_shutdown () =
  with_temp_dir (fun dir ->
      let socket_path = Filename.concat dir "qga.sock" in
      let thread, listener = fake_qga_server ~connections:1 socket_path in
      assert_bool "guest shutdown accepted" true
        (Virtle_plan.qga_guest_shutdown ~socket:socket_path);
      Unix.close listener;
      Thread.join thread)

let test_ssh_ready_token () =
  with_temp_dir (fun dir ->
      let socket_path = Filename.concat dir "ready.sock" in
      let listener = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
      Unix.bind listener (Unix.ADDR_UNIX socket_path);
      Unix.listen listener 1;
      let server =
        Thread.create
          (fun () ->
            let fd, _ = Unix.accept listener in
            socket_write_line fd "SSH-READY";
            Unix.close fd)
          ()
      in
      Virtle_plan.ssh_ready_token ~socket:socket_path ~timeout_seconds:5.;
      Thread.join server;
      Unix.close listener)

let run name test =
  Printf.printf "test %s ... %!" name;
  test ();
  Printf.printf "ok\n%!"

let () =
  run "virtle plan parses rendered plan json" test_of_json_fields;
  run "virtle plan rejects malformed json" test_of_json_malformed;
  run "qga guest-exec polls until exit" test_qga_guest_exec;
  run "qga guest shutdown" test_qga_guest_shutdown;
  run "ssh ready token" test_ssh_ready_token
