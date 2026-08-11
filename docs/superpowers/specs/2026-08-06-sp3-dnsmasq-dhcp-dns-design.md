# SP3 — dnsmasq: LAN DHCP + DNS (folded into `monolith-router`)

- **Part of:** the networking-box arc (SP3 of SP1–SP5). Depends on SP1 (NICs) and
  SP2 (`monolith-router` NAT). Completes the home-router trifecta: **NAT + DHCP + DNS**.
- **Status:** design approved 2026-08-06.

## 1. Motivation

SP2 made The Monolith a one-command NAT router, but LAN clients had to be
configured by hand (static IPs, manual DNS). A real "li'l router" hands out
addresses and answers names. SP3 adds `net-dns/dnsmasq` and folds **DHCP + DNS
for the LAN** into `monolith-router`, so one command turns the box into a
complete home router: it NATs to the WAN, leases addresses on the LAN, and
resolves both LAN client names and forwarded/cached public names.

Because a DHCP server is the one genuinely dangerous service here — plug the box
into a network that already has a DHCP server and it starts fighting it — DHCP
is **off by default** and gated behind an explicit flag **and** a sudo-style
one-time lecture. Everything is secure by default and structurally unable to
answer on the WAN.

## 2. Goals / Non-goals

**Goals**
- Add `net-dns/dnsmasq` (static musl, IPv4-only) to the world/build.
- Extend `monolith-router` with an opt-in `--dhcp` that brings up dnsmasq for
  DHCP + DNS on the LAN interface, plus `--domain <zone>` and `--yes`.
- Secure by default: bound to the LAN address only; no open resolver; DNS-rebind
  protection; drops privileges; no exec/dbus surface.
- A local authoritative zone (default `home.arpa`) in which DHCP client
  hostnames register automatically (`laptop.home.arpa` → its lease).
- Extend the SP2 two-node CI test so the client gets its lease **via DHCP** and
  resolves a zone name through the box, while NAT still works.
- Unit tests for the flag parsing, the safety gate, and the generated config.

**Non-goals (explicitly deferred)**
- **Netboot / TFTP / PXE / network-root.** Serving or booting The Monolith over
  the network requires the client's initramfs to carry the right NIC driver;
  you cannot bake in every NIC, so it needs an **initrd-mod selection UI**,
  which in turn wants **persistence** underneath it. Roadmap order:
  persistence → initrd-mod UI → netboot. dnsmasq's TFTP capability is left
  unbuilt (`-tftp`) until then.
- **IPv6 / dual-stack DHCPv6+RA.** Tracks the project-wide IPv4-only posture
  (`-ipv6`); enabled with the future IPv6 task.
- **DNSSEC validation.** Heavy for a minimal static build (needs a trust anchor);
  noted as a future enhancement.
- **Non-/24 LAN DHCP.** Automatic range derivation is guaranteed for `/24`
  (the default); `--dhcp` with a non-`/24` CIDR is rejected with guidance.

## 3. Package — `net-dns/dnsmasq` (static musl, IPv4-only)

- Add `net-dns/dnsmasq` to `configs/portage/world`.
- USE (in `configs/portage/package.use/`): **`-dbus -script -nls -ipv6 -dnssec
  -tftp`**. Dropping `script` removes the lease-change **exec surface**; no dbus
  IPC surface; `-tftp` keeps the deferred netboot capability unbuilt.
