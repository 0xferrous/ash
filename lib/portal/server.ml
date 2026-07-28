external peer_credentials : Unix.file_descr -> int * int * int
  = "agent_portal_peer_credentials"

type identity = {
  pid : int;
  uid : int;
  gid : int;
  container_id : string option;
}

type bucket = { mutable tokens : float; mutable updated_at : float }

type state = {
  config : Config.t;
  rate_mutex : Mutex.t;
  buckets : (string, bucket) Hashtbl.t;
  inflight : int Atomic.t;
  prompts : int Atomic.t;
}

let read_file path =
  try Some (In_channel.with_open_bin path In_channel.input_all)
  with Sys_error _ -> None

let find_substring text needle =
  let rec loop index =
    if index + String.length needle > String.length text then None
    else if String.sub text index (String.length needle) = needle then
      Some index
    else loop (index + 1)
  in
  loop 0

let take_hex text start =
  let is_hex = function
    | '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' -> true
    | _ -> false
  in
  let stop = ref start in
  while !stop < String.length text && is_hex text.[!stop] do
    incr stop
  done;
  if !stop = start then None else Some (String.sub text start (!stop - start))

let container_id pid =
  match read_file (Printf.sprintf "/proc/%d/cgroup" pid) with
  | None -> None
  | Some text -> (
      match find_substring text "libpod-" with
      | Some index -> take_hex text (index + 7)
      | None -> (
          match find_substring text "/libpod/" with
          | Some index -> take_hex text (index + 8)
          | None -> None))

let identity socket =
  let pid, uid, gid = peer_credentials socket in
  { pid; uid; gid; container_id = container_id pid }

let rate_key identity =
  Option.value identity.container_id
    ~default:("pid:" ^ string_of_int identity.pid)

let allow_rate state identity =
  Mutex.lock state.rate_mutex;
  Fun.protect
    ~finally:(fun () -> Mutex.unlock state.rate_mutex)
    (fun () ->
      let now = Unix.gettimeofday () in
      let capacity = float (max 1 state.config.rate_burst) in
      let refill_per_second = float state.config.rate_per_minute /. 60. in
      let key = rate_key identity in
      let bucket =
        match Hashtbl.find_opt state.buckets key with
        | Some bucket -> bucket
        | None ->
            let bucket = { tokens = capacity; updated_at = now } in
            Hashtbl.add state.buckets key bucket;
            bucket
      in
      let elapsed = max 0. (now -. bucket.updated_at) in
      bucket.tokens <-
        min capacity (bucket.tokens +. (elapsed *. refill_per_second));
      bucket.updated_at <- now;
      if bucket.tokens < 1. then false
      else (
        bucket.tokens <- bucket.tokens -. 1.;
        true))

let prompt state identity reason =
  match state.config.prompt_command with
  | None -> Error "prompt_command is not configured"
  | Some command ->
      if Atomic.fetch_and_add state.prompts 1 >= state.config.prompt_queue then (
        ignore (Atomic.fetch_and_add state.prompts (-1));
        Error "prompt queue full")
      else
        Fun.protect
          ~finally:(fun () -> ignore (Atomic.fetch_and_add state.prompts (-1)))
          (fun () ->
            let context =
              Printf.sprintf "container=%s pid=%d reason=%s"
                (Option.value identity.container_id ~default:"unknown")
                identity.pid
                (Option.value reason ~default:"(none)")
            in
            let input_path = Filename.temp_file "agent-portal" ".prompt" in
            Fun.protect
              ~finally:(fun () ->
                try Unix.unlink input_path with Unix.Unix_error _ -> ())
              (fun () ->
                let oc = open_out input_path in
                Fun.protect
                  ~finally:(fun () -> close_out oc)
                  (fun () ->
                    Printf.fprintf oc "allow-once (%s)\ndeny (%s)\n" context
                      context);
                let shell =
                  Printf.sprintf "cat %s | %s"
                    (Process.shell_quote input_path)
                    command
                in
                let result =
                  Process.run ~timeout_ms:state.config.prompt_timeout_ms
                    "/bin/sh" [ "-c"; shell ]
                in
                if result.exit_code = 124 then Error "prompt timed out"
                else if result.exit_code <> 0 then
                  Error ("prompt command failed: " ^ result.stderr)
                else
                  Ok
                    (String.starts_with ~prefix:"allow"
                       (String.trim result.stdout))))

let clipboard_image config =
  let wl_paste =
    Process.find_host_binary ~override_env:"AGENT_PORTAL_HOST_WL_PASTE"
      "wl-paste"
  in
  let types =
    Process.run ~timeout_ms:config.Config.request_timeout_ms wl_paste
      [ "--list-types" ]
  in
  if types.exit_code <> 0 then failwith types.stderr;
  let offered =
    String.split_on_char '\n' types.stdout |> List.map String.trim
  in
  let mime =
    match
      List.find_opt (fun mime -> List.mem mime offered) config.allowed_mime
    with
    | Some mime -> mime
    | None -> failwith "clipboard does not contain an allowed image MIME type"
  in
  let image =
    Process.run ~timeout_ms:config.request_timeout_ms wl_paste
      [ "--type"; mime; "--no-newline" ]
  in
  if image.exit_code <> 0 then failwith image.stderr;
  if String.length image.stdout > config.max_clipboard_bytes then
    failwith "clipboard image exceeds configured size limit";
  (mime, image.stdout)

