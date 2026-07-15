# Troubleshooting

## `hotmounts` is not visible in `mount`

The guest mount at `/run/ash/hotmounts` is lazy. It appears after the first successful runtime mount:

```sh
ash mount NAME HOST_PATH[:GUEST_PATH]
```

## `virtle.toml` has no `hotmounts` share

Regenerate the VM manifest with a current ash binary:

```sh
ash regenerate NAME
```

If the VM is already running, restart it. Rewriting `virtle.toml` does not add devices to an already-running QEMU process.

## `bindfs` rejects `--read-only`

ash uses bindfs `-r`, not `--read-only`. If you are testing manually, use:

```sh
bindfs --multithreaded --no-allow-other \
  -o attr_timeout=0,entry_timeout=0,negative_timeout=0 -r SOURCE TARGET
```

## `fuse: invalid argument '-s'`

ash passes `--multithreaded` to avoid bindfs' default single-threaded FUSE mode.

## `fuse: invalid argument '-oallow_other'`

ash passes `--no-allow-other` by default. If you see this, verify you are running a current ash build.

## `fuse: invalid argument '-odefault_permissions'`

bindfs adds `default_permissions` internally. ash does not pass it. If your FUSE environment rejects it, bindfs will not work there without fixing the host/container FUSE setup.

## Host staging unmount is busy

`virtiofsd` may briefly hold the staging mount busy. ash tries lazy FUSE unmounts (`fusermount -uz`) after normal unmounts.

## QGA guest-exec fails

Verify QEMU Guest Agent is enabled in the guest and that the guest has required commands under `/run/current-system/sw/bin`.

For NixOS:

```nix
services.qemuGuest.enable = true;
```
