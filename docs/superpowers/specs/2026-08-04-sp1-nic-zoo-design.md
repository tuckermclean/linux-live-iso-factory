# SP1 — The NIC Zoo + `monolith-net` (ISA probe helper)

- **Date:** 2026-08-04
- **Status:** Approved (design), pending implementation plan
- **Branch:** `feat/sp1-nic-zoo`
- **Part of:** the "networking box" arc (SP1 of SP1–SP5). SP1 is the foundation:
  a router and a self-serving netboot both need NICs first.

## 1. Motivation

The covenant: one ISO that boots a 1996 machine and a 2026 machine should also
*network* both. Coldplug already self-assembles anything on a self-describing bus
— PCI cards emit a `modalias`, so `find /sys -name modalias | modprobe` in rcS
loads them with zero configuration and zero resident cost until the card is
present. The gap is exactly the 1996-shaped one: **ISA cards predate bus
self-description and emit no `modalias`.** A PCI machine assembles itself; the
kid's NE2000 needs `modprobe ne io=0x300` — the jumpers-and-IO-ports liturgy.
SP1 enables the full 30-year NIC set as Tier-2 (`=m`) modules and adds a small
helper that bridges the ISA gap without hiding it.

## 2. Goals / Non-goals

**Goals**
- Enable the full NIC set as Tier-2 (`=m`) kernel modules — ISA, PCI, gigabit,
  virtual — so every 1996–2026 controller is loadable, at zero resident RAM cost
  until present.
- Normalize: NICs currently built-in (`=y`) become `=m` so the zoo is uniformly
  coldplug/Tier-2.
- Add `monolith-net` + an `S35netprobe` boot step to reach ISA cards that cannot
  announce themselves, safely (Option A, §5).

**Non-goals (explicitly out of scope for SP1)**
- **PCMCIA/CardBus laptop NICs** (`3c589`, `pcnet_cs`, …) — pulls in the whole
  PCMCIA/yenta socket subsystem; a separate effort if ever wanted.
- **Netboot / network root** — SP3 (dnsmasq self-netboot). SP1 keeps all NICs in
  Tier-2 (rootfs squashfs); none are needed to *reach* the rootfs.
- **Firmware blobs** — never shipped (see §6).
- **Wireless** — noted for the future (`ath5k`/`ath9k` are the blob-free
  exceptions); not in SP1.

## 3. Kernel configuration (`configs/kernel.config`)

The bulk of SP1. Enable the vendor gates that are currently off, then set each
driver `=m`. Driver → `CONFIG_` symbol → vendor gate:

| Class | Driver | Symbol | Vendor gate (enable if off) | Action |
|---|---|---|---|---|
| ISA | ne (NE2000) | `NE2000` | `NET_VENDOR_8390` (off) | `=m` |
| ISA | wd (WD80x3) | `WD80x3` | `NET_VENDOR_8390` | `=m` |
| ISA | smc-ultra | `ULTRA` | `NET_VENDOR_8390` | `=m` (8390 sibling, free) |
| ISA | 3c509 | `EL3` | `NET_VENDOR_3COM` (on) | `=m` |
| ISA | lance | `LANCE` | `NET_VENDOR_AMD` (off) | `=m` |
| PCI-8390 | ne2k-pci | `NE2K_PCI` | `NET_VENDOR_8390` | `=m` (bonus, coldplugs) |
| PCI | pcnet32 | `PCNET32` | `NET_VENDOR_AMD` | `=m` |
| PCI | tulip | `TULIP` | (on) | **demote `=y→=m`** |
| PCI | 8139too | `8139TOO` | `NET_VENDOR_REALTEK` (on) | already `=m` |
| PCI | 8139cp | `8139CP` | `NET_VENDOR_REALTEK` | already `=m` |
| PCI | e100 | `E100` | `NET_VENDOR_INTEL` (on) | **demote `=y→=m`** |
| PCI | via-rhine | `VIA_RHINE` | `NET_VENDOR_VIA` (off) | `=m` |
| PCI | natsemi | `NATSEMI` | `NET_VENDOR_NATSEMI` (off) | `=m` |
| PCI | sis900 | `SIS900` | `NET_VENDOR_SIS` (off) | `=m` |
| GbE | e1000 | `E1000` | `NET_VENDOR_INTEL` | already `=m` |
| GbE | e1000e | `E1000E` | `NET_VENDOR_INTEL` | `=m` |
| GbE | igb | `IGB` | `NET_VENDOR_INTEL` | `=m` |
| GbE | r8169 | `R8169` | `NET_VENDOR_REALTEK` | **demote `=y→=m`** |
| GbE | sky2 | `SKY2` | `NET_VENDOR_MARVELL` (off) | `=m` |
| Virt | virtio-net | `VIRTIO_NET` | — | **demote `=y→=m`** |
| Virt | vmxnet3 | `VMXNET3` | — | **demote `=y→=m`** |
| Virt | hv_netvsc | `HYPERV_NET` | `CONFIG_HYPERV` | already `=m` |

