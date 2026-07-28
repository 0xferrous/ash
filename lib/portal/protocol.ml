exception Decode_error of string

type request_method =
  | Ping
  | Clipboard_read_image of { reason : string option }
  | Exec of {
      argv : string list;
      reason : string option;
      cwd : string option;
      env : (string * string) list option;
    }

type request = { version : int; id : int64; method_ : request_method }
type exec_result = { exit_code : int; stdout : string; stderr : string }

type response_result =
  | Pong of { now_unix_ms : int64 }
  | Clipboard_image of { mime : string; bytes : string }
  | Exec_result of exec_result

type portal_error = { code : string; message : string }

type response = {
  version : int;
  id : int64;
  ok : bool;
  result : response_result option;
  error : portal_error option;
}

let key value = Msgpck.String value

let map fields =
  Msgpck.Map (List.map (fun (name, value) -> (key name, value)) fields)

let nil_or f = function None -> Msgpck.Nil | Some value -> f value
let string value = Msgpck.String value
let strings values = Msgpck.List (List.map string values)
let integer value = Msgpck.Int value

let int64 value =
  if value >= 0L then Msgpck.Uint64 value else Msgpck.Int64 value

let field name = function
  | Msgpck.Map fields -> List.assoc_opt (key name) fields
  | _ -> None

let required name value =
  match field name value with
  | Some value -> value
  | None -> raise (Decode_error ("missing field: " ^ name))

let as_string = function
  | Msgpck.String value -> value
  | _ -> raise (Decode_error "expected string")

let as_bool = function
  | Msgpck.Bool value -> value
  | _ -> raise (Decode_error "expected boolean")

let as_int64 = function
  | Msgpck.Int value -> Int64.of_int value
  | Msgpck.Int32 value -> Int64.of_int32 value
  | Msgpck.Uint32 value -> Int64.logand (Int64.of_int32 value) 0xffff_ffffL
  | Msgpck.Int64 value | Msgpck.Uint64 value -> value
  | Msgpck.Bytes value when String.length value = 16 ->
      let result = ref 0L in
      for index = 8 to 15 do
        result :=
          Int64.logor
            (Int64.shift_left !result 8)
            (Int64.of_int (Char.code value.[index]))
      done;
      !result
  | _ -> raise (Decode_error "expected integer")

let as_int value = as_int64 value |> Int64.to_int

let as_list convert = function
  | Msgpck.List values -> List.map convert values
  | _ -> raise (Decode_error "expected array")

let as_option convert = function
  | Msgpck.Nil -> None
  | value -> Some (convert value)

let as_bytes = function
  | Msgpck.Bytes value | Msgpck.String value -> value
  | Msgpck.List values ->
      values
      |> List.map (fun value -> as_int value |> Char.chr)
      |> List.to_seq |> String.of_seq
  | _ -> raise (Decode_error "expected bytes")

let request_to_msgpack request =
  let method_name, params =
    match request.method_ with
    | Ping -> ("ping", None)
    | Clipboard_read_image { reason } ->
        ("clipboard.read_image", Some [ ("reason", nil_or string reason) ])
    | Exec { argv; reason; cwd; env } ->
        let environment values =
          map (List.map (fun (name, value) -> (name, string value)) values)
        in
        ( "exec",
          Some
            [
              ("argv", strings argv);
              ("reason", nil_or string reason);
              ("cwd", nil_or string cwd);
              ("env", nil_or environment env);
            ] )
  in
  map
    ([
       ("version", integer request.version);
       ("id", int64 request.id);
       ("method", string method_name);
     ]
    @ match params with None -> [] | Some fields -> [ ("params", map fields) ])

let request_of_msgpack value =
  let version = required "version" value |> as_int in
  let id = required "id" value |> as_int64 in
  let method_name = required "method" value |> as_string in
  let params = field "params" value |> Option.value ~default:(map []) in
  let optional_string name =
    Option.bind (field name params) (as_option as_string)
  in
  let argv () = required "argv" params |> as_list as_string in
  let method_ =
    match method_name with
    | "ping" -> Ping
    | "clipboard.read_image" ->
        Clipboard_read_image { reason = optional_string "reason" }
    | "exec" ->
        let env =
          match field "env" params with
          | None | Some Msgpck.Nil -> None
          | Some (Msgpck.Map fields) ->
              Some
                (List.map
                   (fun (name, value) -> (as_string name, as_string value))
                   fields)
          | Some _ -> raise (Decode_error "exec env must be a map")
        in
        Exec
          {
            argv = argv ();
            reason = optional_string "reason";
            cwd = optional_string "cwd";
            env;
          }
    | name -> raise (Decode_error ("unknown portal method: " ^ name))
  in
  { version; id; method_ }

let exec_result_to_msgpack result =
  map
    [
      ("exit_code", integer result.exit_code);
      ("stdout", Msgpck.Bytes result.stdout);
      ("stderr", Msgpck.Bytes result.stderr);
    ]

let result_to_msgpack = function
  | Pong { now_unix_ms } ->
      map
        [
          ("type", string "Pong");
          ("data", map [ ("now_unix_ms", int64 now_unix_ms) ]);
        ]
  | Clipboard_image { mime; bytes } ->
      map
        [
          ("type", string "ClipboardImage");
          ("data", map [ ("mime", string mime); ("bytes", Msgpck.Bytes bytes) ]);
        ]
  | Exec_result result ->
      map [ ("type", string "Exec"); ("data", exec_result_to_msgpack result) ]

let response_to_msgpack response =
  let error =
    match response.error with
    | None -> Msgpck.Nil
    | Some error ->
        map [ ("code", string error.code); ("message", string error.message) ]
  in
  map
    [
      ("version", integer response.version);
      ("id", int64 response.id);
      ("ok", Msgpck.Bool response.ok);
      ("result", nil_or result_to_msgpack response.result);
      ("error", error);
    ]

let exec_result_of_msgpack value =
  {
    exit_code = required "exit_code" value |> as_int;
    stdout = required "stdout" value |> as_bytes;
    stderr = required "stderr" value |> as_bytes;
  }

let response_of_msgpack value =
  let version = required "version" value |> as_int in
  let id = required "id" value |> as_int64 in
  let ok = required "ok" value |> as_bool in
  let result =
    match field "result" value with
    | None | Some Msgpck.Nil -> None
    | Some result ->
        let kind = required "type" result |> as_string in
        let data = required "data" result in
        Some
          (match kind with
          | "Pong" ->
              Pong { now_unix_ms = required "now_unix_ms" data |> as_int64 }
          | "ClipboardImage" ->
              Clipboard_image
                {
                  mime = required "mime" data |> as_string;
                  bytes = required "bytes" data |> as_bytes;
                }
          | "Exec" -> Exec_result (exec_result_of_msgpack data)
          | name -> raise (Decode_error ("unknown response type: " ^ name)))
  in
  let error =
    match field "error" value with
    | None | Some Msgpck.Nil -> None
    | Some error ->
        Some
          {
            code = required "code" error |> as_string;
            message = required "message" error |> as_string;
          }
  in
  { version; id; ok; result; error }

let ok id result =
  { version = 1; id; ok = true; result = Some result; error = None }

let error id code message =
  { version = 1; id; ok = false; result = None; error = Some { code; message } }
