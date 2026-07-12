# ash

`ash` is a small OCaml CLI for spawning, attaching to, and managing NixOS agent VMs through [`virtle`](https://github.com/shazow/virtle).

It focuses on repeatable VM state, agent-box profile mounts, SSH attach flows, and runtime hotmounts for adding host directories to a running VM.

## Common workflow

```sh
ash spawn --name work -f ../my-nix#agent --attach --keep
ash mount work ~/dev/project
ash attach work
ash umount work ~/dev/project
ash stop work
```

## Documentation

- [Quick start](./quick-start.md) — spawn and use a VM.
- [Configuration](./configuration.md) — flake, agent-box config, and guest requirements.
- [Runtime mounts](./mounts.md) — launch-time mounts, hotmounts, and profile hotmounting.
- [Commands](./commands.md) — command reference.
- [Troubleshooting](./troubleshooting.md) — common failure modes and fixes.
