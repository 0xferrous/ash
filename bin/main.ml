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
    spaces print_serial mount_cwd ephemeral attach keep kitty =
  Log.set_debug opts.global.debug;
  if keep && not attach then Log.fatal "--keep requires --attach";
  if ephemeral && ((not attach) || keep) then
    Log.fatal "--ephemeral requires --attach and cannot be used with --keep";
  Virtle.spawn ?virtle:opts.virtle ?ssh ?systemd_ssh_proxy ?ro_store_socket
    ?name ?user ~config_path:config ?flake ~spaces ~print_serial ~mount_cwd
    ~ephemeral ~attach ~keep ~kitty ~verbose:opts.verbose ()

let list_vms global =
  Log.set_debug global.debug;
  Virtle.print_vm_list ()

let inspect_vm global json name =
  Log.set_debug global.debug;
  Virtle.inspect_vm ~json ~name

let rm_vms global =
  Log.set_debug global.debug;
  Virtle.rm_vms ()

let attach opts name spawn keep kitty =
  Log.set_debug opts.global.debug;
  if keep && not spawn then Log.fatal "--keep requires --spawn";
  Virtle.attach ?virtle:opts.virtle ?name ~spawn ~keep ~kitty
    ~verbose:opts.verbose ()

let resume opts name attach keep =
  Log.set_debug opts.global.debug;
  if keep && not attach then Log.fatal "--keep requires --attach";
  Virtle.resume ?virtle:opts.virtle ~name ~attach ~keep ~verbose:opts.verbose ()

let stop opts name suspend force =
  Log.set_debug opts.global.debug;
  if suspend && force then Log.fatal "--force cannot be used with --suspend";
  if suspend then Virtle.suspend ?virtle:opts.virtle ?name ()
  else Virtle.stop ?name ~force ()

let logs global name follow lines =
  Log.set_debug global.debug;
  if lines < 0 then Log.fatal "--lines must be non-negative";
  Systemd_run.show_user_unit_logs ~name ~follow ~lines

let regenerate opts name =
  Log.set_debug opts.global.debug;
  Virtle.regenerate ?virtle:opts.virtle ~name ()

let mount opts mode name spec =
  Log.set_debug opts.global.debug;
  Virtle.hotmount ?virtle:opts.virtle
    ~mode:(Virtle.hotmount_mode_of_string mode)
    ~name ~spec ()

let copy global recursive verbose source name from_path to_path =
  Log.set_debug global.debug;
  Virtle.copy ~name ~recursive ~verbose ~source ~from_path ~to_path ()

let umount opts name guest_path =
  Log.set_debug opts.global.debug;
  Virtle.hotunmount ?virtle:opts.virtle ~name ~guest_path ()

let mount_space opts name spaces =
  Log.set_debug opts.global.debug;
  Virtle.hotmount_spaces ?virtle:opts.virtle ~name ~spaces ()

let umount_space opts name spaces =
  Log.set_debug opts.global.debug;
  Virtle.hotunmount_spaces ?virtle:opts.virtle ~name ~spaces ()

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
    & opt string (Util.default_ash_config_path ())
    & info [ "config"; "c" ] ~doc:"Ash config file." ~docv:"CONFIG")

let flake_arg =
  Arg.(
    value
    & opt (some string) None
    & info [ "flake"; "f" ]
        ~doc:
          "Flake reference in the form FLAKE#HOST, e.g. ../my-nix#agent. \
           Required for a new VM; defaults to the saved ash-state.toml value \
           for an existing named VM."
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
          "Override the guest SSH user. By default ash evaluates the selected \
           NixOS configuration's services.getty.autologinUser."
        ~docv:"USER")

let spaces_arg =
  Arg.(
    value & opt_all string []
    & info [ "space"; "s" ]
        ~doc:"Space whose mounts should be added. Repeatable." ~docv:"SPACE")

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

let kitty_flag =
  Arg.(
    value & flag
    & info [ "kitty" ]
        ~doc:"Use `kitten ssh` instead of ssh for the attached session.")

let suspend_flag =
  Arg.(
    value & flag
    & info [ "suspend" ]
        ~doc:"For stop, save VM state with virtle suspend instead of stopping.")

