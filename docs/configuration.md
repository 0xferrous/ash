# Configuration

## Flake target

Most VM-creating commands need a NixOS flake target:

```sh
ash spawn -f ../my-nix#agent
```

The fragment resolves to:

```text
nixosConfigurations.agent
```

Pass the flake directory, not `flake.nix`. `--flake` is required when creating a new VM. When spawning an existing named VM, ash reuses the flake saved in `ash-state.toml` if `--flake` is omitted; an explicit value overrides it. Path-like flake references are stored as resolved absolute paths.

## Ash config

By default ash reads:

```text
$XDG_CONFIG_HOME/ash/config.toml
```

If `XDG_CONFIG_HOME` is unset or empty, it falls back to:

```text
~/.config/ash/config.toml
```

Override it with:

```sh
ash spawn --config ./config.toml -f ../my-nix#agent
```

Spaces provide read-write and read-only directory mounts:

```toml
[spaces.ash]
rw_mounts = [
  "~/dev/fr/ash",
  "~/dev/fr/ash:/home/agent/workspace/ash",
]
ro_mounts = [
  "~/dev/reference:~/reference",
  "/var/lib/data:/mnt/data",
]
```

Each entry is either:

```text
HOST_PATH
HOST_PATH:GUEST_PATH
```

Both paths must be absolute or begin with `~`. Host-side `~` resolves to the host user's home. Guest-side `~` resolves to the guest SSH user's home. If `GUEST_PATH` is omitted, ash uses the original host path string as the guest path, resolving any `~` for the guest.

Missing host paths are skipped with a warning. If no `--space` option is passed for a new VM, no configured spaces are applied. For an existing named VM, omitting `--space` reuses the saved space list.

## Guest user

The SSH user is resolved in this order:

1. `--user USER`
2. `config.services.getty.autologinUser` from the selected NixOS configuration

ash validates that the selected NixOS configuration defines `users.users.<user>`.

## Guest requirements

Runtime features use QGA guest-exec. The guest needs commands such as:

- `/run/current-system/sw/bin/sh`
- `mount`
- `umount`
- `mountpoint`
- `install`
- `stat`
- `mkdir`
- `chown`
- `chmod`
- `grep`
- `ss`
- `awk`
- `who`

For NixOS guests enable:

```nix
services.qemuGuest.enable = true;
```

## Saved VM inputs

ash stores spawn inputs in:

```text
~/.local/state/ash/<name>/ash-state.toml
```

This file is used by:

```sh
ash regenerate <name>
ash attach --spawn <name>
```

Saved state records the selected `spaces` list and config path. A later `ash spawn --name <name>` without `--space` reuses that saved list. Passing one or more spaces replaces it.
