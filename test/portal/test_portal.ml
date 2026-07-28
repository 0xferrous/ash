module Portal = Agent_portal

let fail message = failwith message
let assert_true label value = if not value then fail label

let assert_equal label expected actual =
  if expected <> actual then
    fail (Printf.sprintf "%s: expected %S, got %S" label expected actual)

let roundtrip_request request =
  request |> Portal.Protocol.request_to_msgpack |> Msgpck.String.to_string
  |> Bytes.unsafe_to_string |> Msgpck.String.read |> snd
  |> Portal.Protocol.request_of_msgpack

let test_protocol_roundtrip () =
  let request =
    Portal.Protocol.
      {
        version = 1;
        id = 42L;
        method_ =
          Gh_exec
            {
              argv = [ "pr"; "view"; "123" ];
              reason = Some "inspect PR";
              require_approval = false;
            };
      }
  in
  match (roundtrip_request request).method_ with
  | Portal.Protocol.Gh_exec { argv; reason; require_approval } ->
      assert_true "gh argv roundtrip" (argv = [ "pr"; "view"; "123" ]);
      assert_true "gh reason roundtrip" (reason = Some "inspect PR");
      assert_true "gh approval roundtrip" (not require_approval)
  | _ -> fail "wrong request variant after roundtrip"

let test_rust_u128_timestamp () =
  let bytes = Bytes.make 16 '\000' in
  Bytes.set_int64_be bytes 8 1234L;
  let value =
    Portal.Protocol.map
      [
        ("version", Msgpck.Int 1);
        ("id", Msgpck.Int 1);
        ("ok", Msgpck.Bool true);
        ( "result",
          Portal.Protocol.map
            [
              ("type", Msgpck.String "Pong");
              ( "data",
                Portal.Protocol.map
                  [ ("now_unix_ms", Msgpck.Bytes (Bytes.to_string bytes)) ] );
            ] );
        ("error", Msgpck.Nil);
      ]
  in
  match (Portal.Protocol.response_of_msgpack value).result with
  | Some (Portal.Protocol.Pong { now_unix_ms }) ->
      assert_true "u128 timestamp" (now_unix_ms = 1234L)
  | _ -> fail "wrong pong response"

let temp_dir prefix =
  let path = Filename.temp_file prefix "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  path

let test_config () =
  let directory = temp_dir "portal-config" in
  let path = Filename.concat directory "config.toml" in
  let oc = open_out path in
  output_string oc
    {|
[portal]
socket_path = "/tmp/test-portal.sock"

[portal.policy.defaults]
clipboard_read_image = "ask"
gh_exec = "ask_for_all"

[portal.policy.containers."abc123"]
clipboard_read_image = "deny"
gh_exec = "deny_all"
|};
  close_out oc;
  let config = Portal.Config.load ~path () in
  assert_equal "socket path" "/tmp/test-portal.sock" config.socket_path;
  let policy = Portal.Config.policy_for_container config (Some "abc123") in
  assert_true "container clipboard policy"
    (policy.clipboard_read_image = Portal.Config.Deny);
  assert_true "container gh policy" (policy.gh_exec = Portal.Config.Deny_all);
  Unix.unlink path;
  Unix.rmdir directory

let wait_for_socket path =
  let rec loop attempts =
    if Sys.file_exists path then ()
    else if attempts = 0 then fail ("socket did not appear: " ^ path)
    else (
      Unix.sleepf 0.02;
      loop (attempts - 1))
  in
  loop 100

let test_host_roundtrip () =
  let directory = temp_dir "portal-host" in
  let socket_path = Filename.concat directory "portal.sock" in
  let config =
    {
      (Portal.Config.defaults ()) with
      socket_path;
      defaults =
        {
          clipboard_read_image = Portal.Config.Deny;
          gh_exec = Portal.Config.Deny_all;
        };
    }
  in
  match Unix.fork () with
  | 0 -> ( try Portal.Server.run config socket_path with _ -> exit 1)
  | pid ->
      Fun.protect
        ~finally:(fun () ->
          (try Unix.kill pid Sys.sigterm with Unix.Unix_error _ -> ());
          ignore (Unix.waitpid [] pid);
          (try Unix.unlink socket_path with Unix.Unix_error _ -> ());
          Unix.rmdir directory)
        (fun () ->
          wait_for_socket socket_path;
          let client = Portal.Client.create ~socket:socket_path () in
          match Portal.Client.request client Portal.Protocol.Ping with
          | Portal.Protocol.Pong _ -> ()
          | _ -> fail "ping returned wrong response")

let test_gh_policy () =
  assert_true "gh pr view is read"
    (Portal.Gh_policy.classify [ "pr"; "view"; "123" ] = Portal.Gh_policy.Read);
  assert_true "gh pr merge is write"
    (Portal.Gh_policy.classify [ "pr"; "merge"; "123" ] = Portal.Gh_policy.Write)

let run name test =
  Printf.printf "test %s ... %!" name;
  test ();
  print_endline "ok"

let () =
  run "protocol roundtrip" test_protocol_roundtrip;
  run "Rust u128 timestamp compatibility" test_rust_u128_timestamp;
  run "portal config" test_config;
  run "host roundtrip" test_host_roundtrip;
  run "gh policy" test_gh_policy
