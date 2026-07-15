# ash - (a)gent (sh)ell

A small OCaml CLI for spawning, attaching to, and managing optionally ephemeral NixOS agent VMs via [`virtle`](https://github.com/shazow/virtle), with profile-based mounts from an [`agent-box`](https://github.com/0xferrous/agent-box) TOML config.

## Quickstart

```sh
nix build
./result/bin/ash spawn --name work -f ../my-nix#agent --mount-cwd
./result/bin/ash attach work
./result/bin/ash stop work
./result/bin/ash ls
./result/bin/ash rm
```

`ash rm` opens an interactive multi-select TUI for deleting VM state directories. State lives under `~/.local/state/ash/<name>/` by default.

## Interface

```sh
ash spawn -p rust -p go --flake path/to/flake#agent
```

Short form:

```sh
ash spawn -p rust -p go -f ../my-nix#agent
```

Mount the current repository into the guest workspace:

```sh
ash spawn -p rust -f ../my-nix#agent --mount-cwd
```

Reuse the same VM state and persistent image across runs:

```sh
ash spawn --name rustbox -p rust -f ../my-nix#agent
```

SSH into an already running VM by name:

```sh
ash attach rustbox
```

If exactly one VM is running, the name can be omitted:

```sh
ash attach
```

Attach can also spawn a stopped VM from saved ash state:

```sh
ash attach --spawn rustbox
ash attach --spawn --keep rustbox
```

Stop an ash background VM:

```sh
ash stop rustbox
```

Shared options, accepted by commands that use them:

- `--debug` — enable ash debug logging. Can also be enabled with `ASH_LOG=debug`.
- `--virtle PATH` — path to `virtle`. Defaults to `$ASH_VIRTLE`, then `virtle` from `PATH`. Used by `spawn` and `attach`.
- `-v`, `--verbose` — for `spawn`, passed to `virtle`; for `attach`, passed to `ssh`; repeatable.

When invoking through `nix run`, pass app arguments after `--` if they begin with `-`, for example:

```sh
nix run . -- attach --virtle ./result/bin/virtle rustbox
```

## External commands

`ash` is a coordinator. It calls these host-side binaries:

- `nix` — evaluates the selected flake/NixOS configuration for kernel, initrd, toplevel, kernel params, `ssh`, and `systemd-ssh-proxy` paths.
- `virtle` — validates, launches, controls, and queries VMs. Defaults to `$ASH_VIRTLE`, then `virtle` from `PATH`; override with `--virtle PATH`.
- `virtiofsd` — used by generated manifests for ash-managed virtiofs mounts. Resolved from `PATH` at spawn time and stored in the manifest.
- `bindfs` — used by `ash mount` to mirror a host directory into the VM state's `hotmounts` directory before exposing it through the VM's `hotmounts` virtiofs share. Ash invokes it with `--multithreaded --no-allow-other` to avoid older single-threaded FUSE `-s` compatibility issues and host FUSE setups where `allow_other` is unavailable; for read-only mounts ash adds bindfs' `-r` flag. This assumes virtiofsd can access the bindfs mount as the same host user that ran ash/virtle. Some FUSE setups also reject bindfs' internal `default_permissions` option; in that case ash falls back to a kernel `mount --bind` staging mount if the host permits it.
- `mountpoint` — used by `ash mount` to avoid remounting an already-mounted host-side hotmount directory.
- `ssh` — host SSH client used for attached sessions. Defaults to the selected NixOS config's `pkgs.openssh`; override with `--ssh PATH`.
- `systemd-ssh-proxy` — host SSH proxy used for vsock SSH connections. Defaults to the selected NixOS config's `config.systemd.package`; override with `--systemd-ssh-proxy PATH`.
- `systemd-run` — starts background VMs as transient user units for `ash spawn`, `ash spawn --attach --keep`, and `ash attach --spawn --keep`.
- `systemctl` — checks/stops ash-owned background units for `ash stop`.
- `ssh-keygen` — creates ash's SSH autoprovisioning key when needed.
- `/bin/sh` — used internally to run small shell commands and capture output.
- `du` — used by `ash ls`/state listing to estimate VM state disk usage, excluding the VM state's `hotmounts` staging directory; ash falls back to walking the directory tree if it fails.

`ash` also prints a `journalctl --user -u ash-<name>.service -f` hint for background VMs, but does not run `journalctl` itself.

Some operations execute commands inside the guest through `virtle rpc guest-exec`, such as mounting profile/workspace/hotmount virtiofs tags and installing ash's SSH public key. Those commands use guest paths like `/run/current-system/sw/bin/sh`, `mount`, `mountpoint`, `install`, `stat`, `mkdir`, `chown`, `chmod`, and `grep`; they must exist in the guest image.

Spawn options:

- `-p`, `--profile PROFILE` — repeatable agent-box profile; profiles supply mount points.
- `-f`, `--flake FLAKE#HOST` — required flake directory plus host reference, e.g. `../my-nix#agent`. `HOST` is resolved as `nixosConfigurations.<HOST>`. Pass the flake directory, not `flake.nix`.
- `--name NAME` — VM/state name. Default: current directory basename plus timestamp, e.g. `ash-20260708193000`.
- `-u`, `--user USER` — guest SSH user. Defaults to `runtime.qemu.ssh_user` from config, then `agent`.
- `-c`, `--config CONFIG` — agent-box style config. Default: `~/.agent-box.toml`.
- `--ssh PATH` — override path to host `ssh`. Defaults to the selected NixOS config's `pkgs.openssh`.
- `--systemd-ssh-proxy PATH` — override path to host `systemd-ssh-proxy`. Defaults to the selected NixOS config's `config.systemd.package`.
- `--ro-store-socket PATH` — use an existing virtiofs daemon socket for the read-only `/nix/store` mount instead of starting ash's own `ro-store` virtiofsd.
- `--print-serial` — print guest kernel/init serial output while booting.
- `--mount-cwd` — mount the current host working directory under the guest workspace. Off by default.
- `--attach` — attach after spawning. Without `--keep`, the VM stops when SSH exits.
- `--keep` — with `--attach`, start as a background VM and keep it running after SSH exits. Plain `spawn` already keeps the VM, so `--keep` requires `--attach`.
- `--ephemeral` — remove the VM state directory after the launched SSH/VM session exits. Requires `--attach` and cannot be used with `--keep`.

Attach options:

- `--spawn` — if the named VM is stopped, load its saved `ash.toml`, regenerate the manifest, start it, then attach.
- `--keep` — with `--spawn`, start the stopped VM as a background systemd unit and keep it running after SSH exits. `ash attach --keep` without `--spawn` is invalid.

## Lifecycle commands

| Command | If stopped | Attach? | SSH exit stops VM? |
|---|---|---:|---:|
| `ash spawn` | start background systemd user unit | no | no |
| `ash spawn --attach` | start foreground VM | yes | yes |
| `ash spawn --attach --keep` | start background systemd user unit | yes | no |
| `ash attach` | error | yes, if already running | no |
| `ash attach --spawn` | start foreground VM from saved state | yes | yes |
| `ash attach --spawn --keep` | start background systemd user unit from saved state | yes | no |

Background VMs are owned by transient user systemd units named `ash-<name>.service`. `ash stop NAME` stops only those ash-owned background units. If a VM is running because of a foreground `ash spawn --attach` or `ash attach --spawn` session, `ash stop` refuses to stop it.

For `attach`, `--keep` is valid only with `--spawn`; `ash attach --keep` is rejected.

## What `spawn` does

For:

```sh
ash spawn -p rust -p go -f ../my-nix#agent
```

`ash` evaluates/builds the NixOS configuration at:

```text
../my-nix#nixosConfigurations.agent
```

and uses it for:

- kernel path
- initrd path
- kernel params
- NixOS toplevel init path
- OpenSSH package path for the host-side `ssh` command
- systemd package path for the host-side `systemd-ssh-proxy` command

Host-side `ssh` and `systemd-ssh-proxy` are resolved from the selected NixOS configuration unless overridden with `--ssh` and `--systemd-ssh-proxy`.

The selected `FLAKE#HOST` must expose a normal NixOS configuration with these attributes:

```text
nixosConfigurations.<HOST>.config.system.build.kernel
nixosConfigurations.<HOST>.config.system.boot.loader.kernelFile
nixosConfigurations.<HOST>.config.system.build.initialRamdisk
nixosConfigurations.<HOST>.config.system.build.toplevel
nixosConfigurations.<HOST>.config.boot.kernelParams
nixosConfigurations.<HOST>.pkgs.openssh
nixosConfigurations.<HOST>.config.systemd.package
```

Then it reads the selected profiles from `~/.agent-box.toml` and turns their mounts into `virtle` `virtiofs` mounts.

Profile selection is explicit:

- If no `-p`/`--profile` is passed for a new VM, `ash` uses `default_profile` from the config, falling back to `base`.
- If no `-p`/`--profile` is passed for an existing named VM with saved `ash.toml`, `ash` reuses the saved profile list.
- If one or more profiles are passed, `ash` uses exactly those profiles. It does not automatically add `default_profile`.
- Shared/base profile behavior should be expressed with profile `extends` in the config.

Profile entries preserve the intended guest path in the generated manifest:

- `mounts.*.home_relative` maps host paths under the host user's home to the same relative path under the guest SSH user's home. For example, host `~/.cargo` targets guest `/home/agent/.cargo`.
- `mounts.*.absolute` maps paths to the same absolute path in the guest. For example, host `/var/cache/foo` targets guest `/var/cache/foo`.

Existing file entries are emitted as `[[write_files]]` instead of virtiofs mounts. Read-only file entries are copied into the guest; read-write/overlay file entries also set `write_back = true` so guest changes are copied back to the host source during teardown. Profiles with file entries require the guest to run QEMU Guest Agent, because `virtle` applies `write_files` through QGA.

Existing directory entries are emitted as launch-time `[[mounts]]` with a `target`. Missing profile paths are skipped with a warning.

Limitation: `virtle` only uses `target` for `[[hotplug.mounts]]`, not launch-time `[[mounts]]`. As a result, directory profile mounts are exposed to the guest as virtiofs tags/devices, but are not automatically mounted at their target paths during launch. Guest config or manual mount commands must mount those tags for now.

It also exposes these mount devices to the guest:

- `workspace` — writable virtiofs share for `<state_dir>/workspace`, intended for `/home/<ssh-user>/workspace`
- `hotmounts` — writable virtiofs share for `<state_dir>/hotmounts`, used by `ash mount` for QGA-driven hot mounts into a running VM.
- `ro-store` — readonly virtiofs share for the host `/nix/store`. By default ash starts a virtiofsd using `ro-store.sock`; pass `--ro-store-socket PATH` to point this mount at an existing virtiofs daemon socket instead.
- `persist` — writable ext4 image labeled `persist`
- `workspace_cwd` — virtiofs share for the host current working directory, only when `--mount-cwd` is passed

The guest may mount these tags/labels as needed. The current agent guest config mounts them as:

```nix
fileSystems."/home/agent/workspace" = {
  device = "workspace";
  fsType = "virtiofs";
};

fileSystems."/nix/store" = {
  device = "ro-store";
  fsType = "virtiofs";
  options = [ "ro" ];
};

fileSystems."/persist" = {
  device = "/dev/disk/by-label/persist";
  fsType = "ext4";
};

fileSystems."/mnt/cwd" = {
  device = "workspace_cwd";
  fsType = "virtiofs";
};
```

Not every exposed mount must be mounted by the guest, but features depending on a path require the matching mount. For example, `--mount-cwd` sets `workspace.mount_cwd = true` and expects `workspace_cwd` to be mounted at `/mnt/cwd` inside the guest. `ash mount [--mode ro|rw] NAME HOST_PATH[:GUEST_PATH]` mounts `HOST_PATH` into `<state_dir>/hotmounts` with `bindfs`, then uses QGA to mount the `hotmounts` virtiofs tag at `/run/ash/hotmounts` if needed and bind-mount the selected subdirectory onto `GUEST_PATH`. If `GUEST_PATH` starts with `~`, ash resolves it using the guest SSH user's home; if it is omitted, ash uses the absolute host path. `ash umount NAME GUEST_PATH` unmounts the guest target and tears down the host-side staging mount recorded for that guest path, falling back to lazy FUSE unmount if virtiofsd still briefly holds the staging mount busy. `ash mount-profile NAME PROFILE...` resolves one or more agent-box profiles from the VM's saved config and hotmounts each directory mount at its profile target; read-only profile mounts become read-only hotmounts. `ash umount-profile NAME PROFILE...` resolves the same profile mount targets and unmounts them as a batch. Runtime profile mounting skips profile file entries for now. Overlay mode is intentionally left for later.

`ash` uses `/home/<ssh-user>/workspace` as the guest workspace directory. For the default `agent` user, this is `/home/agent/workspace`. The SSH user can be overridden per run with `--user`; `ash` validates that the selected NixOS configuration defines `users.users.<user>`. If the guest mounts the `workspace` tag via static guest config, that config must use the same user/path.

`ash` currently enables `ssh.autoprovision = true` in the generated manifest, so the guest should run QEMU Guest Agent and respond on the generated `qga.sock`. Passing `--mount-cwd` also requires QGA because `virtle` uses guest commands to bind-mount the workspace. For NixOS guests, enable:

```nix
services.qemuGuest.enable = true;
```

## Guest SSH contract

`ash spawn --attach`, `ash attach`, and other attached flows use an SSH command that connects through vsock using `systemd-ssh-proxy`:

```text
ssh -o 'ProxyCommand=<systemd>/lib/systemd/systemd-ssh-proxy %h %p' -o ProxyUseFdpass=yes <user>@vsock/<cid>
```

The guest is expected to provide an SSH service reachable through that vsock/systemd path. The generated manifest also sets:

```toml
[ssh]
ready_socket = "ready.sock"
autoprovision = true
```

For readiness, the guest must write this exact token:

```text
SSH-READY
```

to the virtio-serial port exposed by `virtle`:

```text
/dev/virtio-ports/virtle.ready
```

The current agent guest config implements this with a `virtle-ssh-signal.service` that runs after `sshd.service`.

For attached flows, `ash` uses SSH key autoprovisioning when the manifest has `ssh.autoprovision = true`. It creates or reuses an `id_ed25519` key under the VM state directory, installs the public key through virtle's guest-agent control RPC, and attaches with that identity. This is needed for background-spawned VMs because virtle's own SSH autoprovisioning only runs from `virtle launch --ssh`.

Current assumption: the guest SSH user's primary writable group is `users`. During ash-side autoprovisioning, ash creates `/home/<user>/.ssh` or `/root/.ssh`, appends its public key to `authorized_keys`, then runs `chown <user>:users` and sets OpenSSH-compatible permissions. This matches the current NixOS agent guest setup; guests with a different group convention should either provide compatible users/groups or disable ash/virtle SSH autoprovisioning and preconfigure authorized keys.

The generated manifest is written under:

```text
$XDG_STATE_HOME/ash/<name>/virtle.toml
```

or, if `XDG_STATE_HOME` is unset:

```text
~/.local/state/ash/<name>/virtle.toml
```

If `--name` is not passed, `ash` generates a name from the current directory basename and timestamp, such as `ash-20260708193000`. Passing the same `--name` reuses the same state directory and persistent image. For state paths, names preserve letters, digits, `.`, `_`, and `-`; other characters are replaced with `-`.

Plain `ash spawn` starts `virtle launch` under a transient user systemd unit:

```sh
systemd-run --user --unit ash-NAME --collect --same-dir virtle --manifest GENERATED launch
```

`ash spawn --attach` runs foreground and attaches SSH:

```sh
virtle --manifest GENERATED launch --ssh
```

To attach to an already running named VM, `ash attach NAME` reads the existing generated manifest under the VM state directory, asks the running `virtle` control socket for its vsock CID, and executes the manifest's SSH command. If no name is supplied, `ash attach` only succeeds when exactly one VM is running. `ash attach --spawn NAME` can start a stopped VM from its saved `ash.toml`; add `--keep` to start it as a background systemd unit instead of a foreground VM that stops on SSH exit.

Host-side SSH attach requires `ssh` and `systemd-ssh-proxy`. `ash` resolves them from the selected NixOS config by default, unless `--ssh` or `--systemd-ssh-proxy` are passed, and writes the resolved absolute paths into the generated manifest.

Host-side virtiofs mounts require `virtiofsd`. `ash` resolves `virtiofsd` from `PATH` before launch and writes the resolved absolute path into the generated manifest.

`ash` currently emits `kvm = true` in the generated manifest, so the host is expected to provide usable KVM acceleration, typically via `/dev/kvm` on Linux.

## Build

```sh
nix build
./result/bin/ash --help
```
