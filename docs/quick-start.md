# Quick start

## Requirements

Install or make available on `PATH`:

- `ash`
- `virtle`
- `virtiofsd`
- `bindfs` for runtime hotmounts
- `nix`

Your guest image should run QEMU Guest Agent for SSH autoprovisioning and runtime mounts.

For NixOS guests:

```nix
services.qemuGuest.enable = true;
```

## Spawn a VM

```sh
ash spawn --name work -f ../my-nix#agent --attach --keep
```

This creates state under:

```text
~/.local/state/ash/work/
```

and starts the VM as a background user systemd unit.

## Attach later

```sh
ash attach work
```

## Mount a host directory at runtime

```sh
ash mount work ~/dev/project
```

If no guest path is provided, ash mounts the directory at the same absolute path inside the guest.

To choose a guest path:

```sh
ash mount work ~/dev/project:~/project
```

## Mount profiles at runtime

```sh
ash mount-profile work base rust
```

This resolves agent-box profiles from the VM's saved config and hotmounts all directory mounts from those profiles.

## Stop the VM

```sh
ash stop work
```
