# Host resolution for Ash VMs

## Verdict

Yes, this is feasible.

Ash already has the two identifiers needed to maintain host-side names:

- a stable MAC derived from the Ash VM name (`Virtle.network_mac`), and
- the current guest IPv4 address, queried through QGA for `ash ls`.

The concrete `my-nix` configuration confirms the cleanest route: the host
already runs dnsmasq as the authoritative DHCP server for `ash0`. Its DNS side
is explicitly disabled with `port = 0`, so the work is to enable local DNS,
make each guest send its Ash instance name rather than the shared `nixos`
hostname, and route the Ash zone to dnsmasq from the host resolver.

## Naming caveat

`vm-name.ash.local` is syntactically possible, but `.local` is reserved for
multicast DNS. On Linux, `systemd-resolved` normally sends names ending in
`.local` to mDNS instead of ordinary unicast DNS.

Recommended names, in order:

1. `vm-name.ash.test` — collision-free and clearly non-public.
2. `vm-name.ash.home.arpa` — standardized for private home/local networks.
3. `vm-name.ash.local` — only as an explicit compatibility choice, with mDNS
   publication or resolver configuration that deliberately overrides `.local`.

The implementation should make the suffix configurable rather than embedding
`.ash.local` in code.

## Existing Ash support

Relevant code already present on `main`:

- `lib/ash/virtle.ml`: `network_mac name` creates a stable locally administered
  MAC from the normalized VM name.
- `lib/ash/qga.ml`: `vm_stats_action` obtains the current IPv4 address from the
  guest interface matching that MAC.
- `lib/ash/virtle.ml`: `control_socket_vm_stats` and `vm_stats` expose the IP to
  `ash ls` and `ash inspect`.
- `lib/ash/virtle.ml`: `wait_and_mount` is a suitable post-boot hook for work
  that requires a live IP.

The adjacent `my-nix` repository supplies the host infrastructure:

- `modules/nixos/ash-vm-network.nix` creates `ash0` at `192.168.127.1/24`,
  enables NAT, and runs dnsmasq with the DHCP range
  `192.168.127.100`–`192.168.127.254`.
- dnsmasq is DHCP-only today: `resolveLocalQueries = false` and `port = 0`.
- `config/fr/nixos/desktop.nix` enables that module on the host.
- `config/agent/nixos.nix` is the guest configuration. It uses dhcpcd and
  systemd-resolved, but does not set `networking.hostName`, so the evaluated
  NixOS default is `nixos` for every Ash instance.
- NixOS's generated dhcpcd configuration sends the current hostname in DHCP.

Therefore merely enabling dnsmasq DNS would make multiple guests compete for
`nixos.<domain>`; Ash must first provide an instance-specific guest hostname or
register a stable MAC-to-name mapping with dnsmasq.

## Design options

### A. DHCP-coupled dnsmasq — recommended

Use the dnsmasq already running on the Ash bridge as both DHCP and DNS. The
least-privileged path is to make the guest advertise its Ash instance name in
the DHCP request. dnsmasq can then publish the active lease as
`<vm-name>.<domain>` without Ash writing privileged host configuration.

The fallback is an explicit dnsmasq registration:

```text
<stable-mac>,<vm-name>
```

That fallback is robust but requires a constrained privileged helper or another
safe way to update dnsmasq's host registry.

Example shape, not final configuration:

```text
interface=ash0
bind-interfaces=true
domain=ash.test
local=/ash.test/
# Remove the current `port=0` so DNS listens on ash0.
```

The host resolver routes only the Ash zone to dnsmasq. With systemd-resolved,
that means a DNS server associated with `ash0` and a route-only domain such as
`~ash.test`.

Advantages:

- DNS and DHCP share one source of truth.
- No stale address after a lease changes.
- Registration can happen before the VM boots because the MAC is known.
- Reverse DNS can be added by the same service.

Costs and constraints:

- This is best only if dnsmasq owns the existing Ash DHCP leases.
- Updating dnsmasq configuration is privileged.
- A user-writable dnsmasq hosts file needs careful validation because it crosses
  a privilege boundary.
- Deleting a dynamic hosts entry requires a reload or a constrained helper.

### B. Ash DNS daemon backed by QGA IP discovery

Run a small host-side DNS service for the Ash zone. It can enumerate Ash state,
query running VMs through their virtle control sockets, cache the result briefly,
and answer A records.

Advantages:

- Works with an existing DHCP server that cannot publish Ash names.
- Reuses the IP lookup Ash already implements.
- Can run mostly as the Ash user; only one-time resolver routing is privileged.

Costs:

