open Cmdliner
open Ash_lib

let version = "0.1.0"

type global_opts = { debug : bool }

type virtle_opts = {
  global : global_opts;
  virtle : string option;
  verbose : bool list;
}

let global_opts debug = { debug }
let virtle_opts global virtle verbose = { global; virtle; verbose }

let spawn opts ssh systemd_ssh_proxy ro_store_socket config flake name user
    profiles print_serial mount_cwd ephemeral attach keep =
  Log.set_debug opts.global.debug;
  if keep && not attach then Log.fatal "--keep requires --attach";
  if ephemeral && ((not attach) || keep) then
    Log.fatal "--ephemeral requires --attach and cannot be used with --keep";
  Virtle.spawn ?virtle:opts.virtle ?ssh ?systemd_ssh_proxy ?ro_store_socket
    ?name ?user ~config_path:config ~flake ~profiles ~print_serial ~mount_cwd
    ~ephemeral ~attach ~keep ~verbose:opts.verbose ()

let list_vms global =
  Log.set_debug global.debug;
  Virtle.print_vm_list ()

let rm_vms global =
  Log.set_debug global.debug;
  Virtle.rm_vms ()

let attach opts name spawn keep =
  Log.set_debug opts.global.debug;
  if keep && not spawn then Log.fatal "--keep requires --spawn";
  Virtle.attach ?virtle:opts.virtle ?name ~spawn ~keep ~verbose:opts.verbose ()

let stop global name =
  Log.set_debug global.debug;
  Virtle.stop ?name ()

let regenerate opts name =
  Log.set_debug opts.global.debug;
  Virtle.regenerate ?virtle:opts.virtle ~name ()

let mount opts mode name spec =
  Log.set_debug opts.global.debug;
  Virtle.hotmount ?virtle:opts.virtle
    ~mode:(Virtle.hotmount_mode_of_string mode)
    ~name ~spec ()

let umount opts name guest_path =
  Log.set_debug opts.global.debug;
  Virtle.hotunmount ?virtle:opts.virtle ~name ~guest_path ()

let virtle_arg =
  Arg.(
    value
    & opt (some string) None
    & info [ "virtle" ]
        ~doc:"Path to virtle. Defaults to ASH_VIRTLE, then PATH." ~docv:"PATH")

let ssh_arg =
  Arg.(
    value
    & opt (some string) None
    & info [ "ssh" ]
        ~doc:
          "Override path to ssh. Defaults to the selected NixOS config's \
           pkgs.openssh."
        ~docv:"PATH")

let systemd_ssh_proxy_arg =
  Arg.(
    value
    & opt (some string) None
    & info [ "systemd-ssh-proxy" ]
        ~doc:
          "Override path to systemd-ssh-proxy. Defaults to the selected NixOS \
           config's systemd package."
        ~docv:"PATH")

let ro_store_socket_arg =
  Arg.(
    value
    & opt (some string) None
    & info [ "ro-store-socket" ]
        ~doc:
          "Use an existing virtiofs daemon socket for the read-only /nix/store \
           mount instead of starting ash's own ro-store virtiofsd."
        ~docv:"PATH")

let config_arg =
  Arg.(
    value
    & opt string "~/.agent-box.toml"
    & info [ "config"; "c" ] ~doc:"Agent-box style config file." ~docv:"CONFIG")

let flake_arg =
  Arg.(
    required
    & opt (some string) None
    & info [ "flake"; "f" ]
        ~doc:"Flake reference in the form FLAKE#HOST, e.g. ../my-nix#agent."
        ~docv:"FLAKE#HOST")

let name_arg =
  Arg.(
    value
    & opt (some string) None
    & info [ "name" ] ~doc:"VM/state name. Defaults to <cwd>-<timestamp>."
        ~docv:"NAME")

let user_arg =
  Arg.(
    value
    & opt (some string) None
    & info [ "user"; "u" ]
        ~doc:
          "Guest SSH user. Defaults to runtime.qemu.ssh_user from config, then \
           agent."
        ~docv:"USER")

let profiles_arg =
  Arg.(
    value & opt_all string []
    & info [ "profile"; "p" ]
        ~doc:"Profile whose mounts should be added. Repeatable." ~docv:"PROFILE")

let verbose_arg =
  Arg.(
    value & flag_all
    & info [ "verbose"; "v" ]
        ~doc:
          "Increase verbosity. For spawn, passed to virtle; for attach, passed \
           to ssh. Repeatable.")

let print_serial_arg =
  Arg.(
    value & flag
    & info [ "print-serial" ]
        ~doc:"Print guest kernel/init serial output while booting.")

let mount_cwd_arg =
  Arg.(
    value & flag
    & info [ "mount-cwd" ]
        ~doc:
          "Mount the current host working directory under the guest workspace.")

let ephemeral_arg =
  Arg.(
    value & flag
    & info [ "ephemeral" ]
        ~doc:
          "Remove the VM state directory after the launched SSH/VM session \
           exits.")

let attach_flag =
  Arg.(
    value & flag
    & info [ "attach" ]
        ~doc:"Attach after spawning. Without --keep, the VM stops on SSH exit.")

