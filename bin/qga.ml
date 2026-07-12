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

let int_field ~field text =
  let int_value = function
    | `Int value -> Some value
    | `Intlit value -> int_of_string_opt value
    | _ -> None
  in
  let rec find = function
    | `Assoc fields -> (
        match Option.bind (List.assoc_opt field fields) int_value with
        | Some value -> Some value
        | None -> fields |> List.find_map (fun (_, value) -> find value))
    | `List values -> List.find_map find values
    | _ -> None
  in
  try Yojson.Safe.from_string text |> find with Yojson.Json_error _ -> None

let result action output =
  {
    action = action.name;
    output;
    exit_code = int_field ~field:"exitCode" output;
  }

let shell_action ?(args = []) ~name script =
  {
    path = "/run/current-system/sw/bin/sh";
    args = [ "-c"; script; name ] @ args;
    name;
  }

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

install -d "$target"
if [ "$read_only" = 1 ]; then
  mount -t virtiofs -o ro -- "$tag" "$target"
else
  mount -t virtiofs -- "$tag" "$target"
fi
|sh}
  in
  shell_action ~name
    ~args:[ tag; target; (if read_only then "1" else "0") ]
    script

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

install -d "$target"
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
    script

(* QGA ACTION SCRIPT: unmount a guest hotmount target. *)
let unmount_action ~name ~guest_path =
  let script =
    {sh|
set -eu
PATH=/run/current-system/sw/bin:/bin

target=$1

if ! mountpoint -q "$target"; then
  exit 42
fi

umount "$target"
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
