# Commands

## `ash spawn`

```sh
ash spawn [--flake FLAKE#HOST] [options]
```

Creates or updates VM state, renders `virtle.toml`, writes `ash-state.toml`, and launches the VM.

Common options:

- `--name NAME`
- `--flake FLAKE#HOST`, `-f FLAKE#HOST` (required for a new VM; reused from saved `ash-state.toml` for an existing named VM)
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

Attaches over SSH to a running VM. With `--spawn`, a stopped VM is relaunched from saved `ash-state.toml`.
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

Rewrites `virtle.toml` from the VM's saved `ash-state.toml`.

## `ash stop`

```sh
ash stop [--force] [NAME]
```

Stops an ash-owned background VM. If QGA reports active SSH connections, ash warns with the connection and PTY counts and asks for confirmation. Non-interactive invocations refuse to continue unless `--force` is passed.

## `ash logs`

```sh
ash logs [--follow|-f] [--lines N|-n N] NAME
```

Shows journal entries from the latest invocation of the VM's `ash-NAME.service` user unit, excluding older processes that reused the unit name. Entries are formatted as `[YYYY-MM-DD HH:MM:SS] MESSAGE`, without hostname or process metadata. It shows the 100 most recent entries by default; `--follow` continues waiting for new entries.

## `ash inspect`

```sh
ash inspect NAME
```

Prints a concise human-readable summary for a running or stopped VM, including runtime and storage status, flake and profiles, machine resources, workspace paths, configured mounts/files, and hotmount state.

Pass `--json` for the complete machine-readable view, including the saved `ash-state.toml`, referenced agent-box configuration, generated `virtle.toml`, detailed paths, raw runtime status, and guest mount table.

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
