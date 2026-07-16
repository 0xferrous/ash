open Cmdliner

type page = {
  file : string;
  command : string option;
  summary : string;
  man : Manpage.block list;
}

let main =
  {
    file = "ash";
    command = None;
    summary = "spawn agent VMs with virtle";
    man =
      [
        `S Manpage.s_description;
        `P
          "ash coordinates NixOS agent VMs through virtle. It reads its space \
           config, evaluates a NixOS flake host, writes a virtle manifest, and \
           manages spawn, attach, mount, stop, and cleanup flows.";
        `S "STATE";
        `P
          "Named VMs keep ash state under XDG_STATE_HOME/ash/NAME/ when \
           XDG_STATE_HOME is set, or ~/.local/state/ash/NAME/ otherwise. State \
           includes the saved ash config, generated virtle manifest, SSH keys, \
           hotmount staging data, and VM runtime data.";
        `S "GLOBAL OPTIONS";
        `P
          "The options --debug, --virtle=PATH, and -v/--verbose are shared by \
           commands that use them.";
        `S "REQUIREMENTS";
        `P
          "ash assumes host tools are available as needed: nix, virtle, \
           virtiofsd, bindfs, ssh, systemd-ssh-proxy, systemd-run, systemctl, \
           journalctl, ssh-keygen, /bin/sh, mountpoint, and du.";
        `P
          "Some paths can be resolved or overridden: virtle comes from \
           --virtle, ASH_VIRTLE, or PATH; ssh and systemd-ssh-proxy default to \
           the selected NixOS config unless overridden.";
        `P
          "Guest-side operations assume QEMU Guest Agent plus standard NixOS \
           tools under /run/current-system/sw/bin, including sh, mount, \
           mountpoint, install, stat, mkdir, chown, chmod, grep, date, printf, \
           ss, awk, and who.";
        `S Manpage.s_examples;
        `Pre "ash spawn --name work -f ../my-nix#agent";
        `Pre "ash spawn --name tmp -f ../my-nix#agent --attach";
        `Pre "ash spawn --name work -f ../my-nix#agent --attach --keep";
        `Pre "ash attach work";
        `S "SEE ALSO";
        `P "Use ash COMMAND --help for command-specific help.";
      ];
  }

let spawn =
  {
    file = "ash-spawn";
    command = Some "spawn";
    summary = "spawn an agent VM";
    man =
      [
        `S Manpage.s_description;
        `P
          "Creates or updates ash VM state, renders a virtle manifest, and \
           starts virtle.";
        `S "LIFECYCLE";
        `P
          "Plain spawn starts the VM as a background user systemd unit and \
           returns. The VM keeps running until stopped with ash stop.";
        `P
          "--attach starts the VM in the foreground and opens SSH. Without \
           --keep, the VM stops when the attached session exits.";
        `P
          "--attach --keep starts the VM as a background unit, then attaches \
           over SSH. The VM keeps running after SSH exits.";
        `P
          "--ephemeral is only valid with --attach. It removes the VM state \
           directory after the foreground attached session exits.";
        `S "BACKGROUND UNITS";
        `P
          "Background spawns use systemd-run --user to start virtle as a \
           transient unit named ash-NAME.service. ash stop NAME stops that \
           unit.";
        `P
          "After starting a background VM, ash prints the unit name and an ash \
           logs -f NAME hint for following its logs.";
        `S "MANIFEST GENERATION";
        `P
          "spawn writes ash-state.toml and virtle.toml before launching \
           virtle. Both files live in the VM state directory.";
        `P
          "For an existing named VM, spawn first builds new spawn inputs from \
           the current command line and defaults.";
        `P
          "For an existing named VM, omitting --flake reuses the flake saved \
           in ash-state.toml. A new VM still requires --flake, and an explicit \
           --flake overrides the saved value.";
        `P
          "For a new VM, no configured spaces are applied unless --space is \
           passed. For an existing named VM, omitting --space reuses the space \
           list saved in ash-state.toml. Passing --space explicitly replaces \
           the saved selection.";
        `P
          "After inputs are built, spawn overwrites ash-state.toml with the \
           new inputs and renders virtle.toml from those same new inputs.";
        `P
          "Use ash regenerate NAME to re-render virtle.toml later from saved \
           ash-state.toml without launching the VM. Regeneration updates the \
           manifest for a future launch; it does not reconfigure an already \
           running VM.";
        `S "FLAKE TARGET";
        `P
          "--flake expects FLAKE#HOST and is required when creating a new VM. \
           ash evaluates nixosConfigurations.HOST from that flake and uses it \
           for the guest kernel, initrd, kernel params, system toplevel, \
           host-side ssh, and host-side systemd-ssh-proxy paths.";
        `P
          "Path-like flake references are saved in ash-state.toml as resolved \
           absolute paths so ash regenerate NAME works from any current \
           directory.";
        `P
          "The selected NixOS configuration must expose normal NixOS system \
           attributes such as config.system.build.kernel, \
           config.system.build.initialRamdisk, config.system.build.toplevel, \
           config.boot.kernelParams, pkgs.openssh, and config.systemd.package.";
        `P
          "By default ash evaluates config.services.getty.autologinUser for \
           the guest SSH user, then validates that users.users.USER exists. \
           --user overrides the evaluated value.";
        `S "SPACE CONFIGURATION";
        `P
          "The config defaults to XDG_CONFIG_HOME/ash/config.toml, falling \
           back to ~/.config/ash/config.toml, and can be overridden with \
           --config. Each [spaces.NAME] table may define rw_mounts and \
           ro_mounts arrays, plus an extends array naming other spaces. \
           Extended spaces are evaluated recursively before the extending \
           space. Unknown spaces and inheritance cycles are errors.";
        `P
          "Each mount is HOST_PATH or HOST_PATH:GUEST_PATH. Host ~ resolves \
           against the host user's home; guest ~ resolves against the guest \
           SSH user's home. If GUEST_PATH is omitted, the original host path \
           string is reused as the guest path. Absolute paths are also \
           accepted. Missing host paths are skipped with a warning. Duplicate \
           mounts are removed after parsing and path expansion.";
        `S "MOUNTS";
        `P
          "Spaces selected with --space add their configured directory mounts \
           as launch-time virtiofs shares. New VMs have no selected spaces by \
           default; existing named VMs reuse their saved selection.";
        `P
          "--mount-cwd also adds the current host directory as a workspace/cwd \
           mount for the guest.";
        `P
          "Guest-side mounting is done by ash through virtle guest-exec. For \
           background spawns, ash waits for the VM and mounts workspace/space \
           targets after launch. For foreground attached spawns, the generated \
           SSH wrapper mounts them just before SSH starts. The mount operation \
           is idempotent.";
        `P
          "Runtime hotmounts are managed later with ash mount, ash umount, ash \
           mount-space, and ash umount-space. Successful hotmounts are saved \
           as desired state and restored by later background starts and \
           resumes. Foreground attached starts do not currently restore them.";
        `S "ASSUMED MOUNTS";
        `P
          "Every generated virtle.toml includes ash's fixed mounts: workspace, \
           hotmounts, a read-only ro-store mount for /nix/store, and a \
           persistent ext4 disk image at persist.img. The manifest sets KVM \
           acceleration on, so the host is expected to provide /dev/kvm.";
        `P
          "The workspace mount exposes a directory inside ash VM state to the \
           guest through virtiofs. It acts as a host/guest directory portal \
           and is not capped like a disk image; usable size is bounded by host \
           storage.";
        `P
          "The hotmounts mount is reserved for later ash mount operations, so \
           new host directories can be staged and mounted into a running guest \
           without regenerating the manifest.";
        `P
          "When --mount-cwd is used, ash adds workspace_cwd for the current \
           host directory. The current agent guest config mounts this tag at \
           /mnt/cwd.";
        `P
          "Note: /nix/store is exposed through virtiofs. Correct file \
           ownership and permissions currently require running the virtiofs \
           daemon as root; see \
           https://github.com/shazow/agentspace/issues/131.";
        `S "SSH AUTOPROVISIONING";
        `P
          "spawn writes virtle.toml with ssh.autoprovision enabled. This \
           records that ash should manage an SSH key for attached sessions.";
        `P
          "The key is installed when ash attaches, not during a plain \
           background spawn. On attach, ash creates or reuses id_ed25519 in \
           the VM state directory, installs id_ed25519.pub into the guest \
           user's authorized_keys through virtle guest-exec, then runs ssh \
           with that identity.";
        `P
          "Pass --kitty to spawn to use kitten ssh instead of ssh for attached \
           spawn sessions and save that choice in ash-state.toml for later \
           regenerated launches.";
        `P
          "This requires the guest to have QEMU Guest Agent support and the \
           guest user/home path expected by the generated manifest.";
        `S "GUEST CONTRACT";
        `P
          "The guest should run QEMU Guest Agent. For NixOS guests, enable \
           services.qemuGuest.enable.";
        `P
          "Attached flows wait for virtle SSH readiness. The guest must write \
           the token SSH-READY to /dev/virtio-ports/virtle.ready after sshd is \
           reachable.";
        `P
          "ash-side SSH autoprovisioning assumes the guest SSH user's writable \
           primary group is users. It creates or updates authorized_keys and \
           applies OpenSSH-compatible ownership and permissions.";
        `S Manpage.s_examples;
        `Pre "ash spawn --name work -f ../my-nix#agent";
        `Pre "ash spawn --name work -f ../my-nix#agent --attach --keep";
      ];
  }

let attach =
  {
    file = "ash-attach";
    command = Some "attach";
    summary = "ssh into a running VM";
    man =
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
          "With --spawn, attach can start a stopped named VM from saved \
           ash-state.toml, regenerate virtle.toml, then attach.";
        `P
          "--spawn starts a foreground VM that stops when SSH exits. Add \
           --keep to start it as a background systemd user unit and keep it \
           running after SSH exits.";
        `S "SSH AUTOPROVISIONING";
        `P
          "If the manifest has ssh.autoprovision enabled, attach creates or \
           reuses id_ed25519 in the VM state directory, installs the public \
           key through virtle guest-exec, and passes that identity to ssh.";
        `P
          "Pass --kitty to use kitten ssh instead of ssh for this attached \
           session.";
        `S Manpage.s_examples;
        `Pre "ash attach work";
        `Pre "ash attach --spawn work";
        `Pre "ash attach --spawn --keep work";
      ];
  }

let resume =
  {
    file = "ash-resume";
    command = Some "resume";
    summary = "resume a suspended VM";
    man =
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
          "--attach --keep resumes as a background systemd user unit, waits \
           for readiness, restores saved runtime hotmounts, then attaches. The \
           VM keeps running after SSH exits.";
        `P
          "Plain background resume also restores saved runtime hotmounts. A \
           foreground --attach resume does not currently restore them.";
        `S Manpage.s_examples;
        `Pre "ash resume work";
        `Pre "ash resume --attach work";
        `Pre "ash resume --attach --keep work";
      ];
  }

