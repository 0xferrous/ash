open Cmdliner

let version = "0.1.0"

let spawn debug virtie ssh systemd_ssh_proxy config flake host name user profiles print_serial mount_cwd verbose =
  Log.set_debug debug;
  Virtie.spawn ?virtie ?ssh ?systemd_ssh_proxy ?name ?user ~config_path:config ~flake ~host ~profiles ~print_serial ~mount_cwd ~verbose ()

let virtie_arg =
  Arg.(value & opt (some string) None & info [ "virtie" ] ~doc:"Path to virtie. Defaults to ASH_VIRTIE, then PATH." ~docv:"PATH")

let ssh_arg =
  Arg.(value & opt (some string) None & info [ "ssh" ] ~doc:"Override path to ssh. Defaults to the selected NixOS config's pkgs.openssh." ~docv:"PATH")

let systemd_ssh_proxy_arg =
  Arg.(value & opt (some string) None & info [ "systemd-ssh-proxy" ] ~doc:"Override path to systemd-ssh-proxy. Defaults to the selected NixOS config's systemd package." ~docv:"PATH")

let config_arg =
  Arg.(value & opt string "~/.agent-box.toml" & info [ "config"; "c" ] ~doc:"Agent-box style config file." ~docv:"CONFIG")

let flake_arg =
  Arg.(required & opt (some string) None & info [ "flake"; "f" ] ~doc:"Flake directory or flake.nix path containing the NixOS host config." ~docv:"FLAKE")

let host_arg =
  Arg.(required & opt (some string) None & info [ "host" ] ~doc:"Host name under nixosConfigurations." ~docv:"HOST")

let name_arg =
  Arg.(value & opt (some string) None & info [ "name" ] ~doc:"VM/state name. Defaults to <cwd>-<timestamp>." ~docv:"NAME")

let user_arg =
  Arg.(value & opt (some string) None & info [ "user"; "u" ] ~doc:"Guest SSH user. Defaults to runtime.qemu.ssh_user from config, then agent." ~docv:"USER")

let profiles_arg =
  Arg.(value & opt_all string [] & info [ "profile"; "p" ] ~doc:"Profile whose mounts should be added. Repeatable." ~docv:"PROFILE")

let verbose_arg =
  Arg.(value & flag_all & info [ "verbose"; "v" ] ~doc:"Increase virtie verbosity. Repeatable.")

let print_serial_arg =
  Arg.(value & flag & info [ "print-serial" ] ~doc:"Print guest kernel/init serial output while booting.")

let mount_cwd_arg =
  Arg.(value & flag & info [ "mount-cwd" ] ~doc:"Mount the current host working directory under the guest workspace.")

let debug_arg =
  Arg.(value & flag & info [ "debug" ] ~doc:"Enable ash debug logging. Can also be enabled with ASH_LOG=debug.")

let spawn_cmd =
  Cmd.v (Cmd.info "spawn" ~doc:"spawn an agent VM")
    Term.(const spawn $ debug_arg $ virtie_arg $ ssh_arg $ systemd_ssh_proxy_arg $ config_arg $ flake_arg $ host_arg $ name_arg $ user_arg $ profiles_arg $ print_serial_arg $ mount_cwd_arg $ verbose_arg)

let main_cmd =
  let doc = "spawn agent VMs with virtie" in
  let man =
    [
      `S Manpage.s_description;
      `P "ash generates a virtie manifest from an agent-box style config, a NixOS flake host, and selected profiles, then launches virtie.";
      `S Manpage.s_examples;
      `Pre "ash spawn -p rust -p go -f ../my-nix/flake.nix --host agent";
    ]
  in
  Cmd.group (Cmd.info "ash" ~version ~doc ~man) [ spawn_cmd ]

let () = exit (Cmd.eval main_cmd)
