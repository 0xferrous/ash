# Issue #10: possible bindfs problems

The most likely cause is **cache incoherency from stacking filesystems**:

```text
host repo → bindfs/FUSE → virtiofsd → guest virtiofs
```

Git frequently creates, renames, packs, and deletes objects atomically. If the repository is also accessed through its original host path, bindfs and virtiofs can retain inode/dentry information after a loose object has been packed or replaced. The guest then refers to the old inode and receives `ESTALE` (`Stale file handle`). Virtiofs defaults to caching metadata, while `--cache=never` is intended for maximum host/guest coherence.

This fits the evidence:

- Many unrelated loose objects failed simultaneously.
- The errors were `ESTALE`, rather than hash/content mismatches.
- A later `git fsck --full` produced no missing/corrupt object errors.
- The previously failing `922f80...` object later resolved as a tree.
- The repository later had zero loose objects; everything had been packed.

The earlier “missing objects” were therefore probably visible through stale handles, rather than actually lost.

## Recommended fix

### 1. Disable virtiofs caching for mutable shares

In `bin/virtle.ml`, add this to writable/source-tree virtiofsd arguments:

```ocaml
"--cache=never";
```

Use it for:

- `hotmounts`
- writable profile mounts
- `workspace_cwd`
- probably `workspace`

Keep the immutable `/nix/store` share on `auto` for performance.

The Rust virtiofsd syntax supports `--cache=never`. The `auto` setting can cache directory entries and metadata, which is problematic for externally modified trees.

### 2. Reduce bindfs caching as well

Change the bindfs arguments to include:

```sh
-o attr_timeout=0,entry_timeout=0,negative_timeout=0
```

These options force FUSE to revalidate attributes and pathname lookups rather than retaining them.

Do **not** use bindfs `--direct-io` as the primary fix: it can cause problems with `mmap`, and Git uses `mmap` during operations such as `fsck`.

### 3. Prefer avoiding bindfs for Git repositories

The robust architectural solution is:

```text
host repo → virtiofsd --cache=never → guest
```

rather than putting bindfs underneath virtiofs. For runtime hotmounts, that may require virtiofs device hotplug or a privileged kernel bind-mount helper.

Until then, avoid running host-side Git maintenance—especially `git gc`, `git repack`, or aggressive fetch/prune—while the same repository is active in the guest.

## Recovery when it happens

1. Stop Git processes in the host and guest.
2. Unmount/remount the hotmount, or restart the VM.
3. Run `git fsck --full` through the canonical **host path**.
4. Only repair or reclone if the host-side check still reports genuinely missing objects.

## Proposed first step

Implement both `--cache=never` and zero bindfs lookup/attribute timeouts, then stress-test concurrent host/guest Git operations.

## References

- virtiofsd manual: <https://manpages.debian.org/testing/qemu-system-common/virtiofsd.1.en.html>
- virtiofsd cache discussion: <https://gitlab.com/virtio-fs/virtiofsd/-/issues/74>
- libfuse cache timeout configuration: <https://libfuse.github.io/doxygen/structfuse__config.html>
- bindfs manual: <https://bindfs.org/docs/bindfs.1.html>
