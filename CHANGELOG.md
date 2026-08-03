# Changelog

All notable user-facing changes to Ash are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses its existing Git tags for version history.

## [Unreleased]

### Added

- `ash attach --waypipe` display forwarding for Wayland and X11 applications, including composition with `--kitty` and persisted attach settings.
- Experimental filtered D-Bus/vsock proxy for forwarding host desktop notifications into VMs.

### Changed

- Replaced the hand-written interactive selector terminal handling with Notty, including resize-aware list viewports and safe Unicode rendering.
- Redesigned `ash rm` with separate VM-state and cached-image panes, labeled columns, independent selection with per-pane selected-size totals, selectable sort fields and directions, and modification times for cache entries.

### Fixed

- Preserved the selected sort direction when cycling between sort fields in `ash rm`.

### Documentation

- Host-backed guest FileChooser portal design covering Documents portal integration, filesystem exposure, security boundaries, and implementation phases.

## [v0.1.6] - 2026-08-02

### Added

- Standalone `agent-portal-cli` flake package for diagnostics and direct Portal API access.
- Stable per-VM mDNS identities. Ash passes the normalized VM name and stable MAC address to the guest so guest Avahi can publish `<name>.ash.local`.

## [v0.1.5] - 2026-08-01

### Added

- Extended `ash rm` so stopped VM state and cached image-backed Nix store images can be removed interactively.

### Fixed

- Initialized the Nix database directory before loading registration data into image-backed stores.

## [v0.1.4] - 2026-08-01

### Added

- `nix-ext4-image` builder and reusable image-import libraries for creating ext4 images from NixOS closures.
- Private image-backed Nix stores with closure registration, guest database initialization through QGA, versioned image layouts, and kernel strategy signaling.
- Closure-keyed base-image caching with sparse reflink/CoW clones for new VM stores.
- Incremental image updates that import only missing store paths while preserving guest-added and older paths.
- Configurable kernel serial modes.
- Dedicated `agent-portal-host` and `agent-portal-wrappers` flake packages.

### Changed

- Derived config, state, cache, and Portal paths from `ASH_NAME`, allowing isolated application namespaces.
- Extracted the image import core for reuse and added reconciliation coverage for distinct NixOS closures.

### Fixed

- Honored the selected kernel Nix store mode while registering closures in the guest.

## [v0.1.3] - 2026-07-30

### Added

- Per-VM `--nix-store-strategy` and `--nix-store-image-size-mib` spawn overrides.
- Persistent Nix store overrides in VM state, reused by later spawn and regeneration operations.

## [v0.1.2] - 2026-07-30

### Added

- Configurable private image-backed Nix store strategy alongside the shared host-store strategy.
- Sparse per-VM store images, filesystem growth, kernel strategy signaling, and `ash rebuild-db` support for resetting strategy-specific store state.

### Changed

- Simplified the shared-store configuration by removing the obsolete global Nix store socket setting.
- Reorganized the README to put the quickstart before detailed configuration.

### Fixed

- Used the supported Portal configuration flag when constructing VM manifests.
- Set the default Nix flake app executable explicitly and fixed CI command-page builds to use the full package output.

## [v0.1.1] - 2026-07-29

### Added

- Isolated config and state roots through the `ASH_NAME` application namespace and XDG directories.
- Separate flake outputs for the minimal `ash` CLI, the complete `all` build, and generated command-page packages.

## [v0.1] - 2026-07-28

### Added

- Ash CLI for spawning, attaching to, listing, inspecting, regenerating, stopping, suspending, resuming, logging, and removing NixOS agent VMs through Virtle.
- Named reusable VMs, ephemeral spawns, automatic SSH provisioning, Kitty SSH integration, active-connection checks, and attach-on-spawn workflows.
- Host-to-guest and guest-to-host file copying.
- Persistent and runtime host-directory mounts, space/profile mounts, mount restoration, and unmount support.
- Composable configured spaces with recursive `extends` support.
- Shared and overlay Nix store support, closure registration, lower-store metadata, database rebuilding, and configurable read-only store sockets.
- Bridge networking, configurable VM memory, host-CPU-based default vCPU counts, and persistent systemd-managed background VMs.
- Flake input overrides that are normalized and saved with VM state.
- Agent Portal with Unix socket and AF_VSOCK transports plus transparent `gh` and `wl-paste` wrappers.

### Fixed

- Improved VM and SSH state cleanup, saved-flake reuse, SSH autoprovisioning, and fully resolved flake path persistence.
- Preserved ownership across writable shares and read-only Nix stores, and handled virtiofs environments without ID mapping.
- Disabled caching for mutable FUSE shares, normalized mount paths, excluded hotmounts from state-size totals, and removed stale guest mountpoints.
- Configured the Portal environment correctly for Nushell.

[Unreleased]: https://github.com/0xferrous/ash/compare/v0.1.6...HEAD
[v0.1.6]: https://github.com/0xferrous/ash/compare/v0.1.5...v0.1.6
[v0.1.5]: https://github.com/0xferrous/ash/compare/v0.1.4...v0.1.5
[v0.1.4]: https://github.com/0xferrous/ash/compare/v0.1.3...v0.1.4
[v0.1.3]: https://github.com/0xferrous/ash/compare/v0.1.2...v0.1.3
[v0.1.2]: https://github.com/0xferrous/ash/compare/v0.1.1...v0.1.2
[v0.1.1]: https://github.com/0xferrous/ash/compare/v0.1...v0.1.1
[v0.1]: https://github.com/0xferrous/ash/releases/tag/v0.1
