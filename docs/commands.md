# Commands

## `ash spawn`

```sh
ash spawn -f FLAKE#HOST [options]
```

Creates or updates VM state, renders `virtle.toml`, writes `ash.toml`, and launches the VM.

Common options:

- `--name NAME`
- `--profile PROFILE`, `-p PROFILE`
- `--user USER`, `-u USER`
- `--config CONFIG`, `-c CONFIG`
- `--mount-cwd`
- `--attach`
- `--keep`
- `--ephemeral`
- `--kitty` (use `kitten ssh` for attached SSH sessions)

## `ash attach`

```sh
ash attach [--spawn] [--keep] [--kitty] [NAME]
```

Attaches over SSH to a running VM. With `--spawn`, a stopped VM is relaunched from saved `ash.toml`.
Pass `--kitty` to use `kitten ssh` for the attached session instead of plain `ssh`.

## `ash mount`

```sh
ash mount [--mode ro|rw] NAME HOST_PATH[:GUEST_PATH]
```

Hotmounts one host directory into a running VM.

## `ash umount`

```sh
ash umount NAME GUEST_PATH
```

Unmounts a hotmounted guest target and tears down its host-side staging mount.

## `ash mount-profile`

```sh
ash mount-profile NAME PROFILE...
```

Hotmounts all directory mounts from one or more agent-box profiles.

## `ash umount-profile`

```sh
ash umount-profile NAME PROFILE...
```

Unmounts all hotmount targets resolved from one or more agent-box profiles.

## `ash regenerate`

```sh
ash regenerate NAME
```

Rewrites `virtle.toml` from the VM's saved `ash.toml`.

## `ash stop`

```sh
ash stop [NAME]
```

Stops an ash-owned background VM. If QGA reports active SSH connections, ash warns with the connection and PTY counts before continuing.

## `ash logs`

```sh
ash logs [--follow|-f] [--lines N|-n N] NAME
```

Shows journal entries from the latest invocation of the VM's `ash-NAME.service` user unit, excluding older processes that reused the unit name. Entries are formatted as `[YYYY-MM-DD HH:MM:SS] MESSAGE`, without hostname or process metadata. It shows the 100 most recent entries by default; `--follow` continues waiting for new entries.

## `ash ls`

```sh
ash ls
```

Lists VM state directories. For running VMs, `SSH` shows established AF_VSOCK connections to guest port 22 and `PTY` shows active SSH pseudo-terminals. A dash means the VM is stopped or the QGA query failed. Size totals exclude ash's `hotmounts` staging directory.

## `ash rm`

```sh
ash rm
```

Selects and deletes stopped VM state directories.
