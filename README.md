# ash

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

Spawn options:

- `-p`, `--profile PROFILE` — repeatable agent-box profile; profiles supply mount points.
- `-f`, `--flake FLAKE#HOST` — required flake directory plus host reference, e.g. `../my-nix#agent`. `HOST` is resolved as `nixosConfigurations.<HOST>`. Pass the flake directory, not `flake.nix`.
- `--name NAME` — VM/state name. Default: current directory basename plus timestamp, e.g. `ash-20260708193000`.
- `-u`, `--user USER` — guest SSH user. Defaults to `runtime.qemu.ssh_user` from config, then `agent`.
- `-c`, `--config CONFIG` — agent-box style config. Default: `~/.agent-box.toml`.
- `--ssh PATH` — override path to host `ssh`. Defaults to the selected NixOS config's `pkgs.openssh`.
- `--systemd-ssh-proxy PATH` — override path to host `systemd-ssh-proxy`. Defaults to the selected NixOS config's `config.systemd.package`.
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

- If no `-p`/`--profile` is passed, `ash` uses `default_profile` from the config, falling back to `base`.
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
- `ro-store` — readonly virtiofs share for the host `/nix/store`
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

Not every exposed mount must be mounted by the guest, but features depending on a path require the matching mount. For example, `--mount-cwd` sets `workspace.mount_cwd = true` and expects `workspace_cwd` to be mounted at `/mnt/cwd` inside the guest.

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

Current development guest auth uses an empty password for the `agent` user, with OpenSSH and PAM configured to permit empty-password login. This is a development-only convenience while `ash`/guest bootstrapping is being stabilized. Long term, the guest should move to key-only auth, ideally using `virtle` SSH autoprovisioning or configured authorized keys.

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
