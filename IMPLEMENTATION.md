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

`ash rm` opens an interactive multi-pane TUI for deleting stopped VM state directories or cached image-backed Nix store bases. Cache entries show the number of VM states whose current image metadata matches the cached closure, with the VM names and provenance details in the detail footer; `u` selects every unreferenced cache entry in the active cache pane. `ash ls --cache` provides the same cache inventory non-interactively, including disk and virtual sizes, modification and last-use times, reference and closure-path counts, NAR size, closure, origin, and path. Removing a cached base deletes its adjacent TOML sidecar but does not affect writable VM clones; a later spawn rebuilds the base if needed. State lives under `~/.local/state/$ASH_NAME/<name>/`, with `ASH_NAME` defaulting to `ash`.

## Interface

```sh
ash spawn -s rust -s go --flake path/to/flake#agent
```

Short form, with a local flake input override:

```sh
ash spawn -s rust -s go -f ../my-nix#agent \
  --override-input ash=path:../ash
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

- `nix` — evaluates the selected flake/NixOS configuration for kernel, initrd, toplevel, kernel params, `ssh`, and `systemd-ssh-proxy` paths, and queries recursive store metadata for Ash's native registration dump.
- `virtle` — validates, launches, controls, and queries VMs. Defaults to `$ASH_VIRTLE`, then `virtle` from `PATH`; override with `--virtle PATH`.
- `virtiofsd` — used by generated manifests for ash-managed virtiofs mounts. Resolved from `PATH` at spawn time and stored in the manifest.
- `e2fsck` and `resize2fs` — check and grow an existing image-backed Nix store when `image_size_mib` increases. New images are created directly through Ash's `libext2fs` binding.
- `unshare` — prepares id-mapped writable store directories for the shared/local-overlay strategy when subordinate UID/GID ranges are available.
- `bindfs` — creates host-side staging mounts for runtime hotmounts. See [Runtime hotmount implementation](#runtime-hotmount-implementation).
- `mountpoint` — used by `ash mount` to avoid remounting an already-mounted host-side hotmount directory.
- `ssh` — host SSH client used for attached sessions. Defaults to the selected NixOS config's `pkgs.openssh`; override with `--ssh PATH`.
- `waypipe` — wraps attached sessions selected with `--waypipe`, forwarding guest Wayland and X11 applications to the host compositor. The packaged Ash CLI includes the host executable; source builds resolve it from `PATH`. The guest must provide both `waypipe` and `xwayland-satellite` in its SSH command `PATH`.
- `systemd-ssh-proxy` — host SSH proxy used for vsock SSH connections. Defaults to the selected NixOS config's `config.systemd.package`; override with `--systemd-ssh-proxy PATH`.
- `systemd-run` — starts background VMs as transient user units for `ash spawn`, `ash spawn --attach --keep`, and `ash attach --spawn --keep`.
- `agent-portal-host` — required when `[portal]` is enabled with `global = false`; resolved beside `ash`, from `ASH_AGENT_PORTAL_HOST`, or from `PATH`.
- `systemctl` — checks/stops ash-owned background units for `ash stop`.
- `journalctl` — reads logs from ash-owned background units for `ash logs`.
- `ssh-keygen` — creates ash's SSH autoprovisioning key when needed.
- `/bin/sh` — used internally to run small shell commands and capture output.
- `du` — used by `ash ls`/state listing to estimate VM state disk usage, excluding the VM state's `hotmounts` staging directory; ash falls back to walking the directory tree if it fails.

`ash logs NAME` runs `journalctl --user --unit ash-<name>.service --invocation=0` so only the latest process invocation is shown, with 100 recent lines by default. It requests JSON records and formats each entry as `[YYYY-MM-DD HH:MM:SS] MESSAGE`, omitting hostname and process metadata. `--lines`/`-n` changes the count, and `--follow`/`-f` follows new entries. Background spawn prints `ash logs -f NAME` as a hint. Invocation filtering requires systemd 257 or newer.

`ash inspect NAME` emits a concise human-readable summary for a running or stopped VM, covering runtime/storage status, saved flake and spaces, machine resources, configured mounts/files, workspace paths, and hotmount desired state. `ash inspect --json NAME` emits the complete machine-readable object: it converts the saved `ash-state.toml`, referenced ash config TOML, and generated `virtle.toml` documents to JSON; reports state sizes and persist/workspace artifacts; includes parsed hotmount desired state and malformed metadata; and checks host staging mountpoints. For running VMs the JSON view additionally queries the virtle control socket for raw status and the guest kernel mount table through QGA.

Some operations execute commands inside the guest through `virtle rpc guest-exec`, such as loading the selected system closure into the guest Nix database, mounting space/workspace/hotmount virtiofs tags, installing ash's SSH public key, and collecting `ash ls` runtime statistics. Those commands use guest paths like `/run/current-system/sw/bin/sh`, `nix-store`, `mount`, `mountpoint`, `install`, `stat`, `mkdir`, `chown`, `chmod`, `grep`, `ip`, `ss`, `awk`, and `who`; they must exist in the guest image. For each running VM, `ash ls` queries QGA directly through the virtle control socket. It matches the guest interface by ash's stable per-name MAC address and reports its first global IPv4 address. SSH is the number of established AF_VSOCK stream sockets whose guest-local port is 22, and PTY is the number of `pts/*` login records with the AF_VSOCK `UNKNOWN` remote marker. If the query fails, those columns show a dash.

Spawn options:

- `-s`, `--space SPACE` — repeatable ash config space; spaces supply mount points. New VMs apply no spaces when omitted; existing named VMs reuse the saved space list.
- `-f`, `--flake FLAKE#HOST` — flake directory plus host reference, e.g. `../my-nix#agent`. Required for a new VM; when spawning an existing named VM, omitting it reuses the value saved in `ash-state.toml`. `HOST` is resolved as `nixosConfigurations.<HOST>`. Pass the flake directory, not `flake.nix`.
- `--override-input NAME=FLAKE` — override an input of the selected flake during every Nix evaluation and build. Repeatable. Relative path references are resolved before being saved in `ash-state.toml`; an existing named VM reuses saved overrides when none are supplied.
- `--name NAME` — VM/state name. Default: current directory basename plus timestamp, e.g. `ash-20260708193000`.
- `-u`, `--user USER` — override the guest SSH user. The default is evaluated from `config.services.getty.autologinUser` in the selected NixOS configuration.
- `-c`, `--config CONFIG` — ash config. Default: `$XDG_CONFIG_HOME/$ASH_NAME/config.toml`, falling back to `~/.config/$ASH_NAME/config.toml`; `ASH_NAME` defaults to `ash`.
- `--ssh PATH` — override path to host `ssh`. Defaults to the selected NixOS config's `pkgs.openssh`.
- `--systemd-ssh-proxy PATH` — override path to host `systemd-ssh-proxy`. Defaults to the selected NixOS config's `config.systemd.package`.
- `--ro-store-socket PATH` — use an existing virtiofs daemon socket for the read-only `/nix/store` mount instead of starting ash's own `ro-store` virtiofsd.
- `--nix-store-strategy shared|image` — override `global.nix_store.strategy` for this VM and save it in `ash-state.toml`.
- `--nix-store-image-size-mib MIB` — override `global.nix_store.image_size_mib` for this VM and save it in `ash-state.toml`.
- `--kernel-serial=off|print|console` — disable serial I/O, stream guest kernel/init output, or connect host standard input and output to the guest serial console. Interactive `console` mode requires `--attach` without `--keep` so Virtle owns the terminal directly.
- `--mount-cwd` — mount the current host working directory under the guest workspace. Off by default.
- `--attach` — attach after spawning. Without `--keep`, the VM stops when SSH exits.
- `--kitty` — use `kitten ssh` for the attached session.
- `--waypipe` — wrap the attached SSH session with Waypipe so guest Wayland and X11 applications display through the host compositor. This can be combined with `--kitty` and is saved for regenerated launches.
- `--keep` — with `--attach`, start as a background VM and keep it running after SSH exits. Plain `spawn` already keeps the VM, so `--keep` requires `--attach`.
- `--ephemeral` — remove the VM state directory after the launched SSH/VM session exits. Requires `--attach` and cannot be used with `--keep`.

Attach options:

- `--spawn` — if the named VM is stopped, load its saved `ash-state.toml`, regenerate the manifest, start it, then attach.
- `--kitty` — use `kitten ssh`. It can be combined with `--waypipe`.
- `--waypipe` — forward guest Wayland and X11 applications to the host. It can be combined with `--kitty`.
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
- a native Nix database registration dump generated from the exact selected toplevel closure
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

Then it reads `$XDG_CONFIG_HOME/$ASH_NAME/config.toml` (falling back to `~/.config/$ASH_NAME/config.toml`, with `ASH_NAME` defaulting to `ash`, or using `--config`). The optional `global.memory` setting selects VM memory in MiB and defaults to 4096. `global.kitty` defaults to false; when true, spawned manifests and attached sessions use `kitten ssh` unless another feature wraps that SSH command. An explicit `--kitty` also enables Kitty for the requested operation. `global.network_bridge` defaults to `ash0`, and `global.qemu_bridge_helper` defaults to `/run/wrappers/bin/qemu-bridge-helper`. `global.nix_store.strategy` selects `shared` (the default) or `image`; `global.nix_store.image_size_mib` defaults to 16384. `--nix-store-strategy` and `--nix-store-image-size-mib` override those defaults for one VM; explicit overrides are saved in its `ash-state.toml` and reused by later spawns and regeneration. Pass `--ro-store-socket` to select an existing virtiofsd socket for the shared strategy. An explicit enabled `[portal]` section enables Portal integration. Selected spaces turn their `rw_mounts` and `ro_mounts` into `virtle` virtiofs mounts, and their `files` into Virtle `write_files` entries. A space may define `extends = ["base", ...]`; ash traverses these dependencies recursively in declaration order, evaluates dependencies before dependents, and evaluates each reachable space once. Unknown spaces and inheritance cycles are fatal configuration errors.

Space selection is explicit:

- If no `-s`/`--space` option is passed for a new VM, no configured spaces are applied.
- If no `-s`/`--space` option is passed for an existing named VM, `ash` reuses the saved space list.
- If `-f`/`--flake` is omitted for an existing named VM with saved `ash-state.toml`, `ash` reuses the saved flake; new VMs still require it.
- If no `--override-input` option is passed for an existing named VM, `ash` reuses the saved override inputs. Passing one or more overrides replaces the saved list.
- If one or more spaces are passed, `ash` uses exactly those spaces and replaces the saved selection.

Each mount or file entry is either `HOST_PATH` or `HOST_PATH:GUEST_PATH`. Host `~` resolves against the host user's home. Guest `~` resolves against the evaluated guest SSH user's home. When the guest path is omitted, the original host path string is reused and resolved for the guest. Absolute paths are accepted on both sides. Missing host paths are skipped with a warning. Mounts are deduplicated after parsing and path expansion by source, target, and read-only mode, preserving the first occurrence.

Space `files` entries must resolve to regular host files. Ash reads their contents while rendering the manifest and preserves the source permission bits in `write_files.mode`; `overwrite` is enabled. Destinations under the guest SSH user's home receive `USER:users` ownership (`root:root` for root), while absolute destinations elsewhere use Virtle's default ownership. Equivalent source/destination pairs inherited through multiple spaces are emitted once. Configured files and Ash's Portal startup files share one combined `write_files` table array.

The guest SSH user defaults to `config.services.getty.autologinUser` from the selected NixOS configuration. `--user` overrides it, and ash validates the result through `config.users.users.<user>.name`.

It also exposes these mount devices to the guest:

- `workspace` — writable virtiofs share for `<state_dir>/workspace`, intended for `/home/<ssh-user>/workspace`
- `hotmounts` — writable virtiofs share for `<state_dir>/hotmounts`, used by `ash mount` for QGA-driven hot mounts into a running VM.
The `shared` strategy adds:

- `ro-store` — readonly virtiofs share for the host `/nix/store`. By default ash starts a virtiofsd using `ro-store.sock` with its user-namespace sandbox disabled so root ownership from the host store remains root ownership in the guest. Pass `--ro-store-socket PATH` to use an existing daemon instead.
- `shares-ro` — readonly VM-state data, including `guest-store-state`, a synthetic local-store metadata database for the resolved NixOS closure.
- `shares-rw` — writable VM-state data, including `guest-store-state`, `guest-store-upper`, and `guest-store-work` for guests that choose a host-backed OverlayFS upper layer. When subordinate UID/GID ranges are available, Ash maps guest identities one-to-one; otherwise it falls back to identity squashing.

The `image` strategy instead adds `nix-store.img`, a writable ext4 image labeled `nix-store`. It does not add `ro-store`, `shares-ro`, or `shares-rw`, so the guest has no live host Nix store share. Ash appends `ash.nix-store=image` or `ash.nix-store=shared` after the evaluated NixOS kernel parameters, replacing any pre-existing `ash.nix-store` value, so a single guest closure can conditionally select its stage-1 mount layout.
- `persist` — writable ext4 image labeled `persist`
- `workspace_cwd` — virtiofs share for the host current working directory, only when `--mount-cwd` is passed

Ash queries the exact resolved NixOS toplevel once with recursive `nix path-info --json`, then serializes each path's NAR hash, NAR size, and references into the database format accepted by `nix-store --load-db`. The generated registration is added to the Nix store as a fixed-output file. The kernel, initrd, toplevel, and registration file have indirect GC roots under `<state_dir>/gcroots/`; the toplevel root retains its transitive system closure. The roots remain valid for stopped VMs and disappear automatically when the VM state directory is deleted, including ephemeral cleanup.

For the `shared` strategy, Ash uses the selected NixOS configuration's `config.nix.package` to load that registration into a synthetic local-store database at `<state_dir>/shares/ro/guest-store-state`. The synthetic store uses the host `/nix/store` as its physical store directory, but contains metadata only for the pinned NixOS closure.

For the `image` strategy, Ash resolves the selected toplevel closure plus its generated registration store object and writes both directly into a sparse ext4 filesystem through the shared `libext2fs` importer. Store paths are written below `/store` in the image, which becomes `/nix/store` when the filesystem is mounted at `/nix`. Writable images use conventional ext4 inode density of roughly one inode per 16 KiB rather than sizing inodes only for the initial closure. The image initially contains store paths but no Nix database. Ash caches a read-only, closure-sized base image under `$XDG_CACHE_HOME/$ASH_NAME/nix-store-images` (falling back to `~/.cache/$ASH_NAME/nix-store-images`, with `ASH_NAME` defaulting to `ash`), keyed by cache format and the exact toplevel store path rather than registration output or writable capacity. Creating a VM clones that base into the VM state with `cp --reflink=auto --sparse=always`, using filesystem CoW when available and retaining sparse-copy behavior otherwise, then grows the clone with `resize2fs` to the configured `image_size_mib`. A versioned TOML sidecar (`<cache-key>.toml` for cached bases and `nix-store.toml` for writable VM images) records the closure, registration path and hash, expected image size, closure metrics, timestamps, cache lineage, and deduplicated flake provenance. Existing `.toplevel` markers remain visible as legacy metadata, while writable images using them require `ash rebuild-db` before reuse. Increasing `image_size_mib` for a stopped VM enlarges the sparse backing file and runs `resize2fs`; shrinking remains an explicit `ash rebuild-db`. When a stopped VM selects a different closure, Ash checks the existing filesystem, opens it through `libext2fs`, skips immutable targets already present, imports only missing paths, and updates the TOML sidecar after a successful close. Old and guest-added store paths remain available; a failed import is resumable because the old sidecar is retained and subsequent attempts skip paths already written. The flake exposes `nixosConfigurations.image-reconcile-first` and `nixosConfigurations.image-reconcile-second`; `checks.x86_64-linux.image-store-reconcile` builds both closures, creates an image from the first, reconciles the second into the same image, verifies both toplevels and the updated sidecar, and finishes with `e2fsck`.

After guest readiness and before ash-managed mounts, Ash imports the resulting `registration` file with guest-root `nix-store --load-db` for guests that use the regular local store. This applies to both shared and image-backed stores. Guests configured with a `local-overlay` store skip the import because the closure is already present in the readonly lower-store database. Ash detects these guests through `/etc/ash/local-overlay-store` or a `store = local-overlay://...` entry in `nix.conf`. Foreground attach flows apply the same check in the generated SSH wrapper. A marker under `/run/ash/nix-registration/` avoids repeating regular-store imports during the same boot.

The guest may mount these tags/labels as needed. The current agent guest config mounts them as:

```nix
fileSystems."/home/agent/workspace" = {
  device = "workspace";
  fsType = "virtiofs";
};

# A guest supporting both strategies can define conditional stage-1 mount
# units using ConditionKernelCommandLine=ash.nix-store=shared|image. Shared
# mode mounts ro-store, shares-ro, shares-rw, and the writable overlay at
# /sysroot/nix/store. Image mode mounts the ext4 label at /sysroot/nix.

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

## Waypipe guest contract

`--waypipe` runs the host Waypipe client around Ash's generated SSH wrapper. Waypipe uses that wrapper to connect over the existing SSH/vsock path and starts `waypipe server` in the guest. A login shell opened through the resulting session receives `WAYLAND_DISPLAY`, so Wayland applications started there appear on the host.

The guest must provide `waypipe` and `xwayland-satellite` in its SSH command `PATH`; for NixOS, include `pkgs.waypipe` and `pkgs.xwayland-satellite` in `environment.systemPackages`. The host must be running a Wayland session with usable `WAYLAND_DISPLAY` and `XDG_RUNTIME_DIR` values. Ash passes `--no-gpu` because its generated VM currently has no guest GPU, and passes `--xwls` so Waypipe starts `xwayland-satellite` and exports `DISPLAY` for X11 applications such as `glxgears`. Waypipe and `kitten ssh` compose by selecting Ash's Kitty SSH wrapper as Waypipe's `--ssh-bin`.

Ash enables Virtle's SSH autoprovisioning in generated manifests. Foreground attached launches execute `virtle launch --ssh` directly, allowing `kernel.serial = "console"` to own the terminal; a concurrent Ash setup process loads Nix registration metadata and restores configured and runtime mounts. Virtle provisions the shared `<state>/id_ed25519` key if authentication initially fails, then invokes the selected OpenSSH, Kitty, or Waypipe wrapper. `--attach --keep` instead starts a background user unit and uses Ash's control-RPC key installation before attaching.

Waypipe forwards compositor protocols rather than creating a strong sandbox boundary. Only use it with guests and applications trusted with access to the host Wayland compositor.

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

For attached flows, `ash` uses SSH key autoprovisioning when the manifest has `ssh.autoprovision = true`. Foreground `virtle launch --ssh` sessions let Virtle create or reuse `id_ed25519` under the VM state directory and install it through QGA after an authentication failure. Background-spawned VMs use Ash's equivalent control-RPC installation before attaching because Virtle's own autoprovisioning only runs from `virtle launch --ssh`.

Current assumption: the guest SSH user's primary writable group is `users`. During ash-side autoprovisioning, ash creates `/home/<user>/.ssh` or `/root/.ssh`, appends its public key to `authorized_keys`, then runs `chown <user>:users` and sets OpenSSH-compatible permissions. This matches the current NixOS agent guest setup; guests with a different group convention should either provide compatible users/groups or disable ash/virtle SSH autoprovisioning and preconfigure authorized keys.

The generated manifest is written under:

```text
$XDG_STATE_HOME/$ASH_NAME/<name>/virtle.toml
```

or, if `XDG_STATE_HOME` is unset:

```text
~/.local/state/$ASH_NAME/<name>/virtle.toml
```

If `--name` is not passed, `ash` generates a name from the current directory basename and timestamp, such as `ash-20260708193000`. Passing the same `--name` reuses the same state directory and persistent image. For state paths, names preserve letters, digits, `.`, `_`, and `-`; other characters are replaced with `-`.

Ash uses `ASH_NAME` as the application component of its XDG paths, defaulting to `ash`. It keeps manifests, workspace data, persistent images, and other managed files under `XDG_STATE_HOME/$ASH_NAME/<name>/` (falling back to `~/.local/state/$ASH_NAME/<name>/`). The generated manifest sets virtle's own `state_dir` to the nested `virtle_state/` directory, so virtle runtime files and control sockets remain inside that VM state directory.

Every generated manifest disables virtle's default user-mode network and appends an Ash-managed QEMU bridge NIC through `qemu.exec`. The NIC attaches to `ash0` by default through `/run/wrappers/bin/qemu-bridge-helper` and uses a stable locally administered MAC derived from the Ash VM name. The host must provide the bridge, DHCP, NAT if desired, and bridge-helper authorization.

Ash also appends `ash.mdns-host=<dns-label>` and `ash.mdns-mac=<stable-mac>` to the guest kernel command line. A compatible guest reads these boot-time values and publishes `<dns-label>.ash.local`; the agent NixOS configuration generates an Avahi runtime configuration restricted to the interface matching the stable MAC. Avahi owns address discovery, lease changes, conflict handling, announcements, query responses, and goodbye records, so Ash requires no host-side publisher, QGA mDNS action, or guest responder executable. DNS-safe lowercase names up to 63 characters are preserved; transformed names receive an eight-hex digest suffix to avoid normalization collisions.

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

## Source organization

The repository uses separate wrapped OCaml libraries and thin executable entry
points:

```text
lib/ash/                 `Ash` VM-management library
bin/ash/                 Ash CLI and command-page generator
lib/portal/              `Agent_portal` library
bin/agent-portal-host/   Portal host entry point
bin/agent-portal-cli/    Portal client entry point
wrappers/gh/             GitHub CLI compatibility wrapper
wrappers/wl-paste/       Wayland clipboard compatibility wrapper
test/ash/                Ash tests
test/portal/             Portal tests
```

`Agent_portal` does not depend on `Ash`. The Portal host, client, and wrappers
therefore remain usable independently from VM orchestration.

## Agent Portal implementation

Portal uses protocol-versioned MessagePack requests over a Unix socket or
Linux AF_VSOCK stream. It keeps Agent-box's method and response representation
so the OCaml and Rust implementations can communicate with each other. The
supported methods are `ping`, `clipboard.read_image`, `gh.exec`, and
approval-gated `exec`.

For Unix sockets, the host authenticates local callers with `SO_PEERCRED` and
attempts Podman container attribution from cgroups. For vsock, it identifies
the peer by the kernel-reported source CID; per-container overrides do not
apply. It enforces concurrency, rate, prompt, timeout, and clipboard-size
limits. The Unix socket directory and socket use modes `0700` and `0600`.
Host command resolution skips the package's own executable directory to avoid
recursively calling the installed wrappers.

The `gh` policy table in `lib/portal/gh_policy.ml` is generated from
`data/gh-policy.json`; `tools/gh-policy-gen.py` refreshes the report, JSON, and
OCaml source from the installed GitHub CLI command tree.

See [`PORTAL.md`](./PORTAL.md) for configuration and wrapper contracts. When
`[portal]` is explicitly enabled, Ash integrates it with generated VM
manifests. Managed mode (`global = false`) adds a per-VM
`agent-portal-host --vsock-port-for-cid {{.CID}}` virtle `run` process. The
managed port is `65536 + guest CID`, which stays out of the privileged range
and remains unique among running VMs; virtle owns the process lifecycle.
Global mode requires `transport = "vsock"` and uses the configured
CID and port without starting a host process.

Both modes add `/etc/profile.d/ash-agent-portal.sh` and the guest user's
`~/.local/share/nushell/vendor/autoload/ash-agent-portal.nu` through virtle
`write_files`. Managed mode exports `AGENT_PORTAL_VSOCK=managed:<host-cid>`;
the client obtains its local CID from AF_VSOCK and derives the same managed
port. Global mode exports the configured endpoint.
QEMU Guest Agent is therefore required, and the guest must already contain the
Portal wrappers. Managed host resolution checks beside the `ash` executable,
then `ASH_AGENT_PORTAL_HOST`, then `PATH`.

## Build

```sh
nix build
./result/bin/ash --help
./result/bin/agent-portal-host --help
./result/bin/agent-portal-cli --help
```
