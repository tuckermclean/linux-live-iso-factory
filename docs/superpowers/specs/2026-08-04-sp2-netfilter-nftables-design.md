# SP2 — Netfilter (`=m`) + nftables + `monolith-router`

- **Date:** 2026-08-04
- **Status:** Approved (design), pending spec review
- **Branch:** `feat/sp2-netfilter-nftables`
- **Part of:** the networking-box arc (SP2 of SP1–SP5). Depends on SP1 (NICs).

## 1. Motivation

SP1 made the box *reach* any network; SP2 makes it *route* one. Turn The
Monolith into a one-command NAT router: a machine with two NICs masquerades a
private LAN out to a WAN. `CONFIG_NETFILTER` is currently entirely off, so this
is mostly a kernel change (the framework + conntrack/NAT as load-on-demand
modules) plus the nftables userland and a `monolith-router` helper.

## 2. Goals / Non-goals

**Goals**
- Netfilter framework + conntrack/NAT/nftables as Tier-2 (`=m`) — zero resident
  cost until the box actually routes.
- `net-firewall/nftables` in the image (the single firewall userland).
- `monolith-router` — one command stands up IPv4 NAT (ip_forward + masquerade).
- A **real two-node CI test**: a router VM and a client VM on a private segment,
  the client reaching a service through the router's masquerade.

**Non-goals**
- **DHCP/DNS for LAN clients** — that's SP3 (dnsmasq). SP2 clients use static IPs.
- **iptables / xtables** — nftables-only; no compat layer.
- **IPv6 NAT, port-forwarding/DNAT, traffic shaping** — future; SP2 is SNAT/masquerade.

## 3. Kernel configuration (`configs/kernel.config`, revbump `-r5→-r6`)

Framework *gate* on (tiny, no resident tables), the heavy parts `=m`:

| Symbol | Value | Why |
|---|---|---|
| `CONFIG_NETFILTER` | `y` | framework gate (hooks only) |
| `CONFIG_NETFILTER_ADVANCED` | `y` | exposes the nft sub-options |
| `CONFIG_NF_CONNTRACK` | `m` | connection tracking (NAT needs it) |
| `CONFIG_NF_NAT` | `m` | NAT core |
| `CONFIG_NF_TABLES` | `m` | nftables core |
| `CONFIG_NF_TABLES_INET` | `m` | the `inet` family (v4+v6 in one table) |
| `CONFIG_NFT_CT` | `m` | `ct` expression (conntrack match) |
| `CONFIG_NFT_NAT` | `m` | `nat` statement |
| `CONFIG_NFT_MASQ` | `m` | `masquerade` statement |
| `CONFIG_NF_DEFRAG_IPV4` | `m` | dep of conntrack/NAT |

(`NF_NAT_MASQUERADE` auto-selects from `NFT_MASQ`.) No `IP_NF_*`/`NETFILTER_XTABLES`.
`build.yml`'s `.ko`-ship assertion (SP1 pattern) extended to these modules.

**Mandatory kernel ebuild revbump** `-r5 → -r6` + `versions.lock` pin (binpkg-cache
trap — same as SP1). Symbol validity in the 6.12 Kconfig is CI-authoritative.

## 4. Userland — `net-firewall/nftables`

Add to `configs/portage/world`; likely `configs/portage/package.use` to trim USE
to `-json -xtables -python` (stay lean, avoid extra deps where possible). Pulls
`dev-libs/libmnl` + `net-libs/libnftnl` (+ `gmp`, `readline`).

**SP2's primary build risk** (the SP1-equivalent of the retired-symbol unknown):
those libs cross-compiling **static i486-musl** under crossdev. Alpine/buildroot
build them static-musl routinely, so feasible — but unverified here; the
`full-ci` build is the authoritative catch. If a dep fights the static/musl
build, that surfaces as a red `build` job, fixed like any cross-compile wall.

## 5. `monolith-router` (`/usr/sbin`, standalone + unit-tested) + allowlist

Follows SP1's `configs/rootfs-overlay/` + unit-test pattern. Installed to
`/usr/sbin` (privileged system-config command; matches `monolith-advisory-check`).
Add `usr/sbin/monolith-router` to `configs/attestation/unowned-allowlist.yaml`
(the SP1 lesson — every hand-authored rootfs file needs an entry).

**Interface model:** `monolith-router [<wan> <lan>]`. With args, explicit. Zero-arg
auto: WAN = interface of the default route; LAN = the other non-`lo` interface
(error clearly if ambiguous — 0 or >1 candidates).