let ls =
  {
    file = "ash-ls";
    command = Some "ls";
    summary = "list ash VM state directories";
    man =
      [
        `S Manpage.s_description;
        `P
          "Lists ash VM state directories under XDG_STATE_HOME/ash when \
           XDG_STATE_HOME is set, or ~/.local/state/ash otherwise.";
        `S "OUTPUT";
        `P
          "Shows VM name, status, vsock CID when running, active SSH \
           connection and PTY counts, host disk usage, apparent virtual size, \
           last modification time, and state path.";
        `P
          "SSH counts established AF_VSOCK connections to guest port 22. PTY \
           counts active SSH pseudo-terminals registered by the guest. A dash \
           means the VM is stopped or the QGA query failed.";
        `P
          "DISK is host storage currently used. VIRTUAL is apparent size, \
           including sparse files such as persist.img. Both exclude ash's \
           hotmounts staging directory.";
        `S Manpage.s_examples;
        `Pre "ash ls";
      ];
  }

let inspect =
  {
    file = "ash-inspect";
    command = Some "inspect";
    summary = "show detailed VM configuration and state";
    man =
      [
        `S Manpage.s_description;
        `P
          "Shows a concise, human-readable summary of a named running or \
           stopped VM.";
        `S "OUTPUT";
        `P
          "The default view includes runtime and storage status, flake and \
           space configuration, machine resources, workspace paths, configured \
           virtle mounts and files, and persistent hotmount state.";
        `P
          "Malformed hotmount metadata is shown as a warning in the hotmount \
           section.";
        `S "JSON";
        `P
          "With --json, prints the complete machine-readable view, including \
           the saved ash-state.toml, referenced ash configuration, generated \
           virtle.toml, detailed paths, raw virtle runtime status, and the \
           guest mount table when running.";
        `S Manpage.s_examples;
        `Pre "ash inspect work";
        `Pre "ash inspect --json work | jq '.virtle.config.mounts'";
        `Pre "ash inspect --json work | jq '.hotmounts'";
      ];
  }

let regenerate =
  {
    file = "ash-regenerate";
    command = Some "regenerate";
    summary = "regenerate generated VM files";
    man =
      [
        `S Manpage.s_description;
        `P
          "Reads saved ash-state.toml, re-renders generated files, and exits \
           without launching the VM.";
        `S "WHAT IT REWRITES";
        `P
          "regenerate rewrites virtle.toml and generated helper files such as \
           ssh-with-space-mounts. It does not rewrite ash-state.toml.";
        `S "WHEN USEFUL";
        `P
          "Use after upgrading ash when generated output changed, after \
           changing the referenced flake/config, or before relaunching a \
           stopped VM.";
        `S "RUNNING VMS";
        `P
          "Regeneration affects future launches only. It does not reconfigure \
           an already running VM.";
        `S Manpage.s_examples;
        `Pre "ash regenerate work";
      ];
  }

let mount =
  {
    file = "ash-mount";
    command = Some "mount";
    summary = "hot-mount a host directory into a running VM";
    man =
      [
        `S Manpage.s_description;
        `P
          "Hot-mounts one host directory into a running VM without \
           regenerating virtle.toml.";
        `S "MOUNT SPEC";
        `P
          "Use HOST_PATH[:GUEST_PATH]. If GUEST_PATH is omitted, ash uses the \
           absolute host path as the guest target.";
        `P
          "A guest path starting with ~ is resolved relative to the guest SSH \
           user's home. Ash normalizes redundant path components without \
           resolving host symlinks to their targets.";
        `S "HOW IT WORKS";
        `P
          "ash stages the host directory under the VM state's hotmounts \
           directory, exposes it through the fixed hotmounts virtiofs share, \
           then uses virtle guest-exec to mount it at GUEST_PATH inside the \
           guest.";
        `P
          "The guest hotmounts share is mounted lazily on first use. --mode \
           controls guest access: rw is the default; ro makes the staged mount \
           read-only.";
        `P
          "A successful mount is recorded as persistent desired state. Later \
           background starts and resumes attempt to recreate it; an individual \
           restoration failure is reported without preventing VM startup.";
        `S "REQUIREMENTS";
        `P "The VM must be running and QEMU Guest Agent must be available.";
        `S Manpage.s_examples;
        `Pre "ash mount work ~/dev/project";
        `Pre "ash mount --mode ro work ~/src/nixpkgs:~/nixpkgs";
      ];
  }

let umount =
  {
    file = "ash-umount";
    command = Some "umount";
    summary = "unmount a hot-mounted directory from a running VM";
    man =
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
          "ash removes the mount's desired-state record, uses virtle \
           guest-exec to unmount GUEST_PATH, removes an empty guest \
           mountpoint, then tears down the matching host staging mount. If the \
           guest unmount fails normally, ash restores the desired-state \
           record.";
        `P
          "Host teardown tries normal and lazy FUSE unmounts before a \
           root-only umount fallback, which handles virtiofsd briefly keeping \
           the staging mount busy.";
        `S "REQUIREMENTS";
        `P "The VM must be running and QEMU Guest Agent must be available.";
        `S Manpage.s_examples;
        `Pre "ash umount work ~/dev/project";
        `Pre "ash umount work ~/nixpkgs";
      ];
  }

let mount_space =
  {
    file = "ash-mount-space";
    command = Some "mount-space";
    summary = "hot-mount one or more spaces";
    man =
      [
        `S Manpage.s_description;
        `P
          "Hot-mounts directory mounts from one or more configured spaces into \
           a running VM.";
        `S "HOW IT WORKS";
        `P
          "ash reads the config path saved in the VM's ash-state.toml, then \
           resolves the SPACE arguments from that ash config.";
        `P
          "Each resolved space directory mount is mounted using the same \
           runtime hotmount mechanism as ash mount.";
        `P
          "Read-only space mounts stay read-only. Successful space mounts use \
           the same persistent desired-state records as ash mount and are \
           restored by later background starts and resumes.";
        `S "REQUIREMENTS";
        `P "The VM must be running and QEMU Guest Agent must be available.";
        `S Manpage.s_examples;
        `Pre "ash mount-space work rust go";
      ];
  }

let umount_space =
  {
    file = "ash-umount-space";
    command = Some "umount-space";
    summary = "unmount one or more hot-mounted spaces";
    man =
      [
        `S Manpage.s_description;
        `P
          "Unmounts directory mounts for one or more configured spaces from a \
           running VM.";
        `S "HOW IT WORKS";
        `P
          "ash reads the config path saved in the VM's ash-state.toml, then \
           resolves the SPACE arguments from that ash config.";
        `P
          "Each resolved space directory target is unmounted from the running \
           guest and removed from persistent desired state.";
        `S "REQUIREMENTS";
        `P "The VM must be running and QEMU Guest Agent must be available.";
        `S Manpage.s_examples;
        `Pre "ash umount-space work rust go";
      ];
  }