let debug_arg =
  Arg.(
    value & flag
    & info [ "debug" ]
        ~doc:"Enable ash debug logging. Can also be enabled with ASH_LOG=debug.")

let global_opts_arg = Term.(const global_opts $ debug_arg)

let virtle_opts_arg =
  Term.(const virtle_opts $ global_opts_arg $ virtle_arg $ verbose_arg)

let spawn_man = Pages.spawn.man

let spawn_cmd =
  Cmd.v
    (Cmd.info "spawn" ~doc:"spawn an agent VM" ~man:spawn_man)
    Term.(
      const spawn $ virtle_opts_arg $ ssh_arg $ systemd_ssh_proxy_arg
      $ ro_store_socket_arg $ config_arg $ flake_arg $ name_arg $ user_arg
      $ spaces_arg $ print_serial_arg $ mount_cwd_arg $ ephemeral_arg
      $ attach_flag $ keep_flag $ kitty_flag)

let attach_name_arg =
  Arg.(
    value
    & pos 0 (some string) None
    & info []
        ~doc:
          "VM/state name. If omitted, attach requires exactly one running VM."
        ~docv:"NAME")

let attach_man = Pages.attach.man

let attach_cmd =
  Cmd.v
    (Cmd.info "attach" ~doc:"ssh into a running VM" ~man:attach_man)
    Term.(
      const attach $ virtle_opts_arg $ attach_name_arg $ spawn_flag $ keep_flag
      $ kitty_flag)

let resume_name_arg =
  Arg.(
    required
    & pos 0 (some string) None
    & info [] ~doc:"VM/state name." ~docv:"NAME")

let resume_man = Pages.resume.man

let resume_cmd =
  Cmd.v
    (Cmd.info "resume" ~doc:"resume a suspended VM" ~man:resume_man)
    Term.(
      const resume $ virtle_opts_arg $ resume_name_arg $ attach_flag $ keep_flag)

let ls_man = Pages.ls.man

let ls_cmd =
  Cmd.v
    (Cmd.info "ls" ~doc:"list ash VM state directories" ~man:ls_man)
    Term.(const list_vms $ global_opts_arg)

let inspect_name_arg =
  Arg.(
    required
    & pos 0 (some string) None
    & info [] ~doc:"VM/state name." ~docv:"NAME")

let inspect_json_flag =
  Arg.(
    value & flag
    & info [ "json" ] ~doc:"Print the complete machine-readable JSON view.")

let inspect_man = Pages.inspect.man

let inspect_cmd =
  Cmd.v
    (Cmd.info "inspect" ~doc:"show detailed VM configuration and state"
       ~man:inspect_man)
    Term.(
      const inspect_vm $ global_opts_arg $ inspect_json_flag $ inspect_name_arg)

let regenerate_name_arg =
  Arg.(
    required
    & pos 0 (some string) None
    & info [] ~doc:"VM/state name." ~docv:"NAME")

let regenerate_man = Pages.regenerate.man

let regenerate_cmd =
  Cmd.v
    (Cmd.info "regenerate" ~doc:"regenerate generated VM files"
       ~man:regenerate_man)
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
           GUEST_PATH defaults to the absolute host path."
        ~docv:"HOST_PATH[:GUEST_PATH]")

let mount_man = Pages.mount.man

let mount_cmd =
  Cmd.v
    (Cmd.info "mount" ~doc:"hot-mount a host directory into a running VM"
       ~man:mount_man)
    Term.(
      const mount $ virtle_opts_arg $ mount_mode_arg $ mount_name_arg
      $ mount_spec_arg)

let copy_recursive_flag =
  Arg.(
    value & flag
    & info [ "recursive"; "r" ] ~doc:"Copy directories recursively.")

let copy_verbose_flag =
  Arg.(
    value & flag
    & info [ "verbose"; "v" ]
        ~doc:"Print the completed host/guest copy operation.")

let copy_source_arg =
  Arg.(
    value
    & opt (enum [ ("host", Virtle.Host); ("guest", Virtle.Guest) ]) Virtle.Host
    & info [ "from" ] ~doc:"Copy from host or guest." ~docv:"host|guest")

let copy_name_arg =
  Arg.(
    required
    & pos 0 (some string) None
    & info [] ~doc:"VM/state name." ~docv:"NAME")

