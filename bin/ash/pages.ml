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
           manages spawn, attach, copy, mount, stop, and cleanup flows.";
        `S "STATE";
        `P
          "Named VMs keep ash state under XDG_STATE_HOME/ASH_NAME/NAME/ or \
           ~/.local/state/ASH_NAME/NAME/. ASH_NAME defaults to ash. State \
           includes the saved ash config, generated virtle manifest, SSH keys, \
           hotmount staging data, and VM runtime data.";
        `S "GLOBAL OPTIONS";
        `P
          "The options --debug, --virtle=PATH, and -v/--verbose are shared by \
           commands that use them.";
        `S "REQUIREMENTS";
        `P
          "ash assumes host tools are available as needed: nix, virtle, \
           virtiofsd, bindfs, ssh, scp, systemd-ssh-proxy, systemd-run, \
           systemctl, journalctl, ssh-keygen, agent-portal-host, /bin/sh, \
           mountpoint, and du.";
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
           starts the VM. Launching executes the manifest's plan in-process \
           through the virtle Go library (libvirtle.so); the virtle CLI is no \
           longer spawned for launch.";
        `S "LIFECYCLE";
        `P
          "Plain spawn starts the VM as a background user systemd unit \
           (running ash launch-ffi) and returns. The VM keeps running until \
           stopped with ash stop, which asks the guest to power down.";
        `P
          "--attach starts the VM in the foreground and opens SSH. Without \
           --keep, the VM stops when the attached session exits. Interactive \
           --kernel-serial=console requires this foreground mode and cannot be \
           combined with --keep.";
        `P
          "--attach --keep starts the VM as a background unit, then attaches \
           over SSH. The VM keeps running after SSH exits.";
        `P
          "--ephemeral is only valid with --attach. It removes the VM state \
           directory after the foreground attached session exits.";
        `S "BACKGROUND UNITS";
        `P
          "Background spawns use systemd-run --user to start an ash launch-ffi \
           unit named ash-NAME.service. ash stop NAME stops that unit.";
        `P
          "After starting a background VM, ash prints the unit name and an ash \
           logs -f NAME hint for following its logs.";
        `S "MANIFEST GENERATION";
        `P
          "A new VM is always evaluated before spawn writes ash-state.toml and \
           virtle.toml and launches virtle. Both files live in the VM state \
           directory. Virtle's own runtime state and control sockets use its \
           nested virtle_state directory.";
        `P
          "An existing named VM reuses its saved ash-state.toml and \
           virtle.toml without Nix evaluation. Pass --eval to re-evaluate the \
           selected NixOS configuration, refresh its generated state and \
           manifest, and then launch it.";
        `P
          "For a new VM, --flake is required and --eval is implied. For an \
           existing VM spawned with --eval, omitting --flake, \
           --override-input, or --space reuses the corresponding saved values; \
           explicitly passing them replaces the saved selection.";
        `P
          "--nix-store-strategy and --nix-store-image-size-mib override the \
           [global.nix_store] defaults during evaluation. Explicit overrides \
           are saved in ash-state.toml and reused by later evaluated spawns.";
        `S "PORTAL";
        `P
          "When the config contains an enabled [portal] section with \
           global=false, spawn adds a dedicated agent-portal-host vsock \
           process to the virtle manifest. Virtle starts and stops it with the \
           VM, deriving a unique unprivileged Portal port from the allocated \
           guest CID.";
        `P
          "With portal.global=true, Ash requires transport=vsock and uses the \
           configured vsock_cid and vsock_port without starting the host. The \
           user must run agent-portal-host separately.";
        `P
          "Both modes install /etc/profile.d/ash-agent-portal.sh for POSIX \
           shells and \
           ~/.local/share/nushell/vendor/autoload/ash-agent-portal.nu for \
           Nushell through QEMU Guest Agent. The guest must already contain \
           the Portal wrappers.";
        `P
          "Use ash regenerate NAME to re-render virtle.toml later from saved \
           ash-state.toml without launching the VM. Regeneration updates the \
           manifest for a future launch; it does not reconfigure an already \
           running VM.";
        `S "FLAKE TARGET";
        `P
          "--flake expects FLAKE#HOST and is required when creating a new VM. \
           ash evaluates nixosConfigurations.HOST from that flake and uses it \
           for the guest kernel, initrd, kernel params, system toplevel, a Nix \
           store registration dump, host-side ssh, and host-side \
           systemd-ssh-proxy paths.";
        `P
          "Path-like flake references and override input references are saved \
           in ash-state.toml as resolved absolute paths so ash regenerate NAME \
           works from any current directory.";
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
          "The config defaults to XDG_CONFIG_HOME/ASH_NAME/config.toml or \
           ~/.config/ASH_NAME/config.toml. ASH_NAME defaults to ash, and \
           --config overrides every default. Each [spaces.NAME] table may \
           define rw_mounts, ro_mounts, and files arrays, plus an extends \
           array naming other spaces. Extended spaces are evaluated \
           recursively before the extending space. Unknown spaces and \
           inheritance cycles are errors.";
        `P
          "The [global] table may set memory to the VM memory in MiB; the \
           default is 4096. Set kitty = true to use kitten ssh by default for \
           spawn and attach sessions. network_bridge and qemu_bridge_helper \
           configure the host bridge used for VM networking.";
        `P
          "Each mount or file is HOST_PATH or HOST_PATH:GUEST_PATH. Host ~ \
           resolves against the host user's home; guest ~ resolves against the \
           guest SSH user's home. If GUEST_PATH is omitted, the original host \
           path string is reused as the guest path. Absolute paths are also \
           accepted. Missing host paths are skipped with a warning. Duplicate \
           resources are removed after parsing and path expansion.";
        `P
          "Regular files selected through a space are embedded as Virtle \
           write_files entries with their source permission mode and overwrite \
           enabled. Guest-home destinations are owned by the guest SSH user; \
           other destinations keep Virtle's default ownership.";
        `S "MOUNTS";
        `P
          "Spaces selected with --space stage their configured directories \
           beneath the consolidated shares-ro or shares-rw tree, then bind \
           those paths into the guest. New VMs have no selected spaces by \
           default; existing named VMs reuse their saved selection.";
        `P
          "--mount-cwd also adds the current host directory as a workspace/cwd \
           mount for the guest.";
        `P
          "The resolved kernel, initrd, NixOS toplevel, and closure-info \
           output are protected by GC roots in the VM state directory. The \
           roots remain while the VM state exists and are removed with that \
           state, including after an ephemeral session.";
        `P
          "Guest preparation is done by ash through virtle guest-exec. Ash \
           imports the selected closure registration into the guest Nix \
           database, then mounts workspace/space targets. Local-overlay guests \
           skip the import because their readonly lower store already contains \
           the registration. Foreground attached spawns use the generated SSH \
           wrapper for the same preparation.";
        `P
          "Runtime mounts are managed later with ash mount, ash umount, ash \
           mount-space, and ash umount-space. Their resolved paths, modes, and \
           manual or space ownership claims are saved in ash-state.toml and \
           reconciled by later starts and resumes.";
        `S "NIX STORE STRATEGIES";
        `P
          "Set [global.nix_store].strategy to shared or image. shared is the \
           default. image_size_mib configures the image strategy's capacity in \
           MiB and defaults to 16384. --nix-store-strategy and \
           --nix-store-image-size-mib override these defaults for one VM and \
           save the choice in its ash-state.toml.";
        `P
          "The shared strategy stages the host /nix/store at \
           shares/ro/system/nix-store. Both store strategies expose exactly \
           two directory shares, shares-ro and shares-rw. --shares-ro-socket \
           may select an existing daemon socket; --ro-store-socket remains a \
           compatibility alias.";
        `P
          "The image strategy creates nix-store.img as a private ext4 \
           filesystem labeled nix-store and copies the selected closure plus \
           its registration file into it through libext2fs. It does not expose \
           the host /nix/store. The guest must mount the label at /nix with \
           neededForBoot enabled; Ash initializes the Nix database through QGA \
           after boot.";
        `S "IMAGE STORE CACHE";
        `P
          "Ash keeps one read-only, closure-sized base image for each NixOS \
           toplevel and registration output under \
           $XDG_CACHE_HOME/$ASH_NAME/nix-store-images, falling back to \
           ~/.cache/$ASH_NAME/nix-store-images. ASH_NAME defaults to ash. \
           Writable capacity is not part of the cache identity, so VMs with \
           different image_size_mib values reuse the same base.";
        `P
          "For a new VM image, Ash clones the cached base with cp \
           --reflink=auto --sparse=always and grows the writable clone with \
           resize2fs to image_size_mib. Reflink-capable filesystems initially \
           share blocks with the base; other filesystems receive a sparse \
           copy. If image_size_mib is smaller than the closure-sized base, \
           creation fails and reports the minimum size.";
        `P
          "Cache entries are disposable. A missing, malformed, mismatched, or \
           incorrectly sized cache entry is rebuilt from the selected closure. \
           Existing VM images are updated in place rather than replaced \
           because they may contain guest-added store paths.";
        `P
          "Increasing image_size_mib grows a stopped VM's filesystem \
           automatically. If the selected closure changes, Ash retains \
           existing paths and imports only missing immutable store paths. A \
           failed import can be retried, optionally after increasing the image \
           size. Shrinking the filesystem still requires ash rebuild-db and \
           discards guest-added store paths.";
        `S "ASSUMED MOUNTS";
        `P
          "Every generated virtle.toml includes exactly two virtiofs directory \
           mounts, shares-ro and shares-rw, plus the persistent ext4 image at \
           persist.img. The image Nix store strategy additionally attaches \
           nix-store.img, labeled nix-store. The manifest enables KVM, so the \
           host is expected to provide /dev/kvm.";
        `P
          "The host-side VM state uses this directory layout. Conditional \
           entries appear only when their strategy or mount feature is used:";
        `Pre
          "<state-dir>/\n\
           |-- ash-state.toml\n\
           |-- virtle.toml\n\
           |-- shares/\n\
           |   |-- ro/                         -> shares-ro\n\
           |   |   |-- system/\n\
           |   |   |   |-- nix-store/         # shared strategy\n\
           |   |   |   `-- guest-store-state/ # shared strategy\n\
           |   |   `-- mounts/\n\
           |   |       |-- spaces/<tag>/\n\
           |   |       `-- hotmounts/<id>/\n\
           |   `-- rw/                         -> shares-rw\n\
           |       |-- system/\n\
           |       |   |-- guest-store-state/  # shared strategy\n\
           |       |   |-- guest-store-upper/  # shared strategy\n\
           |       |   `-- guest-store-work/   # shared strategy\n\
           |       `-- mounts/\n\
           |           |-- workspace/\n\
           |           |-- cwd/                # with --mount-cwd\n\
           |           |-- spaces/<tag>/\n\
           |           `-- hotmounts/<id>/\n\
           |-- persist.img\n\
           |-- nix-store.img                   # image strategy\n\
           `-- virtle_state/                   # sockets and runtime files";
        `P
          "The guest mounts shares-ro and shares-rw at /run/ash/shares/ro and \
           /run/ash/shares/rw, then Ash bind-mounts individual staged children \
           at their requested guest destinations.";
        `P
          "The workspace lives at shares/rw/mounts/workspace and is bound to \
           the guest workspace path. It is not capped like a disk image; \
           usable size is bounded by host storage.";
        `P
          "Runtime directories are staged below \
           shares/{ro,rw}/mounts/hotmounts and can be mounted into a running \
           guest without regenerating the manifest.";
        `P
          "With the shared strategy, the shares mounts expose VM-state \
           directories at /run/ash/shares/ro and /run/ash/shares/rw. Before \
           launch, Ash loads the resolved NixOS closure registration into \
           shares/ro/system/guest-store-state so a guest local-overlay store \
           can use it as readonly lower-store metadata. The rw share provides \
           guest-store-state, guest-store-upper, and guest-store-work for \
           host-backed OverlayFS upper layers. Configure the local-overlay \
           store's writable state to use guest-store-state so its metadata is \
           reset with the upper layer. When subordinate host UID/GID ranges \
           are available, Ash maps guest identities one-to-one so dedicated \
           build users keep distinct ownership; otherwise it falls back to \
           squashing identities to the host user.";
        `P
          "When --mount-cwd is used, ash stages the current host directory at \
           shares/rw/mounts/cwd and binds it to /mnt/cwd in the guest.";
        `S "SSH AUTOPROVISIONING";
        `P
          "Ash creates or reuses id_ed25519 in the VM state directory and \
           installs its public key through QGA before an attached SSH session. \
           Foreground launches perform this in the generated SSH setup \
           wrapper; background attaches perform the equivalent guest-exec \
           installation before running ssh.";
        `P
          "Pass --kitty to spawn to use kitten ssh instead of ssh for attached \
           spawn sessions and save that choice in ash-state.toml for later \
           regenerated launches. Set global.kitty = true in the Ash config to \
           make Kitty the default without saving a per-VM override.";
        `P
          "Pass --waypipe to wrap the attached SSH session with Waypipe. The \
           guest must provide waypipe and xwayland-satellite in PATH, and the \
           host must be running a Wayland compositor. --waypipe and --kitty \
           may be combined.";
        `P
          "Waypipe runs with --no-gpu because Ash does not expose a guest GPU. \
           It forwards host compositor protocols and should only be used with \
           trusted guest applications.";
        `P
          "This requires the guest to have QEMU Guest Agent support and the \
           guest user/home path expected by the generated manifest.";
        `S "MDNS NAME";
        `P
          "Ash passes ash.mdns-host=<dns-label> and ash.mdns-mac=<stable-mac> \
           on the guest kernel command line. A compatible guest can use these \
           values to publish <dns-label>.ash.local; the agent NixOS \
           configuration uses Avahi. Invalid DNS-label characters are \
           normalized with a digest suffix. The host must have .local mDNS \
           resolution enabled, and multicast UDP 5353 must pass over the VM \
           bridge.";
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
          "Attach creates or reuses id_ed25519 in the VM state directory, \
           installs the public key through virtle guest-exec, and passes that \
           identity to ssh.";
        `P
          "Pass --kitty to use kitten ssh instead of ssh for this attached \
           session. The current config's global.kitty setting also provides \
           the default for the VM.";
        `P
          "Pass --waypipe to forward guest Wayland and X11 applications to the \
           host compositor. Waypipe uses Ash's generated SSH wrapper, enables \
           xwayland-satellite for X11 clients, and can use the Kitty wrapper \
           when --kitty is also passed.";
        `S Manpage.s_examples;
        `Pre "ash attach work";
        `Pre "ash attach --waypipe work";
        `Pre "ash attach --waypipe --kitty work";
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
           for readiness, restores saved runtime mounts, then attaches. The VM \
           keeps running after SSH exits.";
        `P
          "Both background and foreground attached resumes restore saved \
           runtime mounts.";
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
    summary = "list ash VM state directories or cached images";
    man =
      [
        `S Manpage.s_description;
        `P
          "Lists ash VM state directories under XDG_STATE_HOME/ASH_NAME when \
           XDG_STATE_HOME is set, or ~/.local/state/ASH_NAME otherwise. \
           ASH_NAME defaults to ash. With --cache, lists cached image-backed \
           Nix store bases instead.";
        `S "OUTPUT";
        `P
          "The default output shows VM name, status, private IPv4 address and \
           vsock CID when running, active SSH connection and PTY counts, host \
           disk usage, apparent virtual size, last modification time, and \
           state path.";
        `P
          "IP is the first global IPv4 address on the guest interface whose \
           MAC matches the stable address generated for the VM name. SSH \
           counts established AF_VSOCK connections to guest port 22. PTY \
           counts active SSH pseudo-terminals registered by the guest. A dash \
           means the VM is stopped, has no address yet, or the QGA query \
           failed.";
        `P
          "DISK is host storage currently used. VIRTUAL is apparent size, \
           including sparse files such as persist.img. Both exclude the \
           consolidated shares tree so nested host staging mounts are not \
           traversed.";
        `P
          "With --cache, output shows each cache key, host disk usage, sparse \
           virtual size, modification time, logical VM reference count, \
           closure name, and image path. Cache entries remain safe to delete \
           because VM store images are independent clones.";
        `S Manpage.s_examples;
        `Pre "ash ls";
        `Pre "ash ls --cache";
      ];
  }

let manifest_check =
  {
    file = "ash-manifest-check";
    command = Some "manifest-check";
    summary = "validate a virtle manifest in-process via the virtle library";
    man =
      [
        `S Manpage.s_description;
        `P
          "Decodes, resolves, and validates a virtle manifest in-process \
           through the virtle Go library (libvirtle.so) instead of spawning \
           the virtle CLI. The default output is the rendered QEMU argv; with \
           --json it prints the resolved manifest as JSON.";
        `S Manpage.s_examples;
        `Pre "ash manifest-check --manifest virtle.toml";
        `Pre "ash manifest-check --json --manifest virtle.toml | jq .qemu";
      ];
  }

