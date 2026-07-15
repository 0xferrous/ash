type action = { name : string; path : string; args : string list }
type result = { action : string; output : string; exit_code : int option }

let params action =
  `Assoc
    [
      ("path", `String action.path);
      ("args", `List (List.map (fun arg -> `String arg) action.args));
      ("captureOutput", `Bool true);
    ]
  |> Yojson.Safe.to_string

let field_value ~field convert text =
  let rec find = function
    | `Assoc fields -> (
        match Option.bind (List.assoc_opt field fields) convert with
        | Some value -> Some value
        | None -> fields |> List.find_map (fun (_, value) -> find value))
    | `List values -> List.find_map find values
    | _ -> None
  in
  try Yojson.Safe.from_string text |> find with Yojson.Json_error _ -> None

let int_field ~field =
  field_value ~field (function
    | `Int value -> Some value
    | `Intlit value -> int_of_string_opt value
    | _ -> None)

let string_field ~field =
  field_value ~field (function `String value -> Some value | _ -> None)

let decode_base64 text =
  match Base64.decode ~pad:true text with
  | Ok decoded -> Some decoded
  | Error _ -> None

let output_data text =
  Option.bind (string_field ~field:"outData" text) decode_base64

let result action output =
  {
    action = action.name;
    output;
    exit_code = int_field ~field:"exitCode" output;
  }

let ssh_stats_action =
  let script =
    {sh|
PATH=/run/current-system/sw/bin:/bin

connections=$(LC_ALL=C ss --vsock -H -n state established |
  awk '$1 == "v_str" && $4 ~ /:22$/ { n++ } END { print n + 0 }')
ptys=$(who |
  awk '$2 ~ /^pts\// && $NF == "(UNKNOWN)" { n++ } END { print n + 0 }')
printf '%s %s\n' "$connections" "$ptys"
|sh}
  in
  {
    path = "/run/current-system/sw/bin/sh";
    args = [ "-c"; script; "ash-ssh-stats" ];
    name = "ash-ssh-stats";
  }

let shell_action ?(args = []) ~name script =
  {
    path = "/run/current-system/sw/bin/sh";
    args = [ "-c"; script; name ] @ args;
    name;
  }

let install_mountpoint_script =
  {sh|
install_mountpoint() {
  path=$1
  parent=$(dirname "$path")
  while [ ! -e "$parent" ] && [ "$parent" != / ]; do
    parent=$(dirname "$parent")
  done

  owner=$(stat -c %u "$parent")
  group=$(stat -c %g "$parent")
  install -d -o "$owner" -g "$group" "$path"
}
|sh}

(* QGA ACTION SCRIPT: mount a virtiofs tag at its target path. *)
let mount_virtiofs_action ~name ~tag ~target ~read_only =
  let script =
    {sh|
set -eu
PATH=/run/current-system/sw/bin:/bin

tag=$1
target=$2
read_only=$3

if mountpoint -q "$target"; then
  exit 42
fi

install_mountpoint "$target"
if [ "$read_only" = 1 ]; then
  mount -t virtiofs -o ro -- "$tag" "$target"
else
  mount -t virtiofs -- "$tag" "$target"
fi
|sh}
  in
  shell_action ~name
    ~args:[ tag; target; (if read_only then "1" else "0") ]
    (install_mountpoint_script ^ script)

(* QGA ACTION SCRIPT: mount ash's hotmounts virtiofs staging share and bind one
   staged entry to the requested guest target. *)
let hotmount_action ~name ~read_only ~hotmounts_guest_dir ~source_name
    ~guest_path =
  let source = Filename.concat hotmounts_guest_dir source_name in
  let script =
    {sh|
set -eu
PATH=/run/current-system/sw/bin:/bin

hot=$1
source=$2
target=$3
read_only=$4

install -d "$hot"
if ! mountpoint -q "$hot"; then
  mount -t virtiofs -- hotmounts "$hot"
fi

if mountpoint -q "$target"; then
  exit 42
fi

install_mountpoint "$target"
mount --bind "$source" "$target"
if [ "$read_only" = 1 ]; then
  mount -o remount,bind,ro "$target"
fi
|sh}
  in
  shell_action ~name
    ~args:
      [
        hotmounts_guest_dir;
        source;
        guest_path;
        (if read_only then "1" else "0");
      ]
    (install_mountpoint_script ^ script)

(* QGA ACTION SCRIPT: unmount a guest hotmount target. *)
let unmount_action ~name ~guest_path =
  let script =
    {sh|
set -eu
PATH=/run/current-system/sw/bin:/bin

target=$1

if ! mountpoint -q "$target"; then
  rmdir "$target" 2>/dev/null || true
  exit 42
fi

umount "$target"
rmdir "$target" 2>/dev/null || true
|sh}
  in
  shell_action ~name ~args:[ guest_path ] script

(* QGA ACTION SCRIPT: install ash's SSH public key for autoprovisioning. *)
let install_ssh_key_action ~name ~user ~target ~authorized_key =
  let script =
    {sh|
set -eu
PATH=/run/current-system/sw/bin:/bin

auth=$1
key=$2
owner=$3

dir=$(dirname "$auth")
mkdir -p "$dir"
chown -- "$owner" "$dir"
chmod 700 "$dir"

touch "$auth"
if ! grep -qxF -- "$key" "$auth"; then
  printf '%s\n' "$key" >> "$auth"
fi

chown -- "$owner" "$auth"
chmod 600 "$auth"
|sh}
  in
  shell_action ~name ~args:[ target; authorized_key; user ^ ":users" ] script