- Adds a long-running daemon and DNS protocol implementation/dependency.
- DNS availability depends on the user's daemon.
- Queries must not synchronously perform a slow QGA request without caching.
- Multiple host users require separate zones, ports, or a system aggregator.

This is the preferred fallback if the current DHCP implementation is not
extensible.

### C. Managed guest mDNS responder — selected implementation

Ash publishes `<vm-name>.ash.local` without changing host or guest NixOS
configuration.

Each generated manifest contains a host-side virtle `[[run]]` coordinator. It
starts before QEMU, waits for the control socket and QGA, and discovers the
current IPv4 address using the VM's stable MAC. It then starts a transient
`ash-mdns.service` inside the guest through QGA:

```text
systemd-run --unit=ash-mdns ash-mdns \
  --interface <guest-interface> \
  --name work.ash.local \
  --address 192.168.127.101
```

`ash-mdns` is a standalone executable. With the shared store strategy, Ash
passes its sibling responder path from the host `/nix/store`, which the guest
mounts read-only, so no guest package is required. If that path is absent, the
QGA action falls back to `ash-mdns` in the guest `PATH`, allowing image-store
guests to include it in their own closure. The coordinator finds the guest
interface from the stable MAC before starting the service.

The guest responder binds UDP 5353, joins `224.0.0.251` on that interface,
probes for conflicts, announces the A record, answers A/ANY questions, monitors
termination, and sends a TTL-zero goodbye. Because responses originate from the
guest address rather than the host itself, systemd-resolved accepts them as
remote mDNS answers.

A direct responder on the host was tested and rejected: systemd-resolved sends
the query, but ignores mDNS answers sourced by another process on the same host.
Running the responder inside the guest avoids that local-packet suppression.

Advantages:

- No dnsmasq DNS, Avahi, resolver-route, agent NixOS, or hostname changes.
- The only host prerequisite is allowing inbound multicast UDP 5353 on `ash0`.
- Virtle owns the host coordinator lifecycle; the guest transient unit owns the
  responder lifecycle.
- Fresh boot, foreground/background launch, resume, stop, and ephemeral cleanup
  all converge through the same generated run process.

Constraints:

- The guest must provide QGA, `sh`, `systemctl`, and `systemd-run`; the current
  agent image already does.
- The host resolver must have mDNS enabled, and multicast UDP 5353 must be able
  to cross the Ash bridge. The current `ash-vm-network.nix` firewall list allows
  only DHCP UDP 67, so it needs `5353` as well unless `ash0` is made trusted or
  the host firewall is disabled.
- The host Ash store path must remain visible in the guest's read-only store
  mount.
- mDNS has no authenticated ownership, so another bridge participant can claim
  the same name.
- Although mDNS handles every name ending in `.local`, the conventional flat
  form is `work.local`; `work.ash.local` requires compatibility coverage.

### D. `/etc/hosts` updates

Technically simple, but not recommended. Ash is a user CLI, `/etc/hosts` is
root-owned, concurrent updates are awkward, and crashes leave stale records.

## Selected architecture

1. Publish `<dns-safe-vm-name>.ash.local` through mDNS.
2. Generate a virtle `[[run]]` coordinator for every VM.
3. Discover the guest address through the existing QGA stable-MAC lookup.
4. Start the standalone `ash-mdns` responder as a transient guest systemd service.
5. Restart the guest service if the lease changes and stop it during VM
   teardown.

## Host lookup path

No unicast DNS or split-DNS configuration is involved:

```text
application getaddrinfo("work.ash.local")
  -> systemd-resolved stub at 127.0.0.53
  -> mDNS query on ash0 to 224.0.0.251:5353
  -> Ash responder inside the guest
  -> A response containing 192.168.127.x
  -> systemd-resolved cache
  -> application
```

Public DNS, Tailscale split DNS, dnsmasq's DHCP-only configuration, and physical
LAN mDNS remain independent.

A likely host API is deliberately small:

```text
register(name, mac)
unregister(name)
```

The helper validates the normalized Ash name and MAC, atomically rewrites its
owned registry, and reloads dnsmasq. It should not accept arbitrary dnsmasq
configuration text.

If existing IP assignments are static and available to Ash before boot, the API
may include `ip`; otherwise dnsmasq should learn the IP from the DHCP lease.

## Proposed feasibility spike

### Phase 1: use the established host networking source of truth

This is now known: `my-nix/modules/nixos/ash-vm-network.nix` creates `ash0` and
dnsmasq assigns the addresses. Option A is available.

The first spike should test the unprivileged DHCP-hostname path:

1. In the agent image, set `networking.hostName = ""` so NixOS does not install
   the shared static `/etc/hostname` containing `nixos`.
