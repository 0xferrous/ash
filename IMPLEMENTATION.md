# ash - (a)gent (sh)ell

A small OCaml CLI for spawning, attaching to, and managing optionally ephemeral NixOS agent VMs via [`virtle`](https://github.com/shazow/virtle), with space-based mounts from ash's TOML config.

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
ash spawn -s rust -s go --flake path/to/flake#agent
```

Short form:

```sh
ash spawn -s rust -s go -f ../my-nix#agent
```

Mount the current repository into the guest workspace:

```sh
ash spawn -s rust -f ../my-nix#agent --mount-cwd
```

Reuse the same VM state and persistent image across runs:

```sh
ash spawn --name rustbox -s rust -f ../my-nix#agent
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

- `nix` — evaluates the selected flake/NixOS configuration for kernel, initrd, toplevel, kernel params, a `pkgs.closureInfo` registration dump, `ssh`, and `systemd-ssh-proxy` paths.
- `virtle` — validates, launches, controls, and queries VMs. Defaults to `$ASH_VIRTLE`, then `virtle` from `PATH`; override with `--virtle PATH`.
- `virtiofsd` — used by generated manifests for ash-managed virtiofs mounts. Resolved from `PATH` at spawn time and stored in the manifest.
- `bindfs` — creates host-side staging mounts for runtime hotmounts. See [Runtime hotmount implementation](#runtime-hotmount-implementation).
- `mountpoint` — used by `ash mount` to avoid remounting an already-mounted host-side hotmount directory.
- `ssh` — host SSH client used for attached sessions. Defaults to the selected NixOS config's `pkgs.openssh`; override with `--ssh PATH`.
- `systemd-ssh-proxy` — host SSH proxy used for vsock SSH connections. Defaults to the selected NixOS config's `config.systemd.package`; override with `--systemd-ssh-proxy PATH`.
- `systemd-run` — starts background VMs as transient user units for `ash spawn`, `ash spawn --attach --keep`, and `ash attach --spawn --keep`.
- `systemctl` — checks/stops ash-owned background units for `ash stop`.
- `journalctl` — reads logs from ash-owned background units for `ash logs`.
- `ssh-keygen` — creates ash's SSH autoprovisioning key when needed.
- `/bin/sh` — used internally to run small shell commands and capture output.
- `du` — used by `ash ls`/state listing to estimate VM state disk usage, excluding the VM state's `hotmounts` staging directory; ash falls back to walking the directory tree if it fails.

`ash logs NAME` runs `journalctl --user --unit ash-<name>.service --invocation=0` so only the latest process invocation is shown, with 100 recent lines by default. It requests JSON records and formats each entry as `[YYYY-MM-DD HH:MM:SS] MESSAGE`, omitting hostname and process metadata. `--lines`/`-n` changes the count, and `--follow`/`-f` follows new entries. Background spawn prints `ash logs -f NAME` as a hint. Invocation filtering requires systemd 257 or newer.

`ash inspect NAME` emits a concise human-readable summary for a running or stopped VM, covering runtime/storage status, saved flake and spaces, machine resources, configured mounts/files, workspace paths, and hotmount desired state. `ash inspect --json NAME` emits the complete machine-readable object: it converts the saved `ash-state.toml`, referenced ash config TOML, and generated `virtle.toml` documents to JSON; reports state sizes and persist/workspace artifacts; includes parsed hotmount desired state and malformed metadata; and checks host staging mountpoints. For running VMs the JSON view additionally queries the virtle control socket for raw status and the guest kernel mount table through QGA.

Some operations execute commands inside the guest through `virtle rpc guest-exec`, such as loading the selected system closure into the guest Nix database, mounting space/workspace/hotmount virtiofs tags, installing ash's SSH public key, and collecting `ash ls` SSH statistics. Those commands use guest paths like `/run/current-system/sw/bin/sh`, `nix-store`, `mount`, `mountpoint`, `install`, `stat`, `mkdir`, `chown`, `chmod`, `grep`, `ss`, `awk`, and `who`; they must exist in the guest image. For each running VM, `ash ls` queries QGA directly through the virtle control socket: SSH is the number of established AF_VSOCK stream sockets whose guest-local port is 22, and PTY is the number of `pts/*` login records with the AF_VSOCK `UNKNOWN` remote marker. If the query fails, both columns show a dash.

Spawn options:

- `-s`, `--space SPACE` — repeatable ash config space; spaces supply mount points. New VMs apply no spaces when omitted; existing named VMs reuse the saved space list.
- `-f`, `--flake FLAKE#HOST` — flake directory plus host reference, e.g. `../my-nix#agent`. Required for a new VM; when spawning an existing named VM, omitting it reuses the value saved in `ash-state.toml`. `HOST` is resolved as `nixosConfigurations.<HOST>`. Pass the flake directory, not `flake.nix`.
- `--name NAME` — VM/state name. Default: current directory basename plus timestamp, e.g. `ash-20260708193000`.
- `-u`, `--user USER` — override the guest SSH user. The default is evaluated from `config.services.getty.autologinUser` in the selected NixOS configuration.
- `-c`, `--config CONFIG` — ash config. Default: `$XDG_CONFIG_HOME/ash/config.toml`, falling back to `~/.config/ash/config.toml`.
- `--ssh PATH` — override path to host `ssh`. Defaults to the selected NixOS config's `pkgs.openssh`.
- `--systemd-ssh-proxy PATH` — override path to host `systemd-ssh-proxy`. Defaults to the selected NixOS config's `config.systemd.package`.
- `--ro-store-socket PATH` — use an existing virtiofs daemon socket for the read-only `/nix/store` mount instead of starting ash's own `ro-store` virtiofsd.
- `--print-serial` — print guest kernel/init serial output while booting.
- `--mount-cwd` — mount the current host working directory under the guest workspace. Off by default.
- `--attach` — attach after spawning. Without `--keep`, the VM stops when SSH exits.
- `--keep` — with `--attach`, start as a background VM and keep it running after SSH exits. Plain `spawn` already keeps the VM, so `--keep` requires `--attach`.
- `--ephemeral` — remove the VM state directory after the launched SSH/VM session exits. Requires `--attach` and cannot be used with `--keep`.

Attach options:

- `--spawn` — if the named VM is stopped, load its saved `ash-state.toml`, regenerate the manifest, start it, then attach.
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

Background VMs are owned by transient user systemd units named `ash-<name>.service`. `ash stop NAME` stops only those ash-owned background units. If a VM is running because of a foreground `ash spawn --attach` or `ash attach --spawn` session, `ash stop` refuses to stop it. Before stopping a background unit, ash queries the same QGA SSH/PTY statistics used by `ash ls`; when one or more SSH connections are active, it logs a warning with both counts and asks for interactive confirmation. A non-interactive stop with active connections is refused unless `--force` is passed.

For `attach`, `--keep` is valid only with `--spawn`; `ash attach --keep` is rejected.

## What `spawn` does

For:

```sh
ash spawn -s rust -s go -f ../my-nix#agent
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
- a `pkgs.closureInfo` registration dump rooted at the exact selected toplevel
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
nixosConfigurations.<HOST>.config.services.getty.autologinUser
nixosConfigurations.<HOST>.config.users.users.<USER>.name
```

Then it reads selected spaces from `$XDG_CONFIG_HOME/ash/config.toml` (falling back to `~/.config/ash/config.toml`, or using `--config`) and turns their `rw_mounts` and `ro_mounts` into `virtle` virtiofs mounts. A space may define `extends = ["base", ...]`; ash traverses these dependencies recursively in declaration order, evaluates dependencies before dependents, and evaluates each reachable space once. Unknown spaces and inheritance cycles are fatal configuration errors.

Space selection is explicit:

- If no `-s`/`--space` option is passed for a new VM, no configured spaces are applied.
- If no `-s`/`--space` option is passed for an existing named VM, `ash` reuses the saved space list.
- If `-f`/`--flake` is omitted for an existing named VM with saved `ash-state.toml`, `ash` reuses the saved flake; new VMs still require it.
- If one or more spaces are passed, `ash` uses exactly those spaces and replaces the saved selection.

Each mount entry is either `HOST_PATH` or `HOST_PATH:GUEST_PATH`. Host `~` resolves against the host user's home. Guest `~` resolves against the evaluated guest SSH user's home. When the guest path is omitted, the original host path string is reused and resolved for the guest. Absolute paths are accepted on both sides. Missing host paths are skipped with a warning. Mounts are deduplicated after parsing and path expansion by source, target, and read-only mode, preserving the first occurrence.

The guest SSH user defaults to `config.services.getty.autologinUser` from the selected NixOS configuration. `--user` overrides it, and ash validates the result through `config.users.users.<user>.name`.

It also exposes these mount devices to the guest:

- `workspace` — writable virtiofs share for `<state_dir>/workspace`, intended for `/home/<ssh-user>/workspace`
- `hotmounts` — writable virtiofs share for `<state_dir>/hotmounts`, used by `ash mount` for QGA-driven hot mounts into a running VM.
- `ro-store` — readonly virtiofs share for the host `/nix/store`. By default ash starts a virtiofsd using `ro-store.sock`; pass `--ro-store-socket PATH` to point this mount at an existing virtiofs daemon socket instead.
- `persist` — writable ext4 image labeled `persist`
- `workspace_cwd` — virtiofs share for the host current working directory, only when `--mount-cwd` is passed

Ash also builds `pkgs.closureInfo { rootPaths = [ toplevel ]; }` for the exact resolved NixOS toplevel. The kernel, initrd, toplevel, and closure-info outputs are built with indirect GC roots under `<state_dir>/gcroots/`; the closure-info output contains the `registration` file, while the toplevel root retains its transitive system closure. The roots remain valid for stopped VMs and disappear automatically when the VM state directory is deleted, including ephemeral cleanup.

After guest readiness and before ash-managed mounts, ash imports the resulting `registration` file with guest-root `nix-store --load-db`. Foreground attach flows perform the same operation in the generated SSH wrapper. A marker under `/run/ash/nix-registration/` avoids repeating the import during the same boot; because `/run` is volatile, every new boot imports the registration again. The resolved registration path is saved in `ash-state.toml`, not the virtle manifest, because it is consumed by ash rather than virtle.

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

## Runtime hotmount implementation

`ash mount [--mode ro|rw] NAME HOST_PATH[:GUEST_PATH]` uses this path:

```text
host directory
  -> bindfs staging mount under <state_dir>/hotmounts/<id>
  -> hotmounts virtiofs share
  -> /run/ash/hotmounts in guest
  -> guest bind mount at GUEST_PATH
```

For writable staging mounts ash runs:

```sh
bindfs --multithreaded --no-allow-other \
  -o attr_timeout=0,entry_timeout=0,negative_timeout=0 SOURCE TARGET
```

Read-only mounts add `-r`. The options avoid bindfs' default single-threaded FUSE mode, avoid requiring `allow_other`, and disable metadata caches. If bindfs fails and ash is running as root, ash can fall back to a kernel `mount --bind`. Mutable virtiofs shares (`workspace`, selected space directories, `hotmounts`, and `workspace_cwd`) use `--cache=never`; the immutable `/nix/store` share keeps virtiofsd's default cache behavior.

Ash stores each persistent desired-state record at:

```text
<state_dir>/hotmounts/.ash/<source_name>.meta
```

with this line-oriented format:

```text
<guest_path>
<host_dir>
<mode>
<source_name>
```

Metadata writes use temporary-file-plus-rename atomic replacement. Mount, unmount, and startup reconciliation are serialized by a per-VM advisory lock.

Host staging teardown tries, in order:

1. `fusermount3 -u`
2. `fusermount3 -uz`
3. `fusermount -u`
4. `fusermount -uz`
5. root-only `umount`

The lazy variants handle virtiofsd briefly keeping the staging mount busy.

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

Ash keeps its manifests, configuration, workspace, persistent image, and other managed files directly under `~/.local/state/ash/<name>/` (or the equivalent `XDG_STATE_HOME` path). The generated manifest sets virtle's own `state_dir` to the nested `virtle_state/` directory, so virtle runtime files and control sockets live under `~/.local/state/ash/<name>/virtle_state/`.

Plain `ash spawn` starts `virtle launch` under a transient user systemd unit:

```sh
systemd-run --user --unit ash-NAME --collect --same-dir virtle --manifest GENERATED launch
```

`ash spawn --attach` runs foreground and attaches SSH:

```sh
virtle --manifest GENERATED launch --ssh
```

To attach to an already running named VM, `ash attach NAME` reads the existing generated manifest under the VM state directory, asks the running `virtle` control socket for its vsock CID, and executes the manifest's SSH command. If no name is supplied, `ash attach` only succeeds when exactly one VM is running. `ash attach --spawn NAME` can start a stopped VM from its saved `ash-state.toml`; add `--keep` to start it as a background systemd unit instead of a foreground VM that stops on SSH exit.

Host-side SSH attach requires `ssh` and `systemd-ssh-proxy`. `ash` resolves them from the selected NixOS config by default, unless `--ssh` or `--systemd-ssh-proxy` are passed, and writes the resolved absolute paths into the generated manifest.

Host-side virtiofs mounts require `virtiofsd`. `ash` resolves `virtiofsd` from `PATH` before launch and writes the resolved absolute path into the generated manifest.

`ash` currently emits `kvm = true` in the generated manifest, so the host is expected to provide usable KVM acceleration, typically via `/dev/kvm` on Linux.

## Build

```sh
nix build
./result/bin/ash --help
```
