# ash

`ash` is a CLI for spawning, attaching to, suspending, resuming, mounting into,
and deleting NixOS agent VMs through [`virtle`](https://github.com/shazow/virtle).

Most documentation lives in the command help and generated command pages:

- <https://0xf.rs/ash/>
- [Implementation notes](./IMPLEMENTATION.md)

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

## Configuration

Ash reads `$XDG_CONFIG_HOME/ash/config.toml`, falling back to
`~/.config/ash/config.toml`. See [`example_config.toml`](./example_config.toml)
for the global and space mount formats. Set
`global.memory` to configure VM memory in MiB; it defaults to 4096. VMs attach
to the private host bridge `ash0` through
`/run/wrappers/bin/qemu-bridge-helper`; override these with
`global.network_bridge` and `global.qemu_bridge_helper`. The host must create
the bridge and authorize it in `/etc/qemu/bridge.conf`. Set
`global.nix_store_virtiofs_socket` to reuse a host-wide virtiofsd serving
`/nix/store`; `--ro-store-socket` overrides it. For each VM, Ash also creates
a lower-store metadata database under `shares/ro/guest-store-state` from the
resolved NixOS closure registration. Guests can pair that database with the
read-only store mount when using Nix's `local-overlay` store. The writable
store's `state` should point at `shares/rw/guest-store-state`, beside
`guest-store-upper`; keeping its database in the persistent image while
resetting Ash's shares leaves stale valid-path records. Select a space
with a repeatable `--space`/`-s` option:

```sh
ash spawn --name work -s ash -f ../my-nix#agent
```

For a new VM, omitting `--space` applies no configured spaces. For an existing
named VM, it reuses the saved space list. Spaces can compose other spaces with
`extends = ["base", ...]`; extended spaces are evaluated recursively before the
extending space.

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

Inspect, list, and delete VM state:

```sh
ash inspect work
ash ls
ash rm
```

Reset a stopped VM's Nix store metadata and writable overlay:

```sh
ash stop work
ash rebuild-db work
ash attach --spawn work
```

## More detail

Use command help:

```sh
ash spawn --help
ash resume --help
ash mount --help
```