**Subcommands:**
- `monolith-router [<wan> <lan>]` (up) —
  1. `net.ipv4.ip_forward=1` (via `/proc/sys/...`).
  2. Bring up LAN with a default gateway IP `192.168.99.1/24` if it has no address
     (override via `MONOLITH_LAN_CIDR`); WAN keeps its DHCP/existing address.
  3. Install one nftables table (idempotent — delete-then-add):
     ```
     table inet monolith_router {
       chain postrouting { type nat hook postrouting priority srcnat;
                            oifname "<wan>" masquerade }
       chain forward     { type filter hook forward priority filter; policy drop;
                            ct state established,related accept
                            iifname "<lan>" oifname "<wan>" accept }
     }
     ```
- `monolith-router down` — delete the table, `ip_forward=0`.
- `monolith-router status` — print ip_forward, the nft ruleset, and iface addresses.

**Unit tests** (stub `nft`/`ip`/`sysctl` on PATH, fixture `/sys/class/net` +
`/proc/.../ip_forward`): verify up installs masquerade+forward for the resolved
ifaces and sets ip_forward; auto-detection picks the default-route iface; ambiguous
auto errors non-zero; down tears it all down; status reflects state.

## 6. The two-node NAT CI test — the star

A real client-through-router-to-service path, deterministic and self-contained.

**Topology (two QEMU processes, one CI job):**
- **Private LAN segment** via QEMU socket netdevs: router LAN NIC
  `-netdev socket,id=lan,listen=:<port>`; client NIC
  `-netdev socket,id=lan,connect=127.0.0.1:<port>` — a real L2 link. Router
  starts first (listens); client connects.
- **Router WAN** = `-netdev user` (SLIRP). SLIRP's gateway `10.0.2.2` *is the CI
  host*, so the "internet" is a throwaway `python3 -m http.server` on the runner —
  no external-internet flakiness.
- Both NICs use an `=m` coldplug model (e1000).

**`boot-test.py` gains a `nat` mode** that orchestrates two pexpect children:
1. Spawn **router**, boot to shell, run `monolith-router eth0 eth1` (eth0=WAN/user,
   eth1=LAN/socket). Assert on the router: `ip_forward=1` and `nft list ruleset`
   contains `masquerade`.
2. Spawn **client**, boot to shell, configure static:
   `ip addr add 192.168.99.2/24 dev eth0; ip link set eth0 up;
    ip route add default via 192.168.99.1`.
3. **Negative control:** *before* enabling routing would be ideal, but ordering
   makes it fragile; instead assert a wrong path fails — the client cannot reach
   `10.0.2.2` on a bogus port / the router's `forward` policy is `drop` by default.
   (Kept lightweight; the positive assertion is the real proof.)
4. **Positive proof:** on the client, `curl -s -m 15 http://10.0.2.2:8000/` returns
   the server's directory listing — success *only if* the packet was forwarded,
   masqueraded, conntracked, and the reply routed back. Assert on a known marker
   in the listing.
5. Tear both down; on any failure, dump both serial logs (uploaded as artifacts).

**Workflow:** a `nat-router` job starts `python3 -m http.server 8000 --bind 0.0.0.0`
on the runner (background), runs `boot-test.py --mode nat`, then stops the server.
`MODE_DEFAULT_RAM["nat"]` sized for two guests (each 256M).

## 7. Testing summary & risks

- **Kernel modules build/ship** → `build.yml` `.ko` assertion (catches a retired
  netfilter symbol).
- **`monolith-router` logic** → local stub unit tests (fully verifiable here).
- **End-to-end NAT** → the two-node `nat` job (CI-authoritative).
- **Risks:** (a) nftables + libnftnl/libmnl/gmp static-musl cross-build; (b) a
  6.12-retired netfilter symbol; (c) **the two-VM orchestration working first-try
  on CI** — I can't run QEMU locally, so the `nat` mode is designed defensively
  (generous timeouts, router-before-client ordering, both serial logs captured)
  but the first `full-ci` run is its real test; (d) SLIRP host-reach at `10.0.2.2`
  (standard QEMU behaviour; version-independent in practice).

## 8. Files touched

- `configs/kernel.config` — netfilter gate + `=m` symbols.
- `configs/overlay/sys-kernel/monolith-kernel/…-r5.ebuild` → `-r6.ebuild` (git mv);
  `configs/portage/versions.lock` pin.
- `configs/portage/world` (+ `package.use`/`package.accept_keywords` as needed) — nftables.
- `configs/rootfs-overlay/usr/sbin/monolith-router` (new) + `scripts/tests/monolith-router.test.sh` (new).
- `scripts/build-rootfs.sh` — install `monolith-router`.
- `configs/attestation/unowned-allowlist.yaml` — `usr/sbin/monolith-router`.
- `scripts/boot-test.py` — `nat` mode (two-child orchestration, builders, assertions).
- `.github/workflows/boot-test.yml` — `nat-router` job (+ host http.server) and the
  `.ko` assertion list in `build.yml`.
