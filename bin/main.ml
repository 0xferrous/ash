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
  let flake =
    match flake with
    | Some flake -> flake
    | None -> Log.fatal "spawn requires --flake"
  in
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

let resume opts name attach keep =
  Log.set_debug opts.global.debug;
  if keep && not attach then Log.fatal "--keep requires --attach";
  Virtle.resume ?virtle:opts.virtle ~name ~attach ~keep ~verbose:opts.verbose ()

let stop opts name suspend =
  Log.set_debug opts.global.debug;
  if suspend then Virtle.suspend ?virtle:opts.virtle ?name ()
  else Virtle.stop ?name ()

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

let mount_profile opts name profiles =
  Log.set_debug opts.global.debug;
  Virtle.hotmount_profiles ?virtle:opts.virtle ~name ~profiles ()

let umount_profile opts name profiles =
  Log.set_debug opts.global.debug;
  Virtle.hotunmount_profiles ?virtle:opts.virtle ~name ~profiles ()

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
    value
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

let spawn_man =
  [
    `S Manpage.s_description;
    `P
      "Creates or updates ash VM state, renders a virtle manifest, and starts \
       virtle.";
    `S "LIFECYCLE";
    `P
      "Plain spawn starts the VM as a background user systemd unit and \
       returns. The VM keeps running until stopped with ash stop.";
    `P
      "--attach starts the VM in the foreground and opens SSH. Without --keep, \
       the VM stops when the attached session exits.";
    `P
      "--attach --keep starts the VM as a background unit, then attaches over \
       SSH. The VM keeps running after SSH exits.";
    `P
      "--ephemeral is only valid with --attach. It removes the VM state \
       directory after the foreground attached session exits.";
    `S "BACKGROUND UNITS";
    `P
      "Background spawns use systemd-run --user to start virtle as a transient \
       unit named ash-NAME.service. ash stop NAME stops that unit.";
    `P
      "After starting a background VM, ash prints the unit name and a \
       journalctl --user -u ash-NAME.service -f hint for logs.";
    `S "MANIFEST GENERATION";
    `P
      "spawn writes ash.toml and virtle.toml before launching virtle. Both \
       files live in the VM state directory.";
    `P
      "For an existing named VM, spawn first builds new spawn inputs from the \
       current command line and defaults.";
    `P
      "Profiles have one carry-forward rule: if no --profile option is passed \
       and an old ash.toml exists, ash reads the old ash.toml and copies its \
       profile list into the new inputs. Passing one or more --profile options \
       disables this carry-forward and uses exactly those profiles.";
    `P
      "After inputs are built, spawn overwrites ash.toml with the new inputs \
       and renders virtle.toml from those same new inputs.";
    `P
      "Use ash regenerate NAME to re-render virtle.toml later from saved \
       ash.toml without launching the VM. Regeneration updates the manifest \
       for a future launch; it does not reconfigure an already running VM.";
    `S "MOUNTS";
    `P
      "Profiles selected with --profile add their configured directory mounts \
       as launch-time virtiofs shares. If no profile is selected, ash uses the \
       config's default profile.";
    `P
      "--mount-cwd also adds the current host directory as a workspace/cwd \
       mount for the guest.";
    `P
      "Guest-side mounting is done by ash through virtle guest-exec. For \
       background spawns, ash waits for the VM and mounts workspace/profile \
       targets after launch. For foreground attached spawns, the generated SSH \
       wrapper mounts them just before SSH starts. The mount operation is \
       idempotent.";
    `P
      "Runtime hotmounts are managed later with ash mount, ash umount, ash \
       mount-profile, and ash umount-profile.";
    `S "ASSUMED MOUNTS";
    `P
      "Every generated virtle.toml includes ash's fixed mounts: workspace, \
       hotmounts, a read-only ro-store mount for /nix/store, and a persistent \
       disk image at persist.img.";
    `P
      "The workspace mount exposes a directory inside ash VM state to the \
       guest through virtiofs. It acts as a host/guest directory portal and is \
       not capped like a disk image; usable size is bounded by host storage.";
    `P
      "The hotmounts mount is reserved for later ash mount operations, so new \
       host directories can be staged and mounted into a running guest without \
       regenerating the manifest.";
    `P
      "Note: /nix/store is exposed through virtiofs. Correct file ownership \
       and permissions currently require running the virtiofs daemon as root; \
       see https://github.com/shazow/agentspace/issues/131.";
    `S "SSH AUTOPROVISIONING";
    `P
      "spawn writes virtle.toml with ssh.autoprovision enabled. This records \
       that ash should manage an SSH key for attached sessions.";
    `P
      "The key is installed when ash attaches, not during a plain background \
       spawn. On attach, ash creates or reuses id_ed25519 in the VM state \
       directory, installs id_ed25519.pub into the guest user's \
       authorized_keys through virtle guest-exec, then runs ssh with that \
       identity.";
    `P
      "This requires the guest to have QEMU Guest Agent support and the guest \
       user/home path expected by the generated manifest.";
    `S Manpage.s_examples;
    `Pre "ash spawn --name work -f ../my-nix#agent";
    `Pre "ash spawn --name work -f ../my-nix#agent --attach --keep";
  ]

let spawn_cmd =
  Cmd.v
    (Cmd.info "spawn" ~doc:"spawn an agent VM" ~man:spawn_man)
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

let attach_man =
  [
    `S Manpage.s_description;
    `P
      "Attaches to a running ash VM over SSH using the VM's vsock CID from \
       virtle status.";
    `S "VM SELECTION";
    `P
      "Pass NAME to attach to that VM. If NAME is omitted, attach requires \
       exactly one running VM.";
    `S "SPAWNING STOPPED VMS";
    `P
      "With --spawn, attach can start a stopped named VM from saved ash.toml, \
       regenerate virtle.toml, then attach.";
    `P
      "--spawn starts a foreground VM that stops when SSH exits. Add --keep to \
       start it as a background systemd user unit and keep it running after \
       SSH exits.";
    `S "SSH AUTOPROVISIONING";
    `P
      "If the manifest has ssh.autoprovision enabled, attach creates or reuses \
       id_ed25519 in the VM state directory, installs the public key through \
       virtle guest-exec, and passes that identity to ssh.";
    `S Manpage.s_examples;
    `Pre "ash attach work";
    `Pre "ash attach --spawn work";
    `Pre "ash attach --spawn --keep work";
  ]

