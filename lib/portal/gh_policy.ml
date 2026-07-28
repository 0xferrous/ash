(* Generated from data/gh-policy.json. Do not edit by hand. *)

type operation = Read | Write | Read_write | Unknown

let commands =
  [
    ("agent-task create", Write);
    ("agent-task list", Read);
    ("agent-task view", Read);
    ("alias delete", Write);
    ("alias import", Write);
    ("alias list", Read);
    ("alias set", Write);
    ("api", Read_write);
    ("attestation download", Read);
    ("attestation trusted-root", Read);
    ("attestation verify", Read);
    ("auth login", Write);
    ("auth logout", Write);
    ("auth refresh", Write);
    ("auth setup-git", Write);
    ("auth status", Read);
    ("auth switch", Write);
    ("auth token", Read);
    ("browse", Read);
    ("cache delete", Write);
    ("cache list", Read);
    ("co", Write);
    ("codespace code", Read_write);
    ("codespace cp", Read_write);
    ("codespace create", Write);
    ("codespace delete", Write);
    ("codespace edit", Write);
    ("codespace jupyter", Read_write);
    ("codespace list", Read);
    ("codespace logs", Read);
    ("codespace ports forward", Read_write);
    ("codespace ports visibility", Read_write);
    ("codespace rebuild", Read_write);
    ("codespace ssh", Read_write);
    ("codespace stop", Write);
    ("codespace view", Read);
    ("completion", Read);
    ("config clear-cache", Read_write);
    ("config get", Read);
    ("config list", Read);
    ("config set", Write);
    ("copilot", Read_write);
    ("extension browse", Read_write);
    ("extension create", Write);
    ("extension exec", Read_write);
    ("extension install", Read_write);
    ("extension list", Read);
    ("extension remove", Write);
    ("extension search", Read);
    ("extension upgrade", Read_write);
    ("gist clone", Write);
    ("gist create", Write);
    ("gist delete", Write);
    ("gist edit", Write);
    ("gist list", Read);
    ("gist rename", Write);
    ("gist view", Read);
    ("gpg-key add", Write);
    ("gpg-key delete", Write);
    ("gpg-key list", Read);
    ("issue close", Write);
    ("issue comment", Write);
    ("issue create", Write);
    ("issue delete", Write);
    ("issue develop", Read_write);
    ("issue edit", Write);
    ("issue list", Read);
    ("issue lock", Write);
    ("issue pin", Write);
    ("issue reopen", Write);
    ("issue status", Read);
    ("issue transfer", Write);
    ("issue unlock", Write);
    ("issue unpin", Write);
    ("issue view", Read);
    ("label clone", Write);
    ("label create", Write);
    ("label delete", Write);
    ("label edit", Write);
    ("label list", Read);
    ("org list", Read);
    ("pr checkout", Write);
    ("pr checks", Read);
    ("pr close", Write);
    ("pr comment", Write);
    ("pr create", Write);
    ("pr diff", Read);
    ("pr edit", Write);
    ("pr list", Read);
    ("pr lock", Write);
    ("pr merge", Write);
    ("pr ready", Write);
    ("pr reopen", Write);
    ("pr revert", Write);
    ("pr review", Write);
    ("pr status", Read);
    ("pr unlock", Write);
    ("pr update-branch", Write);
    ("pr view", Read);
    ("preview prompter", Read_write);
    ("project close", Write);
    ("project copy", Read_write);
    ("project create", Write);
    ("project delete", Write);
    ("project edit", Write);
    ("project field-create", Write);
    ("project field-delete", Write);
    ("project field-list", Read);
    ("project item-add", Write);
    ("project item-archive", Write);
    ("project item-create", Write);
    ("project item-delete", Write);
    ("project item-edit", Write);
    ("project item-list", Read);
    ("project link", Write);
    ("project list", Read);
    ("project mark-template", Write);
    ("project unlink", Write);
    ("project view", Read);
    ("release create", Write);
    ("release delete", Write);
    ("release delete-asset", Write);
    ("release download", Read);
    ("release edit", Write);
    ("release list", Read);
    ("release upload", Write);
    ("release verify", Read);
    ("release verify-asset", Read);
    ("release view", Read);
    ("repo archive", Write);
    ("repo autolink create", Write);
    ("repo autolink delete", Write);
    ("repo autolink list", Read);
    ("repo autolink view", Read);
    ("repo clone", Write);
    ("repo create", Write);
    ("repo delete", Write);
    ("repo deploy-key add", Write);
    ("repo deploy-key delete", Write);
    ("repo deploy-key list", Read);
    ("repo edit", Write);
    ("repo fork", Write);
    ("repo gitignore list", Read);
    ("repo gitignore view", Read);
    ("repo license list", Read);
    ("repo license view", Read);
    ("repo list", Read);
    ("repo rename", Write);
    ("repo set-default", Write);
    ("repo sync", Write);
    ("repo unarchive", Write);
    ("repo view", Read);
    ("ruleset check", Read);
    ("ruleset list", Read);
    ("ruleset view", Read);
    ("run cancel", Write);
    ("run delete", Write);
    ("run download", Read);
    ("run list", Read);
    ("run rerun", Write);
    ("run view", Read);
    ("run watch", Read);
    ("search code", Read);
    ("search commits", Read);
    ("search issues", Read);
    ("search prs", Read);
    ("search repos", Read);
    ("secret delete", Write);
    ("secret list", Read);
    ("secret set", Write);
    ("ssh-key add", Write);
    ("ssh-key delete", Write);
    ("ssh-key list", Read);
    ("status", Read);
    ("variable delete", Write);
    ("variable get", Read);
    ("variable list", Read);
    ("variable set", Write);
    ("workflow disable", Write);
    ("workflow enable", Write);
    ("workflow list", Read);
    ("workflow run", Write);
    ("workflow view", Read);
  ]

let roots =
  commands
  |> List.filter_map (fun (command, _) ->
      match String.split_on_char ' ' command with
      | root :: _ -> Some root
      | [] -> None)
  |> List.sort_uniq String.compare

let prefixes =
  commands
  |> List.concat_map (fun (command, _) ->
      let parts = String.split_on_char ' ' command in
      let rec loop acc current = function
        | [] -> List.rev acc
        | part :: rest ->
            let current = if current = "" then part else current ^ " " ^ part in
            loop (current :: acc) current rest
      in
      loop [] "" parts)
  |> List.sort_uniq String.compare

let classify argv =
  let rec from_root = function
    | [] -> []
    | arg :: rest -> if List.mem arg roots then arg :: rest else from_root rest
  in
  let rec path acc = function
    | [] -> acc
    | arg :: rest when String.starts_with ~prefix:"-" arg -> path acc rest
    | arg :: rest ->
        let candidate = String.concat " " (List.rev (arg :: acc)) in
        if List.mem candidate prefixes then path (arg :: acc) rest else acc
  in
  match path [] (from_root argv) |> List.rev with
  | [] -> Unknown
  | parts ->
      List.assoc_opt (String.concat " " parts) commands
      |> Option.value ~default:Unknown