let stop =
  {
    file = "ash-stop";
    command = Some "stop";
    summary = "stop an ash background VM";
    man =
      [
        `S Manpage.s_description;
        `P
          "Stops an ash-owned background VM by stopping its transient user \
           systemd unit.";
        `S "VM SELECTION";
        `P
          "Pass NAME to stop that VM. If NAME is omitted, stop requires \
           exactly one running VM.";
        `S "BACKGROUND UNITS";
        `P
          "ash stop targets the ash-NAME.service user unit created by \
           background spawn flows.";
        `P
          "Foreground attached VMs are not owned by a background unit, so ash \
           stop will refuse to stop them.";
        `S "ACTIVE SSH CONNECTIONS";
        `P
          "Before stopping the unit, ash queries the guest through QGA. If the \
           VM has active SSH connections, ash prints their connection and PTY \
           counts and asks for confirmation.";
        `P
          "In a non-interactive invocation, ash refuses to stop a VM with \
           active SSH connections. Pass --force to bypass confirmation and \
           continue after the warning.";
        `S "SUSPEND";
        `P
          "With --suspend, ash runs virtle suspend for the VM's manifest \
           instead of stopping the unit. virtle saves QEMU state to disk and \
           the launch process exits.";
        `P "Resume later with ash resume NAME.";
        `S Manpage.s_examples;
        `Pre "ash stop work";
        `Pre "ash stop --force work";
        `Pre "ash stop --suspend work";
      ];
  }

let logs =
  {
    file = "ash-logs";
    command = Some "logs";
    summary = "show logs for an ash background VM";
    man =
      [
        `S Manpage.s_description;
        `P
          "Shows journal entries from the latest invocation of the transient \
           user systemd unit that owns an ash background VM. Logs from older \
           processes that reused the same unit name are excluded.";
        `S "OUTPUT";
        `P
          "Each journal entry is printed as [YYYY-MM-DD HH:MM:SS] MESSAGE. \
           Hostname, process name, and process ID metadata are omitted.";
        `S "OPTIONS";
        `P
          "By default, ash shows the 100 most recent entries. Use --lines=N or \
           -n N to choose a different number.";
        `P
          "With --follow or -f, journalctl continues waiting for new entries \
           until interrupted.";
        `S "BACKGROUND UNITS";
        `P
          "ash logs reads the ash-NAME.service user unit created by background \
           spawn flows. Foreground attached VMs do not run in this unit.";
        `S Manpage.s_examples;
        `Pre "ash logs work";
        `Pre "ash logs --lines 250 work";
        `Pre "ash logs -f work";
      ];
  }