let launch_ffi =
  {
    file = "ash-launch-ffi";
    command = Some "launch-ffi";
    summary =
      "execute a virtle manifest's plan in-process via the virtle library";
    man =
      [
        `S Manpage.s_description;
        `P
          "Renders a virtle manifest's launch plan through the virtle Go \
           library (libvirtle.so) and executes it from ash: prepares runtime \
           directories, starts host run processes and QEMU, waits for the QMP \
           socket, and holds until the VM exits. While running it serves the \
           virtle control socket (virtle.sock under the manifest state \
           directory) with status and guest-exec proxied to the guest agent, \
           so the VM is visible to ash ls/attach/stop/inspect. On SIGTERM (ash \
           stop) it asks the guest to power down before exiting. Guest serial \
           output goes to stderr. Requires qemu-system-* on PATH.";
        `S Manpage.s_examples;
        `Pre "ash launch-ffi --manifest virtle.toml";
        `Pre "ash launch-ffi --manifest virtle.toml --cid 7";
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
           virtle mounts and files, and runtime mount owners stored in \
           ash-state.toml.";
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
          "regenerate rewrites virtle.toml, ash-state.toml, and generated \
           helper files such as ssh-with-space-mounts. Runtime desired state \
           is preserved while resolved spawn fields are refreshed.";
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

let rebuild_db =
  {
    file = "ash-rebuild-db";
    command = Some "rebuild-db";
    summary = "rebuild a VM's Nix store database";
    man =
      [
        `S Manpage.s_description;
        `P
          "Deletes the named VM's strategy-specific Nix store state, then \
           regenerates it from the VM's saved ash-state.toml and current NixOS \
           closure.";
        `S "WHAT IT RESETS";
        `P
          "For strategy=shared, rebuild-db removes only the Nix-related \
           directories below shares/{ro,rw}/system, including local-overlay \
           metadata, upper, and work directories. For strategy=image, it \
           removes nix-store.img and its closure marker but preserves the \
           closure base under $XDG_CACHE_HOME/$ASH_NAME/nix-store-images. \
           ASH_NAME defaults to ash. The replacement image reuses that cache \
           when the closure matches. In either case, guest-installed store \
           paths are discarded.";
        `S "SAFETY";
        `P
          "The VM must be stopped. persist.img, workspace, SSH keys, runtime \
           mount state, and other non-store share data are preserved.";
        `S "REGENERATION";
        `P
          "After removing the store state, ash resolves the saved flake again, \
           prepares the configured store strategy, and regenerates virtle.toml \
           and SSH helper scripts. The next normal spawn starts with the \
           rebuilt store.";
        `S Manpage.s_examples;
        `Pre "ash stop work";
        `Pre "ash rebuild-db work";
        `Pre "ash attach --spawn work";
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
          "ash stages the host directory below \
           shares/{ro,rw}/mounts/hotmounts, exposes it through the matching \
           consolidated share, then uses virtle guest-exec to bind it at \
           GUEST_PATH inside the guest.";
        `P
          "The guest shares-ro or shares-rw root is mounted lazily when \
           needed. --mode controls guest access: rw is the default; ro uses \
           the read-only share and a read-only bind mount.";
        `P
          "The desired mount is recorded atomically in ash-state.toml before \
           guest realization. Later starts and resumes retry any missing host \
           staging or guest bind mount.";
        `S "REQUIREMENTS";
        `P "The VM must be running and QEMU Guest Agent must be available.";
        `S Manpage.s_examples;
        `Pre "ash mount work ~/dev/project";
        `Pre "ash mount --mode ro work ~/src/nixpkgs:~/nixpkgs";
      ];
  }