Gates confirmed already on: `ISA`, `ISA_BUS`, `MII`, `ETHERNET`, `NETDEVICES`,
`NET_VENDOR_3COM`, `NET_VENDOR_INTEL`, `NET_VENDOR_REALTEK`.

### 3.1 CRITICAL — kernel ebuild revbump

Changing `configs/kernel.config` alone is **not enough**: Portage keys the kernel
binpkg on version+USE+CHOST, not on `.config`, so the shared S3 cache would serve
the old kernel and none of the new modules would be built. The kernel ebuild MUST
be revbumped: `monolith-kernel-6.12.80-r4.ebuild` → `-r5.ebuild` (git mv), and any
version pin in `configs/portage/versions.lock` updated to match. This is the same
binpkg-cache trap documented for the earlier module-tier phases.

## 4. Module delivery — no new machinery

The `=m` drivers ride the existing path: the kernel ebuild's
`modules_install INSTALL_MOD_PATH=${D}` puts them under `/lib/modules/${KVER}`,
they land in the rootfs squashfs, and `depmod`'s `modules.alias` lets coldplug
match them. **PCI/virtual NICs self-load via modalias with no further work.** ISA
cards emit no modalias — that is the entire gap SP1's helper fills. No initrd /
Tier-1 manifest change (NICs are not needed to reach the rootfs).

## 5. `monolith-net` + `S35netprobe` — Option A (safe-auto + opt-in sweep)

ISA drivers split by probe safety: `3c509` (and ISAPnP cards) *self-identify* via
the 3Com ID-port contention protocol — safe to load blindly. `ne`/`wd`/`lance`
need `io=`-style port sweeps, and blindly poking legacy I/O ports can wedge odd
hardware. So the automatic path only does what is safe; the risky sweep is opt-in.

### 5.1 `S35netprobe` (init.d, runs after rcS coldplug, before `S40network`)

```
start:
  if a non-'lo' interface already exists in /sys/class/net: exit 0   # coldplug won
  modprobe 3c509 2>/dev/null || true        # safe: ID-port self-detect
  # (room to trigger ISAPnP here in future)
  re-check /sys/class/net for a non-lo iface
  if found: exit 0                          # S40network will DHCP it
  # nothing safe found — do NOT blind-sweep automatically:
  print the incantation banner (see 5.3) pointing at `monolith-net probe`
```

Placed at `S35` so any woken NIC is up before `S40network` walks
`/sys/class/net/eth*|en*` and runs `dhcpcd -b`.

### 5.2 `monolith-net` (`/usr/bin/monolith-net`, on PATH)

- `monolith-net` (no args) / `monolith-net status` — list non-`lo` interfaces and
  link state; if none, print the incantation banner.
- `monolith-net probe` — the **opt-in bounded blind sweep**. For each legacy
  driver, try its common `io=` addresses, `modprobe <drv> io=<addr>`, and stop as
  soon as a new interface appears; then bring it up + `dhcpcd -b`. Bounded, ordered:
  - `ne`:    `0x300 0x280 0x320 0x340 0x360`
  - `wd`:    `0x240 0x300 0x280 0x2e0 0x350`
  - `lance`: `0x300 0x320 0x360 0x3a0`
  - On no hit: `rmmod` anything it speculatively loaded and report failure + the
    incantation (so a bad guess leaves no half-loaded driver resident).