let rm =
  {
    file = "ash-rm";
    command = Some "rm";
    summary = "select and delete ash VM state directories";
    man =
      [
        `S Manpage.s_description;
        `P
          "Opens an interactive multi-select picker for deleting stopped ash \
           VM state directories.";
        `S "SAFETY";
        `P
          "Only stopped VM states are shown. Running VMs are not selectable \
           for deletion.";
        `P
          "Deletion removes the selected VM state directory, including \
           generated manifests, SSH keys, hotmount staging data, workspace \
           data, and persistent images.";
        `S Manpage.s_examples;
        `Pre "ash rm";
      ];
  }

let all =
  [
    main;
    spawn;
    attach;
    resume;
    mount;
    umount;
    mount_space;
    umount_space;
    stop;
    logs;
    regenerate;
    inspect;
    ls;
    rm;
  ]

let escape_html text =
  let b = Buffer.create (String.length text) in
  String.iter
    (function
      | '&' -> Buffer.add_string b "&amp;"
      | '<' -> Buffer.add_string b "&lt;"
      | '>' -> Buffer.add_string b "&gt;"
      | '"' -> Buffer.add_string b "&quot;"
      | '\'' -> Buffer.add_string b "&#39;"
      | c -> Buffer.add_char b c)
    text;
  Buffer.contents b

let id_of_heading heading =
  heading |> String.lowercase_ascii
  |> String.map (function ' ' | '/' -> '-' | c -> c)

let rec render_block = function
  | `S heading ->
      let id = id_of_heading heading in
      Printf.sprintf "<h2 id=\"%s\">%s</h2>\n" (escape_html id)
        (escape_html heading)
  | `P text -> Printf.sprintf "<p>%s</p>\n" (escape_html text)
  | `Pre text ->
      Printf.sprintf "<pre><code>%s</code></pre>\n" (escape_html text)
  | `I (left, right) ->
      Printf.sprintf "<dl><dt>%s</dt><dd>%s</dd></dl>\n" (escape_html left)
        (escape_html right)
  | `Noblank -> ""
  | `Blocks blocks -> blocks |> List.map render_block |> String.concat ""

let page_title page = page.file ^ "(1)"

let man7_css =
  {|html { color-scheme: light dark; }
body {
  margin: 0 auto;
  padding: 0 1.25rem 2rem;
  max-width: 92ch;
  color: #111;
  background: #fff;
  font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace;
  font-size: 0.95rem;
  line-height: 1.35;
}
body * {
  font-family: inherit !important;
}
a { color: #0645ad; text-decoration: none; }
a:hover { text-decoration: underline; }
.top, .foot {
  display: grid;
  grid-template-columns: 1fr auto 1fr;
  gap: 1rem;
  margin: 1rem 0 1.75rem;
  font-size: 0.9rem;
}
.top .center, .foot .center { text-align: center; }
.top .right, .foot .right { text-align: right; }
.nav {
  margin: 0.75rem 0 1.25rem;
  font-size: 0.9rem;
}
h1 {
  margin: 1.6rem 0 0.4rem;
  font-size: 1rem;
  line-height: 1.2;
  text-transform: uppercase;
}
h2 {
  margin: 1.35rem 0 0.25rem;
  font-size: 1rem;
  line-height: 1.2;
  text-transform: uppercase;
}
p {
  margin: 0.25rem 0 0.7rem 8ch;
}
pre {
  margin: 0.25rem 0 0.85rem 8ch;
  overflow-x: auto;
  font-family: inherit;
  font-size: 0.92rem;
  line-height: 1.3;
  background: transparent;
}
dl { margin-left: 8ch; }
dt { font-weight: bold; }
dd { margin: 0.2rem 0 0.7rem 4ch; }
.summary { margin-left: 8ch; }
.generated { margin-top: 2rem; font-size: 0.85rem; color: #555; }
@media (prefers-color-scheme: dark) {
  body { color: #ddd; background: #111; }
  a { color: #8ab4f8; }
  .generated { color: #aaa; }
}
|}

let normalize_base_href = function
  | None | Some "" -> ""
  | Some url ->
      let url = if String.ends_with ~suffix:"/" url then url else url ^ "/" in
      Printf.sprintf "<base href=\"%s\">\n" (escape_html url)

let render_page ?base_href page =
  let title = page_title page in
  let body = page.man |> List.map render_block |> String.concat "" in
  Printf.sprintf
    {|<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
%s<title>%s</title>
<style>%s</style>
</head>
<body>
<div class="top"><span>%s</span><span class="center">Ash Manual</span><span class="right">%s</span></div>
<div class="nav"><a href="index.html">Index</a></div>
<h1>NAME</h1>
<p class="summary">%s - %s</p>
%s
<p class="generated">Generated from ash Cmdliner manpage metadata.</p>
<div class="foot"><span>%s</span><span class="center">ash 0.1.0</span><span class="right">%s</span></div>
</body>
</html>
|}
    (normalize_base_href base_href)
    (escape_html title) man7_css (escape_html title) (escape_html title)
    (escape_html page.file) (escape_html page.summary) body (escape_html title)
    (escape_html title)

let render_index ?base_href pages =
  let items =
    pages
    |> List.map (fun page ->
        let title = page_title page in
        Printf.sprintf "<li><a href=\"%s.html\">%s</a> — %s</li>"
          (escape_html page.file) (escape_html title) (escape_html page.summary))
    |> String.concat "\n"
  in
  Printf.sprintf
    {|<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
%s<title>ash command pages</title>
<style>%s
ul { margin-left: 4ch; padding-left: 4ch; }
li { margin: 0.35rem 0; }
</style>
</head>
<body>
<div class="top"><span>ash(1)</span><span class="center">Ash Manual</span><span class="right">ash(1)</span></div>
<h1>ash command pages</h1>
<ul>%s</ul>
<div class="foot"><span>ash(1)</span><span class="center">ash 0.1.0</span><span class="right">ash(1)</span></div>
</body>
</html>
|}
    (normalize_base_href base_href)
    man7_css items