let attach_cmd =
  Cmd.v
    (Cmd.info "attach" ~doc:"ssh into a running VM" ~man:attach_man)
    Term.(
      const attach $ virtle_opts_arg $ attach_name_arg $ spawn_flag $ keep_flag)

let resume_name_arg =
  Arg.(
    required
    & pos 0 (some string) None
    & info [] ~doc:"VM/state name." ~docv:"NAME")

let resume_man =
  [
    `S Manpage.s_description;
    `P "Resumes a suspended existing VM using virtle launch --resume force.";
    `S "MANIFEST";
    `P
      "resume reuses the saved virtle.toml. It does not regenerate the \
       manifest because QEMU suspend/resume needs the saved device graph.";
    `S "LIFECYCLE";
    `P
      "Plain resume starts the VM as a background systemd user unit and \
       returns.";
    `P
      "--attach resumes in the foreground with SSH. Without --keep, the VM \
       stops when SSH exits.";
    `P
      "--attach --keep resumes as a background systemd user unit, waits for \
       readiness, then attaches. The VM keeps running after SSH exits.";
    `S Manpage.s_examples;
    `Pre "ash resume work";
    `Pre "ash resume --attach work";
    `Pre "ash resume --attach --keep work";
  ]

let resume_cmd =
  Cmd.v
    (Cmd.info "resume" ~doc:"resume a suspended VM" ~man:resume_man)
    Term.(
      const resume $ virtle_opts_arg $ resume_name_arg $ attach_flag $ keep_flag)

let ls_man =
  [
    `S Manpage.s_description;
    `P
      "Lists ash VM state directories under $XDG_STATE_HOME/ash, or \
       ~/.local/state/ash if XDG_STATE_HOME is unset.";
    `S "OUTPUT";
    `P
      "Shows VM name, status, vsock CID when running, host disk usage, \
       apparent virtual size, last modification time, and state path.";
    `P
      "DISK is host storage currently used. VIRTUAL is apparent size, \
       including sparse files such as persist.img.";
    `S Manpage.s_examples;
    `Pre "ash ls";
  ]

let ls_cmd =
  Cmd.v
    (Cmd.info "ls" ~doc:"list ash VM state directories" ~man:ls_man)
    Term.(const list_vms $ global_opts_arg)

let regenerate_name_arg =
  Arg.(
    required
    & pos 0 (some string) None
    & info [] ~doc:"VM/state name." ~docv:"NAME")

let regenerate_man =
  [
    `S Manpage.s_description;
    `P
      "Reads saved ash.toml, re-renders generated files, and exits without \
       launching the VM.";
    `S "WHAT IT REWRITES";
    `P
      "regenerate rewrites virtle.toml and generated helper files such as \
       ssh-with-profile-mounts. It does not rewrite ash.toml.";
    `S "WHEN USEFUL";
    `P
      "Use after upgrading ash when generated output changed, after changing \
       the referenced flake/config, or before relaunching a stopped VM.";
    `S "RUNNING VMS";
    `P
      "Regeneration affects future launches only. It does not reconfigure an \
       already running VM.";
    `S Manpage.s_examples;
    `Pre "ash regenerate work";
  ]

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

let mount_man =
  [
    `S Manpage.s_description;
    `P
      "Hot-mounts one host directory into a running VM without regenerating \
       virtle.toml.";
    `S "MOUNT SPEC";
    `P
      "Use HOST_PATH[:GUEST_PATH]. If GUEST_PATH is omitted, ash uses the \
       absolute host path as the guest target.";
    `P
      "A guest path starting with ~ is resolved relative to the guest SSH \
       user's home.";
    `S "HOW IT WORKS";
    `P
      "ash stages the host directory under the VM state's hotmounts directory, \
       exposes it through the fixed hotmounts virtiofs share, then uses virtle \
       guest-exec to mount it at GUEST_PATH inside the guest.";
    `P
      "--mode controls guest access: rw is the default; ro makes the staged \
       mount read-only.";
    `S "REQUIREMENTS";
    `P "The VM must be running and QEMU Guest Agent must be available.";
    `S Manpage.s_examples;
    `Pre "ash mount work ~/dev/project";
    `Pre "ash mount --mode ro work ~/src/nixpkgs:~/nixpkgs";
  ]

