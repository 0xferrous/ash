# ash

`ash` is a CLI for spawning, attaching to, suspending, resuming, mounting into,
and deleting NixOS agent VMs through [`virtle`](https://github.com/shazow/virtle).

Most documentation lives in the command help and generated command pages:

- <https://0xf.rs/ash/>
- [Implementation notes](./IMPLEMENTATION.md)
- [`nix-ext4-image`](./bin/nix-ext4-image/README.md)
- [Agent Portal and wrappers](./PORTAL.md)

## Install / run

Build with flakes:

```sh
nix build github:0xferrous/ash
./result/bin/ash --help
```

Run directly:

```sh
nix run github:0xferrous/ash -- --help
```

## Quickstart

Start a reusable background VM:

```sh
ash spawn --name work -f ../my-nix#agent
```

Attach to it:

```sh
ash attach work
```

Follow its logs:

```sh
ash logs -f work
```

Use Kitty's SSH kitten for an attached session:

```sh
ash attach --kitty work
```

Start and attach immediately, keeping the VM after SSH exits:

```sh
ash spawn --name work -f ../my-nix#agent --attach --keep
```

Copy files between the host and a running VM:

```sh
ash cp work ./input.txt ~/workspace/input.txt
ash cp --from guest work ~/workspace/output.txt ./output.txt
```

Use `-r` to copy directories and `-v` to print a successful transfer.

Mount a host directory into a running VM:

```sh
ash mount work ~/dev/project
```

Unmount it:

```sh
ash umount work ~/dev/project
```

Suspend and resume a background VM:

```sh
ash stop --suspend work
ash resume work
```

Stop a background VM:

```sh
ash stop work
```

Inspect and list VM state, or interactively delete stopped VM state and cached store images:

```sh
ash inspect work
ash ls
ash rm
```

Reset a stopped VM's strategy-specific Nix store state:

```sh
ash stop work
ash rebuild-db work
ash attach --spawn work
```

## Configuration

Ash uses `ASH_NAME` as its XDG application namespace, defaulting to `ash`.
It reads `$XDG_CONFIG_HOME/$ASH_NAME/config.toml`, falling back to
`~/.config/$ASH_NAME/config.toml`, and stores VM state and caches below the
matching `XDG_STATE_HOME` and `XDG_CACHE_HOME` namespaces. For example,
`ASH_NAME=nash` selects `~/.config/nash`, `~/.local/state/nash`, and
`~/.cache/nash`. `--config` overrides the configuration file directly.

See [`example_config.toml`](./example_config.toml) for the global and space
mount formats. Set `global.memory` to configure VM memory in MiB; it defaults
to 4096.

VMs attach to the private host bridge `ash0` through
`/run/wrappers/bin/qemu-bridge-helper`; override these with
`global.network_bridge` and `global.qemu_bridge_helper`. The host must create
the bridge and authorize it in `/etc/qemu/bridge.conf`.

The default Nix store strategy is `shared`: Ash exposes the host `/nix/store`
read-only through virtiofs. Pass `--ro-store-socket PATH` to reuse an existing
virtiofsd. Ash also provides lower-store metadata and writable overlay
locations under `shares/ro` and `shares/rw` for guests using Nix's
`local-overlay` store.

To use a private image-backed store instead:

```toml
[global.nix_store]
strategy = "image"
image_size_mib = 32768
```

Override these defaults for an individual VM when spawning it:

```sh
ash spawn --name private --nix-store-strategy image \
  --nix-store-image-size-mib 65536 -f ../my-nix#agent
```

The overrides are saved as `nix_store_strategy` and
`nix_store_image_size_mib` in that VM's `ash-state.toml` and reused by later
spawns and regeneration.

Ash caches one closure-sized ext4 base image for each selected closure and
registration output under `$XDG_CACHE_HOME/$ASH_NAME/nix-store-images` (or
`~/.cache/$ASH_NAME/nix-store-images`, with `ASH_NAME` defaulting to `ash`). New VM state uses a sparse reflink/CoW clone
of that base image when the host filesystem supports it, then grows the clone
to the VM's configured capacity. Different image-size settings therefore reuse
the same cached closure without rebuilding or fully copying the store image. The writable clone is labeled `nix-store` and does not expose the
host store to the guest. Ash appends `ash.nix-store=image` or
`ash.nix-store=shared` to the kernel command line so guests can select the
matching stage-1 mount layout. Image-capable guests must mount the `nix-store`
label at `/nix`; Ash loads the Nix database through QGA after boot. Increasing
`image_size_mib` grows an existing stopped VM's filesystem automatically.
When the selected closure changes, Ash imports only missing immutable store
paths into the stopped VM's existing image and retains guest-added and older
paths. Shrinking the image or migrating a legacy image created with `mke2fs
-d` requires `ash rebuild-db NAME`, which discards guest-added store paths.

Select a space with a repeatable `--space`/`-s` option:

```sh
ash spawn --name work -s ash -f ../my-nix#agent
```

Use repeatable `--override-input NAME=FLAKE` options to override inputs while
Ash evaluates and builds the selected flake:

```sh
ash spawn --name work -f ../my-nix#agent \
  --override-input ash=path:../ash
```

Overrides are saved with named VM state and reused by later regeneration.
Relative path references are saved as absolute paths.

For a new VM, omitting `--space` applies no configured spaces. For an existing
named VM, it reuses the saved space list. Spaces can compose other spaces with
`extends = ["base", ...]`; extended spaces are evaluated recursively before the
extending space.

## Agent Portal

The repository also builds a standalone OCaml implementation of the Agent-box
Portal protocol:

- `agent-portal-host` — host-side capability broker
- `agent-portal-cli` — diagnostic and direct API client
- `gh` — transparent GitHub CLI wrapper
- `wl-paste` — transparent image-clipboard wrapper

Portal uses MessagePack over a permission-restricted Unix socket or Linux
AF_VSOCK stream and remains wire-compatible with the Rust Agent-box
implementation. Its code is isolated under `lib/portal/`,
`bin/agent-portal-*`, and `wrappers/`; it does not depend
on the Ash VM implementation.

See [PORTAL.md](./PORTAL.md) for configuration, security behavior, and wrapper
compatibility. With an enabled `[portal]` section, Ash either manages a
per-VM vsock Portal process or injects the endpoint of a user-managed global
Portal into the guest.

## More detail

Use command help:

```sh
ash spawn --help
ash resume --help
ash mount --help
```

