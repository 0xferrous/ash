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

## Quickstart

Start a reusable background VM:

```sh
ash spawn --name work -f ../my-nix#agent
```

Attach to it:

```sh
ash attach work
```

Use Kitty's SSH kitten for an attached session:

```sh
ash attach --kitty work
```

Start and attach immediately, keeping the VM after SSH exits:

```sh
ash spawn --name work -f ../my-nix#agent --attach --keep
```

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

List and delete stopped VM state:

```sh
ash ls
ash rm
```

## More detail

Use command help:

```sh
ash spawn --help
ash resume --help
ash mount --help
```

