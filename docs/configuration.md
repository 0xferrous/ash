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

Pass the flake directory, not `flake.nix`. Path-like flake references are stored as resolved absolute paths in `ash.toml`, so later `ash regenerate NAME` does not depend on the current directory.

## Agent-box config

By default ash reads:

```text
~/.agent-box.toml
```

Override it with:

```sh
ash spawn --config ./agent-box.toml -f ../my-nix#agent
```

Profiles in this file provide directory mounts and file entries.

## Guest user

The SSH user is resolved in this order:

1. `--user USER`
2. `runtime.qemu.ssh_user` in the agent-box config
3. `agent`

ash validates that the selected NixOS configuration defines the user.

## Guest requirements

Runtime features use QGA guest-exec. The guest needs commands such as:

- `/run/current-system/sw/bin/sh`
- `mount`
- `umount`
- `mountpoint`
- `install`
- `mkdir`
- `chown`
- `chmod`
- `grep`

For NixOS guests enable:

```nix
services.qemuGuest.enable = true;
```

## Saved VM inputs

ash stores spawn inputs in:

```text
~/.local/state/ash/<name>/ash.toml
```

This file is used by:

```sh
ash regenerate <name>
ash attach --spawn <name>
```