let mount_cmd =
  Cmd.v
    (Cmd.info "mount" ~doc:"hot-mount a host directory into a running VM"
       ~man:mount_man)
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

let umount_man =
  [
    `S Manpage.s_description;
    `P
      "Unmounts a hot-mounted guest path and tears down ash's host-side \
       staging mount.";
    `S "GUEST PATH";
    `P
      "GUEST_PATH must match the guest target used with ash mount. A path \
       starting with ~ is resolved relative to the guest SSH user's home.";
    `S "HOW IT WORKS";
    `P
      "ash uses virtle guest-exec to unmount GUEST_PATH in the guest, then \
       removes the matching staged mount under the VM state's hotmounts \
       directory.";
    `S "REQUIREMENTS";
    `P "The VM must be running and QEMU Guest Agent must be available.";
    `S Manpage.s_examples;
    `Pre "ash umount work ~/dev/project";
    `Pre "ash umount work ~/nixpkgs";
  ]

let umount_cmd =
  Cmd.v
    (Cmd.info "umount" ~doc:"unmount a hot-mounted directory from a running VM"
       ~man:umount_man)
    Term.(
      const umount $ virtle_opts_arg $ mount_name_arg $ umount_guest_path_arg)

let profile_names_arg =
  Arg.(
    non_empty & pos_right 1 string []
    & info [] ~doc:"Profile names to hotmount." ~docv:"PROFILE")

let mount_profile_man =
  [
    `S Manpage.s_description;
    `P
      "Hot-mounts directory mounts from one or more agent-box profiles into a \
       running VM.";
    `S "HOW IT WORKS";
    `P
      "ash reads the config path saved in the VM's ash.toml, then resolves the \
       PROFILE arguments from that agent-box config. It does not use the saved \
       spawn profile list unless you pass those profile names here.";
    `P
      "Each resolved profile directory mount is mounted using the same runtime \
       hotmount mechanism as ash mount.";
    `P
      "Read-only profile mounts stay read-only. Profile file entries are not \
       hot-mounted.";
    `S "REQUIREMENTS";
    `P "The VM must be running and QEMU Guest Agent must be available.";
    `S Manpage.s_examples;
    `Pre "ash mount-profile work rust go";
  ]

let mount_profile_cmd =
  Cmd.v
    (Cmd.info "mount-profile" ~doc:"hot-mount one or more profiles"
       ~man:mount_profile_man)
    Term.(
      const mount_profile $ virtle_opts_arg $ mount_name_arg $ profile_names_arg)

let umount_profile_man =
  [
    `S Manpage.s_description;
    `P
      "Unmounts directory mounts for one or more agent-box profiles from a \
       running VM.";
    `S "HOW IT WORKS";
    `P
      "ash reads the config path saved in the VM's ash.toml, then resolves the \
       PROFILE arguments from that agent-box config. It does not use the saved \
       spawn profile list unless you pass those profile names here.";
    `P
      "Each resolved profile directory mount target is then unmounted from the \
       running guest.";
    `P "Profile file entries are ignored, matching ash mount-profile.";
    `S "REQUIREMENTS";
    `P "The VM must be running and QEMU Guest Agent must be available.";
    `S Manpage.s_examples;
    `Pre "ash umount-profile work rust go";
  ]

let umount_profile_cmd =
  Cmd.v
    (Cmd.info "umount-profile" ~doc:"unmount one or more hot-mounted profiles"
       ~man:umount_profile_man)
    Term.(
      const umount_profile $ virtle_opts_arg $ mount_name_arg
      $ profile_names_arg)

let stop_name_arg =
  Arg.(
    value
    & pos 0 (some string) None
    & info []
        ~doc:"VM/state name. If omitted, stop requires exactly one running VM."
        ~docv:"NAME")

let stop_man =
  [
    `S Manpage.s_description;
    `P
      "Stops an ash-owned background VM by stopping its transient user systemd \
       unit.";
    `S "VM SELECTION";
    `P
      "Pass NAME to stop that VM. If NAME is omitted, stop requires exactly \
       one running VM.";
    `S "BACKGROUND UNITS";
    `P
      "ash stop targets the ash-NAME.service user unit created by background \
       spawn flows.";
    `P
      "Foreground attached VMs are not owned by a background unit, so ash stop \
       will refuse to stop them.";
    `S "SUSPEND";
    `P
      "With --suspend, ash runs virtle suspend for the VM's manifest instead \
       of stopping the unit. virtle saves QEMU state to disk and the launch \
       process exits.";
    `P "Resume later with ash resume NAME.";
    `S Manpage.s_examples;
    `Pre "ash stop work";
    `Pre "ash stop --suspend work";
  ]