- `monolith-net incantation` — just print the liturgy (addresses + `modprobe`
  examples), for the curious.

### 5.3 The incantation banner (period-authentic, shown not hidden)

```
No network card detected automatically.
ISA cards from before Plug-and-Play can't announce themselves — you tell the
kernel where the card lives:

    modprobe ne io=0x300        # NE2000 clone (try 0x280, 0x320, 0x340...)
    modprobe wd io=0x240        # SMC/WD 80x3
    modprobe lance io=0x300     # AMD LANCE

Or let the box try the common addresses for you:

    monolith-net probe
```

## 6. Firmware covenant

Do **not** set `CONFIG_EXTRA_FIRMWARE` (that would bake blobs into the kernel).
Most of the zoo is blob-free (e1000/e1000e/igb/sky2/tulip/pcnet32/via-rhine/
natsemi/sis900/8139). `r8169` (newest silicon) and `e100` (optional CPU-saver
ucode) *reference* firmware but initialize without it on older revisions — enable
them; they degrade honestly. The image ships no firmware files.

## 7. Testing — with teeth

QEMU emulates a good slice of the zoo, so `boot-test.py` gets a NIC-model matrix
in addition to the build-ship assertion:

- **Build/ship:** after the build, assert the new `.ko`s exist under
  `/lib/modules/${KVER}` (e.g. `ne.ko`, `3c509.ko`, `pcnet32.ko`, `sky2.ko`).
- **Coldplug proof (modalias path):** boot with each of `-nic model=pcnet`,
  `model=rtl8139`, `model=tulip`, `model=ne2k_pci` and assert the matching driver
  (`pcnet32`, `8139too`/`8139cp`, `tulip`, `ne2k-pci`) appears in `lsmod`.
- **ISA-probe proof (the headline):** boot with `-nic model=ne2k_isa` (an ISA
  NE2000 with no modalias, default `io=0x300`), assert coldplug did **not** load it,
  run `monolith-net probe`, and assert `ne` is then loaded and an interface exists.
- **Negative control (already present):** `nicless` asserts no NIC driver loads
  when no NIC hardware exists — keep it green (now checks a modular NIC).

The existing `e1000` coldplug assertion stays valid (e1000 remains `=m`).

## 8. Risks & mitigations

- **Binpkg cache trap** — mitigated by the mandatory kernel revbump (§3.1).
- **`S35netprobe` false-negative on a slow ISA card** — the safe path only tries
  `3c509`; anything else is user-driven, so timing is not on the boot critical path.
- **Blind sweep leaves a driver half-loaded on a bad guess** — `monolith-net probe`
  `rmmod`s speculative loads that produced no interface (§5.2).
- **A legacy ISA symbol retired in 6.12** — some pre-PnP drivers may have been
  removed upstream. The implementation validates each `CONFIG_` symbol against the
  actual kernel tree's Kconfig (e.g. `scripts/config`/menuconfig round-trip) and
  drops any that no longer exist, rather than silently carrying a dead symbol that
  makes the `.config` diff lie.
- **Squashfs growth** — ~15 small `.ko`s (10–50KB each); negligible.
- **A demoted `=y→=m` NIC regressing a boot path** — none of these NICs is needed
  to reach a shell (storage is Tier-0/Tier-1); the boot-test matrix proves coldplug.

## 9. Files touched

- `configs/kernel.config` — vendor gates + driver `=m` + demotions.
- `configs/overlay/sys-kernel/monolith-kernel/monolith-kernel-6.12.80-r4.ebuild`
  → `-r5.ebuild` (git mv); `configs/portage/versions.lock` pin update.
- `scripts/build-rootfs.sh` — new `/usr/bin/monolith-net` + `/etc/init.d/S35netprobe`
  heredocs.
- `scripts/boot-test.py` + `.github/workflows/boot-test.yml` — NIC-model matrix
  + module-ship assertion.
