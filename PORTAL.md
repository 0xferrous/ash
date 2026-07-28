# Agent Portal and wl-paste wrapper

Ash includes an OCaml rewrite of the Agent-box host Portal and its transparent
image-clipboard wrapper. Portal is an independent library and set of
executables; it does not depend on the Ash VM implementation.

## Components

| Component | Source | Purpose |
|---|---|---|
| `Agent_portal` | `lib/portal/` | Protocol, configuration, client, policy, and host server |
| `agent-portal-host` | `bin/agent-portal-host/` | Host-side Unix-socket service |
| `agent-portal-cli` | `bin/agent-portal-cli/` | Direct client and diagnostic tool |
| `wl-paste` | `wrappers/wl-paste/` | Transparent image clipboard wrapper |

The protocol is version 1 MessagePack over a Unix domain socket and is
compatible with the Rust implementation in Agent-box.

## First run

Add a Portal section to the Ash config:

```toml
[portal]
enabled = true
global = true
socket_path = "/run/user/1000/agent-portal/portal.sock"
prompt_command = "rofi -dmenu -p 'agent-portal'"

[portal.policy.defaults]
clipboard_read_image = "allow"
```

Start the host:

```sh
agent-portal-host
```

Check it from another terminal:

```sh
agent-portal-cli ping
```

Options belonging to a client operation follow its subcommand, for example:

```sh
agent-portal-cli ping --socket /tmp/portal.sock
```

## Configuration lookup

Portal clients and wrappers resolve configuration in this order:

1. `AGENT_PORTAL_CONFIG`
2. `$XDG_CONFIG_HOME/ash/config.toml`
3. `~/.config/ash/config.toml`
4. legacy `~/.agent-box.toml`

`AGENT_PORTAL_SOCKET` overrides the configured socket for clients and wrappers.
The default socket is `/run/user/<uid>/agent-portal/portal.sock`.

## Configuration reference

```toml
[portal]
enabled = true
global = true
socket_path = "/run/user/1000/agent-portal/portal.sock"
prompt_command = "rofi -dmenu -p 'agent-portal'"

[portal.timeouts]
request_ms = 5000
prompt_ms = 15000

[portal.limits]
max_inflight = 32
prompt_queue = 64
rate_per_minute = 60
rate_burst = 10
max_clipboard_bytes = 20971520

[portal.clipboard]
allowed_mime = ["image/png", "image/jpeg", "image/webp"]

[portal.policy.defaults]
clipboard_read_image = "allow"

[portal.policy.containers."3f7a1d5c2b8e"]
clipboard_read_image = "deny"
```

Clipboard decisions are `allow`, `ask`, or `deny`.

## Host behavior

The host:

- creates the socket directory with mode `0700` and socket with mode `0600`
- obtains caller PID, UID, and GID through `SO_PEERCRED`
- identifies Podman callers from `/proc/<pid>/cgroup` when possible
- supports per-container policy overrides
- limits concurrent requests, prompt concurrency, request rate, and payload size
- applies request and prompt timeouts
- writes an append-only log under
  `${XDG_STATE_HOME:-~/.local/state}/ash/logs/`
- refuses to replace a non-socket filesystem entry at the configured path

Prompt commands follow the dmenu convention: choices are written to stdin and
the selected line is read from stdout.

## `wl-paste` wrapper

The `wl-paste` wrapper implements the image flow used by agent tools:

```sh
wl-paste --list-types
wl-paste --type image/png --no-newline
```

Supported options are:

- `--list-types`, `-l`
- `--type MIME`, `-t MIME`
- `--no-newline`, `-n`
- `--help`, `-h`

The host invokes the real `wl-paste` to list clipboard MIME types and retrieve
the selected image. It only returns configured image MIME types and enforces
the maximum byte limit. Set `AGENT_PORTAL_HOST_WL_PASTE` to an absolute path
when needed.

The wrapper is intentionally not a complete replacement for every
`wl-clipboard` feature; unsupported flags fail explicitly.

## Binary recursion avoidance

The installed package contains a wrapper named `wl-paste`. The host therefore
skips host binaries located in its own executable directory when searching
`PATH`. An explicit `AGENT_PORTAL_HOST_WL_PASTE` path takes precedence.

## Current Ash integration boundary

Portal is currently standalone. Ash does not yet expose the Unix socket to a
VM or inject `AGENT_PORTAL_SOCKET` into guests. That transport/integration step
should be designed separately because a VM boundary differs from Agent-box's
container bind-mount model.
