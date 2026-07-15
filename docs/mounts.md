# Runtime mounts

ash has two mount paths:

- launch-time virtiofs mounts rendered into `virtle.toml`
- runtime hotmounts driven by `ash mount` and QGA

## Launch-time mounts

Every rendered manifest exposes:

- `workspace` — `<state_dir>/workspace`
- `hotmounts` — `<state_dir>/hotmounts`
- `ro-store` — host `/nix/store`
- `persist` — writable ext4 image
- `workspace_cwd` — current working directory, only with `--mount-cwd`

Profile directory mounts selected at spawn are also emitted as virtiofs mounts.

## Hotmount model

`ash mount` stages a host directory and then bind-mounts it in the guest:

```text
host directory
  -> bindfs staging mount under <state_dir>/hotmounts/<id>
  -> hotmounts virtiofs share
  -> /run/ash/hotmounts in guest
  -> guest bind mount at target path
```

The guest-side `/run/ash/hotmounts` mount is lazy. It is mounted on the first successful `ash mount` or profile hotmount.

## Mount one directory

```sh
ash mount [--mode ro|rw] NAME HOST_PATH[:GUEST_PATH]
```

Examples:

```sh
ash mount work ~/dev/project
ash mount work ~/dev/project:~/project
ash mount --mode ro work ../my-nix:/home/agent/my-nix
```

If `GUEST_PATH` is omitted, ash uses the absolute host path as the guest target.

If `GUEST_PATH` starts with `~`, ash resolves it using the guest SSH user's home.

## Unmount one directory

```sh
ash umount NAME GUEST_PATH
```

Unmount removes the guest bind mount, removes the guest mountpoint directory if it is empty, then tears down the host-side staging mount.

Host-side unmount tries:

1. `fusermount3 -u`
2. `fusermount3 -uz`
3. `fusermount -u`
4. `fusermount -uz`
5. root-only `umount`

## Mount profiles at runtime

```sh
ash mount-profile NAME PROFILE...
ash umount-profile NAME PROFILE...
```

These commands resolve profiles from the VM's saved agent-box config and hotmount each directory mount as a batch.

- read-only profile mounts become `--mode ro` hotmounts
- writable profile mounts become `--mode rw` hotmounts
- profile file entries are skipped for now with a warning
- overlay profile mode is left for later

## Metadata

ash records one metadata file per staging path:

```text
<state_dir>/hotmounts/.ash/<source_name>.meta
```

The file records:

```text
<guest_path>
<host_dir>
<mode>
<source_name>
```

The metadata is persistent desired state. A successful `ash mount` keeps the record until `ash umount` removes it. When a background VM is started or resumed, ash reads the remaining records after QGA becomes ready and recreates their host staging and guest bind mounts. Missing host directories, invalid records, and individual restoration failures are reported without preventing the VM from starting.

Metadata updates use a temporary file and atomic rename so readers do not observe partially written records. Mount, unmount, and startup reconciliation are serialized with a per-VM metadata lock.

`ash umount` removes the desired-state record before unmounting. If the guest unmount fails normally, ash restores the record; if ash is interrupted after removal, the mount is not recreated on the next start.

Attached foreground launches that stop when SSH exits do not currently run startup reconciliation; persistent background starts and resumes do.

## Bindfs arguments

For writable mounts ash runs:

```sh
bindfs --multithreaded --no-allow-other \
  -o attr_timeout=0,entry_timeout=0,negative_timeout=0 SOURCE TARGET
```

For read-only mounts ash adds `-r`:

```sh
bindfs --multithreaded --no-allow-other \
  -o attr_timeout=0,entry_timeout=0,negative_timeout=0 -r SOURCE TARGET
```

The zero-valued FUSE timeouts force metadata and pathname lookups to be revalidated, reducing stale handles when the source is also modified through its original host path.

Mutable virtiofs shares (`workspace`, profile directories, `hotmounts`, and `workspace_cwd`) run virtiofsd with `--cache=never`. The immutable `/nix/store` share keeps virtiofsd's default cache behavior.

If bindfs fails and ash is running as root, ash can fall back to a kernel `mount --bind` staging mount.