let send socket response =
  Wire.write socket (Protocol.response_to_msgpack response)

let handle state socket =
  let request_id = ref 0L in
  try
    let caller = identity socket in
    let request =
      Wire.read ~timeout_ms:state.config.request_timeout_ms socket
      |> Protocol.request_of_msgpack
    in
    request_id := request.id;
    Logging.info "request id=%Ld pid=%d uid=%d container=%s" request.id
      caller.pid caller.uid
      (Option.value caller.container_id ~default:"(none)");
    if request.version <> 1 then
      send socket
        (Protocol.error request.id "unsupported_version"
           "only protocol version 1 is supported")
    else if not (allow_rate state caller) then
      send socket
        (Protocol.error request.id "rate_limited" "request rate exceeded")
    else
      let policy =
        Config.policy_for_container state.config caller.container_id
      in
      let response =
        match request.method_ with
        | Protocol.Ping ->
            Protocol.ok request.id
              (Protocol.Pong
                 {
                   now_unix_ms = Int64.of_float (Unix.gettimeofday () *. 1000.);
                 })
        | Protocol.Clipboard_read_image { reason } -> (
            let allowed =
              match policy.clipboard_read_image with
              | Config.Allow -> Ok true
              | Config.Deny -> Ok false
              | Config.Ask -> prompt state caller reason
            in
            match allowed with
            | Error message -> Protocol.error request.id "prompt_failed" message
            | Ok false ->
                Protocol.error request.id "denied" "request denied by policy"
            | Ok true -> (
                try
                  let mime, bytes = clipboard_image state.config in
                  Protocol.ok request.id
                    (Protocol.Clipboard_image { mime; bytes })
                with exn ->
                  Protocol.error request.id "clipboard_failed"
                    (Printexc.to_string exn)))
        | Protocol.Exec { argv; reason; cwd; env } -> (
            match prompt state caller reason with
            | Error message -> Protocol.error request.id "prompt_failed" message
            | Ok false ->
                Protocol.error request.id "denied" "request denied by policy"
            | Ok true -> (
                match argv with
                | [] -> Protocol.error request.id "exec_failed" "empty command"
                | command :: args -> (
                    try
                      let binary = Process.find_binary command in
                      Protocol.ok request.id
                        (Protocol.Exec_result
                           (Process.run ?cwd ?env
                              ~timeout_ms:state.config.request_timeout_ms binary
                              args))
                    with exn ->
                      Protocol.error request.id "exec_failed"
                        (Printexc.to_string exn))))
      in
      send socket response
  with exn -> (
    Logging.error "request failed: %s" (Printexc.to_string exn);
    try
      send socket
        (Protocol.error !request_id "invalid_request" (Printexc.to_string exn))
    with _ -> ())

let run config socket_path : unit =
  if not config.Config.enabled then failwith "portal is disabled";
  let socket_directory = Filename.dirname socket_path in
  Process.ensure_dir socket_directory;
  Unix.chmod socket_directory 0o700;
  (if Sys.file_exists socket_path then
     match (Unix.lstat socket_path).st_kind with
     | Unix.S_SOCK -> Unix.unlink socket_path
     | _ -> failwith ("refusing to replace non-socket path: " ^ socket_path));
  let listener = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () ->
      Unix.close listener;
      try Unix.unlink socket_path with Unix.Unix_error _ -> ())
    (fun () ->
      Unix.bind listener (Unix.ADDR_UNIX socket_path);
      Unix.chmod socket_path 0o600;
      Unix.listen listener config.max_inflight;
      Logging.info "agent-portal-host listening on %s" socket_path;
      let state =
        {
          config;
          rate_mutex = Mutex.create ();
          buckets = Hashtbl.create 32;
          inflight = Atomic.make 0;
          prompts = Atomic.make 0;
        }
      in
      while true do
        let socket, _ = Unix.accept listener in
        if Atomic.fetch_and_add state.inflight 1 >= config.max_inflight then (
          ignore (Atomic.fetch_and_add state.inflight (-1));
          send socket
            (Protocol.error 0L "too_busy" "too many in-flight requests");
          Unix.close socket)
        else
          ignore
            (Thread.create
               (fun socket ->
                 Fun.protect
                   ~finally:(fun () ->
                     ignore (Atomic.fetch_and_add state.inflight (-1));
                     try Unix.close socket with Unix.Unix_error _ -> ())
                   (fun () -> handle state socket))
               socket)
      done)