let copy_from_path_arg =
  Arg.(
    required
    & pos 1 (some string) None
    & info [] ~doc:"Source path." ~docv:"FROM_PATH")

let copy_to_path_arg =
  Arg.(
    required
    & pos 2 (some string) None
    & info [] ~doc:"Destination path." ~docv:"TO_PATH")

let cp_man = Pages.cp.man

let cp_cmd =
  Cmd.v
    (Cmd.info "cp" ~doc:"copy files between the host and a running VM"
       ~man:cp_man)
    Term.(
      const copy $ global_opts_arg $ copy_recursive_flag $ copy_verbose_flag
      $ copy_source_arg $ copy_name_arg $ copy_from_path_arg $ copy_to_path_arg)

let umount_guest_path_arg =
  Arg.(
    required
    & pos 1 (some string) None
    & info []
        ~doc:
          "Guest mount path to unmount. A path starting with ~ is resolved \
           relative to the guest SSH user's home."
        ~docv:"GUEST_PATH")

let umount_man = Pages.umount.man

let umount_cmd =
  Cmd.v
    (Cmd.info "umount" ~doc:"unmount a hot-mounted directory from a running VM"
       ~man:umount_man)
    Term.(
      const umount $ virtle_opts_arg $ mount_name_arg $ umount_guest_path_arg)

let space_names_arg =
  Arg.(
    non_empty & pos_right 1 string []
    & info [] ~doc:"Space names to hotmount." ~docv:"SPACE")

let mount_space_man = Pages.mount_space.man

let mount_space_cmd =
  Cmd.v
    (Cmd.info "mount-space" ~doc:"hot-mount one or more spaces"
       ~man:mount_space_man)
    Term.(
      const mount_space $ virtle_opts_arg $ mount_name_arg $ space_names_arg)

let umount_space_man = Pages.umount_space.man

let umount_space_cmd =
  Cmd.v
    (Cmd.info "umount-space" ~doc:"unmount one or more hot-mounted spaces"
       ~man:umount_space_man)
    Term.(
      const umount_space $ virtle_opts_arg $ mount_name_arg $ space_names_arg)

let stop_name_arg =
  Arg.(
    value
    & pos 0 (some string) None
    & info []
        ~doc:"VM/state name. If omitted, stop requires exactly one running VM."
        ~docv:"NAME")

let force_flag =
  Arg.(
    value & flag
    & info [ "force" ] ~doc:"Stop even when the VM has active SSH connections.")

let stop_man = Pages.stop.man

let stop_cmd =
  Cmd.v
    (Cmd.info "stop" ~doc:"stop an ash background VM" ~man:stop_man)
    Term.(
      const stop $ virtle_opts_arg $ stop_name_arg $ suspend_flag $ force_flag)

let logs_name_arg =
  Arg.(
    required
    & pos 0 (some string) None
    & info [] ~doc:"VM/state name." ~docv:"NAME")

let follow_flag =
  Arg.(
    value & flag
    & info [ "follow"; "f" ] ~doc:"Follow new journal entries as they arrive.")

let lines_arg =
  Arg.(
    value & opt int 100
    & info [ "lines"; "n" ] ~doc:"Number of recent journal lines to show."
        ~docv:"N")

let logs_man = Pages.logs.man

let logs_cmd =
  Cmd.v
    (Cmd.info "logs" ~doc:"show logs for an ash background VM" ~man:logs_man)
    Term.(
      const logs $ global_opts_arg $ logs_name_arg $ follow_flag $ lines_arg)

let rm_man = Pages.rm.man

let rm_cmd =
  Cmd.v
    (Cmd.info "rm" ~doc:"select and delete ash VM state directories" ~man:rm_man)
    Term.(const rm_vms $ global_opts_arg)

let main_cmd =
  let doc = "spawn agent VMs with virtle" in
  let man = Pages.main.man in
  Cmd.group
    (Cmd.info "ash" ~version ~doc ~man)
    [
      spawn_cmd;
      attach_cmd;
      resume_cmd;
      mount_cmd;
      cp_cmd;
      umount_cmd;
      mount_space_cmd;
      umount_space_cmd;
      stop_cmd;
      logs_cmd;
      regenerate_cmd;
      inspect_cmd;
      ls_cmd;
      rm_cmd;
    ]

let () = exit (Cmd.eval main_cmd)
