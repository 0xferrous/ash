# nix-ext4-image

Create an ext4 image containing the Nix store closure of a NixOS
configuration. The filesystem is created and populated directly with
`libext2fs`, without invoking `mke2fs`.

## Usage

```sh
nix run .#nix-ext4-image -- \
  --flake ../my-nix#agent \
  --out ./agent-nix-store.img
```

`../my-nix#agent` resolves to:

```text
../my-nix#nixosConfigurations.agent.config.system.build.toplevel
```

Options:

```text
--flake FLAKE#HOST  NixOS configuration to import (required)
--out PATH          Output image, replacing an existing file (required)
--dry-run           Evaluate and scan without creating the image
--jobs N            Reserved for parallel scanning; currently serial
```

Enable detailed progress logs with `ASH_LOG=debug`.

## Image contract

The resulting raw ext4 filesystem:

- is labelled `nix-store`;
- contains the closure under `/nix/store`;
- preserves regular files, directories, symlinks, ownership, modes, and
  modification times;
- is automatically sized for both data blocks and inodes.

It is a **store image, not a boot disk**: it has no partition table, bootloader,
root filesystem, or writable Nix database. A VM must supply its kernel, initrd,
NixOS toplevel, and writable state separately.

## FFI

The OCaml library `ash.ext2fs` calls `libext2fs` through the C stubs in
[`lib/ext2fs/ext2fs_stubs.c`](../../lib/ext2fs/ext2fs_stubs.c). Dune compiles
the stubs with `foreign_stubs` and links them with `-lext2fs -lcom_err`.

The binding exposes filesystem creation, directories, regular files, symlinks,
metadata, and close/finalization. Filesystem mutation stays serialized; the
close path reconciles inode-group summaries and checksums before writing the
final image.

## Verification

```sh
e2fsck -fn ./agent-nix-store.img
dumpe2fs -h ./agent-nix-store.img
debugfs -R 'ls -l /nix/store' ./agent-nix-store.img
```

## Development

```sh
nix develop -c dune exec -- bin/nix-ext4-image/main.exe \
  --flake ../my-nix#agent \
  --out ./agent-nix-store.img
```

Run the tests:

```sh
nix develop -c dune test
```

The tests create real images and validate them with `e2fsck`, `dumpe2fs`, and
`debugfs`, including a regression test that fills an ext4 inode group.