- Inherits the global `*/* static static-libs`. dnsmasq is lean C with few deps,
  so the static-musl link is expected to be clean — but, per the SP2
  nftables/`readline` surprise, the **exact USE/link set is verified during
  implementation**, not assumed. If a static link pulls an unexpected library,
  that is the SP3 build risk to resolve (mirror of SP1/SP2's build-risk clause).
- No kernel config change: DHCP/DNS are pure userland over UDP/TCP sockets.

## 4. `monolith-router` integration

`monolith-router` keeps its SP2 interface; SP3 adds three options. **Plain
`monolith-router up <wan> <lan> [<cidr>]` is unchanged — NAT only, no dnsmasq.**

```
monolith-router [up] <wan> <lan> [<cidr>] [--dhcp [--yes]] [--domain <zone>]
monolith-router down                 # tears down dnsmasq + NAT together
monolith-router status               # now also reports dnsmasq state
```

**New options**
- `--dhcp` — also start dnsmasq (DHCP + DNS) on `<lan>`. Off by default.
- `--domain <zone>` — authoritative LAN zone; default `home.arpa`, env fallback
  `$MONOLITH_LAN_DOMAIN`. Validated as a DNS domain (labels of
  `[A-Za-z0-9-]`, dot-separated). Only meaningful with `--dhcp`.
- `--yes` (a.k.a. `--i-understand`) — non-interactive acknowledgement of the
  DHCP lecture (for scripts/CI).

**The safety gate (the human half of "secure by default")**
- The first `--dhcp` of a boot session prints a short lecture:
  > `monolith-router: enabling a DHCP server on <lan>. It will hand out IP`
  > `leases and DNS to anything on that segment. Do NOT do this on a network`
  > `that already has a DHCP server (office/dorm/home ISP router) — you will`
  > `break it. Only proceed if THIS box owns the LAN.`
- **Interactive (stdin is a TTY):** prompt for a typed `yes`; anything else aborts.
- **Non-interactive (no TTY):** **fail closed** — refuse and exit non-zero unless
  `--yes` is present. A script can never enable a DHCP server by accident.
- After acknowledgement, a per-boot flag file
  `/run/monolith-router/dhcp-lectured` suppresses the lecture for the rest of the
  session. `/run` is tmpfs, so the lecture returns once per boot (until
  persistence exists to remember it).

**Ordering:** `cmd_up` assigns the LAN address first (SP2 behaviour, incl. the
PR #18 link-local fix), *then* starts dnsmasq — so dnsmasq's
`--bind-interfaces` bind to the LAN address always succeeds.

**Runtime state (all under `/run/monolith-router/`, tmpfs, never shipped):**
generated `dnsmasq.conf`, `dnsmasq.pid`, `dhcp-lectured`. `down` kills dnsmasq
via the pidfile and removes the directory (plus the SP2 nft/ip_forward teardown).
`status` reports up/down from the pidfile alongside the NAT state.

## 5. dnsmasq configuration (secure by default)

`cmd_up --dhcp` writes `/run/monolith-router/dnsmasq.conf` and launches
`dnsmasq --conf-file=/run/monolith-router/dnsmasq.conf`. The config:

**Binding — structurally WAN-unreachable**
- `interface=<lan>`, `bind-interfaces`, `except-interface=<wan>` — sockets open
  only on the LAN address. DHCP and DNS can never answer on the WAN.
- `local-service` — answer DNS only from hosts on a local subnet (no open
  resolver / no amplification role even if a WAN packet arrives).

**DNS hygiene**
- `domain=<zone>` + `local=/<zone>/` + `expand-hosts` — the zone is authoritative
  and never leaked upstream. Default `home.arpa` (RFC 8375, reserved for home
  networks; guaranteed never public).
- `stop-dns-rebind` + `rebind-localhost-ok` — DNS-rebinding protection (reject
  upstream answers pointing into private ranges; the "can't pivot an external
  domain into your LAN" lock).
- `domain-needed` + `bogus-priv` — never forward plain names or private reverse
  lookups upstream.
- Upstreams come from `/etc/resolv.conf` (dhcpcd-populated from the WAN lease);
  the box's own resolv.conf points at the real upstreams, not at dnsmasq, so
  there is no forwarding loop.

**DHCP**
- `dhcp-range=<lan-net>.50,<lan-net>.200,12h` derived from the LAN `/24`
  (e.g. `192.168.99.1/24` → `192.168.99.50,192.168.99.200`). Non-`/24` is
  rejected by `cmd_up` before dnsmasq is invoked.
- `dhcp-authoritative` — correct for the sole-router-on-LAN role.
- Gateway + DNS advertised to clients = the box's LAN address.
- DHCP client hostnames register into `<zone>` automatically (dnsmasq default) —
  `laptop` → `laptop.<zone>` → its leased IP; the box resolves as
  `monolith.<zone>`.

**Privilege drop**
- `user=<unprivileged>` — dnsmasq binds as root then drops to an unprivileged
  user (the package's `dnsmasq` user, or `nobody`; confirmed during impl).
- `pid-file=/run/monolith-router/dnsmasq.pid`, `leasefile-ro` not used; leases in
  the dnsmasq default (`/var/lib/misc/dnsmasq.leases`, ephemeral overlay).

## 6. Attestation

- The runtime dnsmasq config/pid/lecture files live in `/run` (tmpfs) and are
  **not in the squashfs**, so they are not scanned — no allowlist entries for
  the helper's runtime state.
- Any **build-time** artifacts from dnsmasq's `pkg_postinst` that land in the
  rootfs (e.g. a `/var/lib/misc` directory, or a `dnsmasq` user — `/etc/passwd`
  is already allowlisted) get added to
  `configs/attestation/unowned-allowlist.yaml`, same class as SP2's
  `/var/lib/nftables/rules-save`. Exact set confirmed from the build's Pillar-4
  output during implementation.

## 7. Testing

**Unit tests** (extend `scripts/tests/monolith-router.test.sh`; stub `dnsmasq`
on PATH the way `nft`/`ip` are stubbed — log argv + the generated conf):
- `--dhcp --yes` writes a conf containing the derived range, `interface=<lan>`,
  `domain=home.arpa` / `local=/home.arpa/`, and every hardening flag
  (`bind-interfaces`, `local-service`, `stop-dns-rebind`, `domain-needed`,
  `bogus-priv`, `dhcp-authoritative`).
- `--domain home.example` overrides the zone in the conf.
- **Safety gate:** run non-interactively (test stdin is not a TTY) — `--dhcp`
  without `--yes` exits non-zero and starts nothing; `--dhcp --yes` proceeds and
  writes the lecture flag.
- Plain `up` (no `--dhcp`) never invokes dnsmasq.
- Non-`/24` CIDR with `--dhcp` errors before dnsmasq is invoked.
- `down` kills dnsmasq via the pidfile; `status` reports its state.

**Two-node CI test** (extend the SP2 `nat` mode in `scripts/boot-test.py`,
reusing the `drain_router` + router-side-diagnostics harness):
1. Router: `monolith-router up eth0 eth1 --dhcp --yes` → NAT + dnsmasq.
2. **Secure-by-default assertion:** on the router, `ss -lntu` shows dnsmasq bound
   to the LAN address only — never the WAN address or a wildcard.
3. Client: runs `dhcpcd` on eth0 (no static IP) → obtains a lease **in
   `192.168.99.50–200`**, with gateway + DNS = the box.
4. **Local zone (deterministic DNS proof):** the client resolves its own
   `<hostname>.home.arpa` and `monolith.home.arpa` through the box to the
   expected addresses — proving DHCP-hostname→DNS registration.
5. **NAT still works:** the client curls the host `http.server` through NAT over
   its DHCP-obtained config (external DNS forwarding via SLIRP is a *soft*
   check — the local zone is the hard assertion).
6. Teardown + the SP2 negative control (after `down`, the client can't reach the
   host).

## 8. Files touched

- `configs/portage/world` — add `net-dns/dnsmasq`.
- `configs/portage/package.use/dnsmasq` (new) — static, IPv4-only, minimal USE.
- `configs/rootfs-overlay/usr/sbin/monolith-router` — `--dhcp`, `--domain`,
  `--yes`, the lecture/fail-closed gate, dnsmasq config generation, teardown +
  status integration.
- `scripts/tests/monolith-router.test.sh` — the unit tests above.
- `scripts/boot-test.py` — extend `nat` mode with the DHCP client + DNS asserts.
- `configs/attestation/unowned-allowlist.yaml` — any dnsmasq build-time rootfs
  artifacts (confirmed from Pillar-4 output).
- `versions.lock` — dnsmasq pin (no kernel revbump; SP3 changes no kernel config).

## 9. Risks

- **Static-musl dnsmasq link** — expected clean, but an unexpected static lib
  (à la nftables/`readline`) is the primary build risk; resolve by USE/link
  adjustment.
- **CI DHCP-client timing** — the DHCP'd client is subject to the same LAN
  bring-up races SP2 hit; the harness's `drain_router` + router-side diagnostics
  + the PR #18 link-local fix apply. dhcpcd on the client replaces the static-IP
  step; assert the lease before asserting DNS/NAT.
- **resolv.conf loop** — avoided by keeping the box's own resolv.conf pointed at
  WAN upstreams, not at dnsmasq.