let keep_flag =
  Arg.(
    value & flag
    & info [ "keep" ]
        ~doc:"Keep a VM running after an attached spawned session exits.")

let spawn_flag =
  Arg.(
    value & flag
    & info [ "spawn" ]
        ~doc:"For attach, spawn the named stopped VM if it is not running.")

let debug_arg =
  Arg.(
    value & flag
    & info [ "debug" ]
        ~doc:"Enable ash debug logging. Can also be enabled with ASH_LOG=debug.")

let global_opts_arg = Term.(const global_opts $ debug_arg)

let virtle_opts_arg =
  Term.(const virtle_opts $ global_opts_arg $ virtle_arg $ verbose_arg)

let spawn_cmd =
  Cmd.v
    (Cmd.info "spawn" ~doc:"spawn an agent VM")
    Term.(
      const spawn $ virtle_opts_arg $ ssh_arg $ systemd_ssh_proxy_arg
      $ ro_store_socket_arg $ config_arg $ flake_arg $ name_arg $ user_arg
      $ profiles_arg $ print_serial_arg $ mount_cwd_arg $ ephemeral_arg
      $ attach_flag $ keep_flag)

let attach_name_arg =
  Arg.(
    value
    & pos 0 (some string) None
    & info []
        ~doc:
          "VM/state name. If omitted, attach requires exactly one running VM."
        ~docv:"NAME")

let attach_cmd =
  Cmd.v
    (Cmd.info "attach" ~doc:"ssh into a running VM")
    Term.(
      const attach $ virtle_opts_arg $ attach_name_arg $ spawn_flag $ keep_flag)

let ls_cmd =
  Cmd.v
    (Cmd.info "ls" ~doc:"list ash VM state directories")
    Term.(const list_vms $ global_opts_arg)

let regenerate_name_arg =
  Arg.(
    required
    & pos 0 (some string) None
    & info [] ~doc:"VM/state name." ~docv:"NAME")

let regenerate_cmd =
  Cmd.v
    (Cmd.info "regenerate" ~doc:"regenerate a VM manifest from saved ash.toml")
    Term.(const regenerate $ virtle_opts_arg $ regenerate_name_arg)

let mount_name_arg =
  Arg.(
    required
    & pos 0 (some string) None
    & info [] ~doc:"VM/state name." ~docv:"NAME")

let mount_mode_arg =
  Arg.(
    value & opt string "rw"
    & info [ "mode"; "m" ] ~doc:"Mount mode: ro or rw." ~docv:"MODE")

let mount_spec_arg =
  Arg.(
    required
    & pos 1 (some string) None
    & info []
        ~doc:
          "Mount spec HOST_PATH[:GUEST_PATH]. A guest path starting with ~ is \
           resolved relative to the guest SSH user's home. If omitted, \
           GUEST_PATH defaults to ~/$(basename HOST_PATH)."
        ~docv:"HOST_PATH[:GUEST_PATH]")

let mount_cmd =
  Cmd.v
    (Cmd.info "mount" ~doc:"hot-mount a host directory into a running VM")
    Term.(
      const mount $ virtle_opts_arg $ mount_mode_arg $ mount_name_arg
      $ mount_spec_arg)

let umount_guest_path_arg =
  Arg.(
    required
    & pos 1 (some string) None
    & info []
        ~doc:
          "Guest mount path to unmount. A path starting with ~ is resolved \
           relative to the guest SSH user's home."
        ~docv:"GUEST_PATH")

let umount_cmd =
  Cmd.v
    (Cmd.info "umount" ~doc:"unmount a hot-mounted directory from a running VM")
    Term.(
      const umount $ virtle_opts_arg $ mount_name_arg $ umount_guest_path_arg)

let stop_name_arg =
  Arg.(
    value
    & pos 0 (some string) None
    & info []
        ~doc:"VM/state name. If omitted, stop requires exactly one running VM."
        ~docv:"NAME")

let stop_cmd =
  Cmd.v
    (Cmd.info "stop" ~doc:"stop an ash background VM")
    Term.(const stop $ global_opts_arg $ stop_name_arg)

let rm_cmd =
  Cmd.v
    (Cmd.info "rm" ~doc:"select and delete ash VM state directories")
    Term.(const rm_vms $ global_opts_arg)

let main_cmd =
  let doc = "spawn agent VMs with virtle" in
  let man =
    [
      `S Manpage.s_description;
      `P
        "ash generates a virtle manifest from an agent-box style config, a \
         NixOS flake host, and selected profiles, then launches virtle.";
      `S "GLOBAL OPTIONS";
      `P
        "The options --debug, --virtle=PATH, and -v/--verbose are shared by \
         commands that use them.";
      `S Manpage.s_examples;
      `Pre "ash spawn -p rust -p go -f ../my-nix#agent";
      `Pre "ash attach rustbox";
      `Pre "ash attach --virtle ./result/bin/virtle rustbox";
    ]
  in
  Cmd.group
    (Cmd.info "ash" ~version ~doc ~man)
    [
      spawn_cmd;
      attach_cmd;
      mount_cmd;
      umount_cmd;
      stop_cmd;
      regenerate_cmd;
      ls_cmd;
      rm_cmd;
    ]

let () = exit (Cmd.eval main_cmd)