let cp =
  {
    file = "ash-cp";
    command = Some "cp";
    summary = "copy files between the host and a running VM";
    man =
      [
        `S Manpage.s_description;
        `P
          "Copies a file between the host and a running ash VM. The default \
           direction is host to guest; use --from guest for guest to host.";
        `S "DIRECTORIES";
        `P
          "Pass -r or --recursive to copy a directory and its contents. \
           Without it, directory sources are rejected by scp.";
        `S "VM SELECTION";
        `P
          "NAME selects the running VM. The transfer uses that VM's SSH user \
           and vsock CID.";
        `S "SSH";
        `P
          "ash creates or reuses the VM's autoprovisioned SSH identity, \
           installs it through virtle guest-exec, and transfers through \
           OpenSSH scp over the generated SSH wrapper.";
        `P
          "-v or --verbose prints the completed host/guest source and \
           destination after a successful transfer.";
        `S Manpage.s_examples;
        `Pre "ash cp work ./notes.txt ~/workspace/notes.txt";
        `Pre "ash cp -r work ./src ~/workspace/src";
        `Pre "ash cp --from guest work ~/workspace/result.txt ./result.txt";
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
          "Each requested space is resolved to a mount snapshot and recorded \
           in ash-state.toml with a space ownership claim before \
           reconciliation.";
        `P
          "Read-only space mounts stay read-only. Overlapping spaces share one \
           resolved mount with multiple ownership claims, so removing one \
           space does not remove a mount still required by another owner.";
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
          "ash removes each SPACE ownership claim from the resolved snapshot \
           already stored in ash-state.toml; it does not re-resolve the \
           current config while unmounting.";
        `P
          "A guest and host staging mount is removed only when no manual or \
           space owners remain.";
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
    summary = "select and delete VM state or cached images";
    man =
      [
        `S Manpage.s_description;
        `P
          "Opens an interactive multi-select picker for deleting stopped ash \
           VM state directories and cached image-backed Nix store bases.";
        `S "SAFETY";
        `P
          "Only stopped VM states are shown. Running VMs are not selectable \
           for deletion. Cached bases are safe to remove while VMs are running \
           because each VM uses its own writable clone.";
        `P
          "Deleting a VM removes its state directory, including generated \
           manifests, SSH keys, hotmount staging data, workspace data, and \
           persistent images. Deleting a cache entry removes its base image \
           and closure marker; a later spawn rebuilds the base if needed.";
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
    cp;
    umount;
    mount_space;
    umount_space;
    stop;
    logs;
    regenerate;
    rebuild_db;
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
<div class="foot"><span>%s</span><span class="center">ash 0.1.7</span><span class="right">%s</span></div>
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
<div class="foot"><span>ash(1)</span><span class="center">ash 0.1.7</span><span class="right">ash(1)</span></div>
</body>
</html>
|}
    (normalize_base_href base_href)
    man7_css items
