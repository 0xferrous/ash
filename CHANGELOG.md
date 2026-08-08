# Changelog

All notable user-facing changes to Ash are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses its existing Git tags for version history.

## [Unreleased]

### Added

- In-process virtle manifest validation via FFI: a cgo shim
  (`ffi/shim.go`, built as `ash-libvirtle`) exposes virtle's manifest
  decode/resolve and QEMU argv generation as a C shared library, bound from
  OCaml through `Virtle_ffi` (ctypes). `ash manifest-check --manifest PATH`
  validates a generated manifest without spawning the virtle CLI; `--json`
  prints the resolved manifest, otherwise it prints the rendered QEMU argv.
- `ash launch-ffi --manifest PATH [--cid N] [--incoming]` renders a virtle
  manifest's launch plan through the virtle library FFI and executes it from
  OCaml: ash prepares runtime directories, starts host run processes and
  QEMU, waits for the virtiofs and QMP sockets, holds until the VM exits, and
  terminates the remaining host processes. Guest serial output goes to
  stderr; the VM's allocated CID, exit code, and QMP socket are printed on
  exit. Requires qemu-system-* on PATH.
  The virtle flake input currently tracks the `push-tmopowoytwzm` branch of
  `0xferrous/virtle` and should be switched back to upstream `shazow/virtle`
  once the extraction is merged.

## [v0.1.7] - 2026-08-07

### Added

- TOML metadata sidecars for cached and writable image-backed Nix stores, including closure metrics, creation and last-use timestamps, registration hashes, and deduplicated flake/lock/override provenance.
- `global.kitty` configuration for using `kitten ssh` by default across spawn and attach sessions.
- Per-space `files` configuration for embedding host files into generated Virtle `write_files` entries with preserved modes and guest-home ownership.
- `ash ls --cache` for a non-interactive inventory of cached image-backed Nix store bases, including sizes, modification times, VM reference counts, closures, and paths.
- `ash attach --waypipe` display forwarding for Wayland and X11 applications, including composition with `--kitty` and persisted attach settings.
- Experimental filtered D-Bus/vsock proxy for forwarding host desktop notifications into VMs.

### Changed

- Existing named `ash spawn` launches now reuse saved manifests and GC-rooted NixOS outputs by default; `--eval` explicitly re-evaluates and regenerates them, while new VMs continue to evaluate automatically.
- Consolidated directory sharing into the `shares-ro` and `shares-rw` VirtioFS roots. Workspace, cwd, configured spaces, the shared host Nix store, and runtime mounts now use structured bindfs staging paths beneath those roots; the Nix package includes `bindfs` at runtime, while Virtle supplies the shares' standard virtiofsd arguments.
- Moved persistent runtime mount and `mount-space` desired state into atomically updated `ash-state.toml` records with ownership claims, restart reconciliation, overlapping-space handling, and migration from legacy per-mount metadata files.
- Keyed image-backed Nix store caches by the exact toplevel store path, since native registration data is derived deterministically from that closure.
- Generated Nix closure registration data directly from a single recursive store query instead of building a separate `pkgs.closureInfo` derivation.
- Bundled spawn-time NixOS metadata lookups into one structured `nix eval`, reducing repeated flake evaluation while preserving the existing kernel, initrd, and toplevel builds.
- Replaced the hand-written interactive selector terminal handling with Notty, including resize-aware list viewports and safe Unicode rendering.
- Redesigned `ash rm` with separate VM-state and cached-image panes, labeled columns, independent selection with per-pane selected-size totals, selectable sort fields and directions, cache modification times and VM reference counts, and one-key selection of all unreferenced caches.

### Fixed

- Provisioned Ash's SSH identity through QGA in foreground setup wrappers before authentication, avoiding public-key failures after Virtle SSH provisioning was removed.
- Prevented foreground SSH launches from racing duplicate guest-agent setup connections, and restored persisted runtime mounts through the SSH setup wrapper.
- Corrected `mount-space` and `umount-space` positional parsing so the first space name is accepted.
- Added guest-side source, ownership, and mount-table diagnostics when a staged bind mount cannot be realized.
- Restored direct foreground Virtle launches for attached sessions without `--keep`, making interactive kernel serial consoles usable again while retaining foreground mount and registration setup.
- Fixed the bundled spawn metadata evaluation to emit valid Nix syntax.
- Preserved the selected sort direction when cycling between sort fields in `ash rm`.

### Documentation

- Added an ASCII VM-state tree showing how the consolidated read-only and writable shares stage system, workspace, space, and runtime mount data.
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

[Unreleased]: https://github.com/0xferrous/ash/compare/v0.1.7...HEAD
[v0.1.7]: https://github.com/0xferrous/ash/compare/v0.1.6...v0.1.7
[v0.1.6]: https://github.com/0xferrous/ash/compare/v0.1.5...v0.1.6
[v0.1.5]: https://github.com/0xferrous/ash/compare/v0.1.4...v0.1.5
[v0.1.4]: https://github.com/0xferrous/ash/compare/v0.1.3...v0.1.4
[v0.1.3]: https://github.com/0xferrous/ash/compare/v0.1.2...v0.1.3
[v0.1.2]: https://github.com/0xferrous/ash/compare/v0.1.1...v0.1.2
[v0.1.1]: https://github.com/0xferrous/ash/compare/v0.1...v0.1.1
[v0.1]: https://github.com/0xferrous/ash/releases/tag/v0.1