2. Have Ash append a custom kernel argument such as `ash.vm-name=work` to the
   generated manifest's existing kernel parameter list.
3. Add an agent-image oneshot service ordered before `dhcpcd.service`. It parses
   `ash.vm-name=` from `/proc/cmdline`, validates it again, and writes it to
   `/proc/sys/kernel/hostname`. With no static `/etc/hostname`, this becomes the
   hostname dhcpcd advertises in DHCP option 12.
4. Confirm dhcpcd sends that hostname in its DHCP request.
5. Enable dnsmasq DNS and set the Ash domain.
6. Confirm the lease appears under the expected FQDN.

If the boot-time hostname is overwritten or is not available before dhcpcd's
first request, use the stable MAC-to-name registry instead.

### Phase 2: prove resolver behavior outside Ash

On a test bridge/network:

1. Serve one static A record from dnsmasq.
2. Route `~ash.test` to it with systemd-resolved.
3. Verify all normal libc clients, not only `dig`:

   ```sh
   resolvectl query demo.ash.test
   getent ahostsv4 demo.ash.test
   ssh demo.ash.test
   curl http://demo.ash.test/
   ```

4. If `.ash.local` remains required, separately test both:
   - Avahi publication, and
   - unicast routing behavior without breaking ordinary `.local` mDNS.

### Phase 3: add an Ash record interface

Before integrating privileges, expose testable data from the existing model,
for example:

```sh
ash network-records --json
```

Suggested fields:

```json
{
  "name": "work",
  "fqdn": "work.ash.test",
  "mac": "02:...",
  "status": "running",
  "ipv4": "192.168.x.y"
}
```

This can support either a dnsmasq helper or an Ash DNS daemon without coupling
DNS policy directly to `ash ls` formatting.

### Phase 4: lifecycle integration

For DHCP/MAC registration:

- register before starting or resuming a VM;
- retain registration while stopped if the DHCP/DNS policy permits stable
  names, or unregister on stop if stopped names must return NXDOMAIN;
- unregister when VM state is deleted;
- reconcile all existing state at helper startup so crashes cannot permanently
  desynchronize records.

For QGA/IP publication:

- publish after `wait_for_ssh_ready` obtains a usable IP;
- remove on stop, suspend, ephemeral cleanup, and VM deletion;
- add a periodic reconciliation pass for crashes and externally killed units.

### Phase 5: package host integration

If Ash should offer this as a supported feature rather than documentation only,
add a NixOS module exporting:

- bridge/DHCP/DNS settings or integration points,
- the configurable domain,
- systemd-resolved route configuration,
- helper daemon/socket permissions,
- firewall rules restricted to the Ash bridge/localhost, and
- end-to-end NixOS tests.

The current flake exports packages and apps only, so this would be new project
surface area.

## Tests required

- Stable MAC and normalized name produce the expected FQDN.
- Invalid names cannot inject DNS/dnsmasq configuration.
- Two VMs receive distinct records.
- Lease/IP changes update resolution.
- Stop/suspend/delete/crash behavior matches the documented policy.
- Reconciliation repairs stale or missing records.
- DNS is reachable from the host but not unintentionally from external links.
- Existing public DNS, Tailscale split DNS, and mDNS continue to work.
- `.local` behavior is explicitly tested if that suffix is supported.

## Open questions

1. Are the current dnsmasq addresses expected to remain stable across lease
   expiry, or is resolution required only while a VM is running?
2. Should stopped VMs continue to resolve to their last lease?
3. Is host-only resolution sufficient, or should guests and LAN peers resolve
   the names too?
4. Is `vm-name.ash.local` mandatory, or can the default be `vm-name.ash.test`?
5. May the reusable agent image intentionally have an empty static hostname so
   Ash can provide the per-instance hostname at boot?
6. How should Ash names containing dots, underscores, uppercase characters, or
   more than 63 characters map to a collision-free DNS label?

## Recommendation for the next implementation step

Prototype the existing dnsmasq path rather than building a new DNS daemon:

1. Add a DNS domain and enable dnsmasq's DNS listener in
   `my-nix/modules/nixos/ash-vm-network.nix`.
2. Make the reusable agent image accept a runtime hostname instead of fixing all
   instances to `nixos`.
3. Make Ash inject a DNS-safe VM hostname before DHCP starts.
4. Configure the host's systemd-resolved instance with a per-link DNS server and
   route-only Ash domain on `ash0`.
5. Verify with `getent`, SSH, and HTTP, then test lease renewal and duplicate
   names.

Only add a privileged MAC registry if the DHCP-hostname experiment fails. Treat
Avahi as a separate compatibility path only if `.ash.local` is non-negotiable.