let stop_cmd =
  Cmd.v
    (Cmd.info "stop" ~doc:"stop an ash background VM" ~man:stop_man)
    Term.(const stop $ virtle_opts_arg $ stop_name_arg $ suspend_flag)

let rm_man =
  [
    `S Manpage.s_description;
    `P
      "Opens an interactive multi-select picker for deleting stopped ash VM \
       state directories.";
    `S "SAFETY";
    `P
      "Only stopped VM states are shown. Running VMs are not selectable for \
       deletion.";
    `P
      "Deletion removes the selected VM state directory, including generated \
       manifests, SSH keys, hotmount staging data, workspace data, and \
       persistent images.";
    `S Manpage.s_examples;
    `Pre "ash rm";
  ]

let rm_cmd =
  Cmd.v
    (Cmd.info "rm" ~doc:"select and delete ash VM state directories" ~man:rm_man)
    Term.(const rm_vms $ global_opts_arg)

let main_cmd =
  let doc = "spawn agent VMs with virtle" in
  let man =
    [
      `S Manpage.s_description;
      `P
        "ash coordinates NixOS agent VMs through virtle. It reads an agent-box \
         style config, evaluates a NixOS flake host, writes a virtle manifest, \
         and manages spawn, attach, mount, stop, and cleanup flows.";
      `S "STATE";
      `P
        "Named VMs keep ash state under $XDG_STATE_HOME/ash/NAME/, or \
         ~/.local/state/ash/NAME/ if XDG_STATE_HOME is unset. State includes \
         the saved ash config, generated virtle manifest, SSH keys, hotmount \
         staging data, and VM runtime data.";
      `S "GLOBAL OPTIONS";
      `P
        "The options --debug, --virtle=PATH, and -v/--verbose are shared by \
         commands that use them.";
      `S "REQUIREMENTS";
      `P
        "ash assumes host tools are available as needed: nix, virtle, \
         virtiofsd, bindfs, ssh, systemd-ssh-proxy, systemd-run, systemctl, \
         ssh-keygen, /bin/sh, mountpoint, and du.";
      `P
        "Some paths can be resolved or overridden: virtle comes from --virtle, \
         ASH_VIRTLE, or PATH; ssh and systemd-ssh-proxy default to the \
         selected NixOS config unless overridden.";
      `P
        "Guest-side operations assume QEMU Guest Agent plus standard NixOS \
         tools under /run/current-system/sw/bin, including sh, mount, \
         mountpoint, install, mkdir, chown, chmod, grep, date, and printf.";
      `S Manpage.s_examples;
      `Pre "ash spawn --name work -f ../my-nix#agent";
      `Pre "ash spawn --name tmp -f ../my-nix#agent --attach";
      `Pre "ash spawn --name work -f ../my-nix#agent --attach --keep";
      `Pre "ash attach work";
      `S "SEE ALSO";
      `P "Use ash COMMAND --help for command-specific help.";
    ]
  in
  Cmd.group
    (Cmd.info "ash" ~version ~doc ~man)
    [
      spawn_cmd;
      attach_cmd;
      resume_cmd;
      mount_cmd;
      umount_cmd;
      mount_profile_cmd;
      umount_profile_cmd;
      stop_cmd;
      regenerate_cmd;
      ls_cmd;
      rm_cmd;
    ]

let () = exit (Cmd.eval main_cmd)
