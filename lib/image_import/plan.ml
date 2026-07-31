type entry_kind = Dir | File | Symlink

type entry = {
  source : string;
  target : string;
  kind : entry_kind;
  size : int64;
  mode : int;
  uid : int;
  gid : int;
  mtime : float;
  link_target : string option;
}

let compare_entry a b =
  match Int.compare (String.length a.target) (String.length b.target) with
  | 0 -> String.compare a.target b.target
  | c -> c

let dedup_by_target target_of entries =
  let seen = Hashtbl.create (max 16 (List.length entries)) in
  let rec loop acc = function
    | [] -> List.rev acc
    | x :: xs ->
        let target = target_of x in
        if Hashtbl.mem seen target then loop acc xs
        else (
          Hashtbl.add seen target ();
          loop (x :: acc) xs)
  in
  loop [] entries
