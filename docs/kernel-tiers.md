# Kernel module tiers — the three-tier driver regime

The Monolith runs on everything from an i486 with a few MB of RAM to a modern
UEFI box. Those two worlds have opposite needs: the 486 cannot spare RAM for
drivers it will never use, while the modern box wants broad hardware coverage.
Compiling *everything* into the kernel (`=y`) satisfies the modern box and
starves the 486; compiling everything as modules starves nothing but risks a
machine that can't find its own boot media.

The regime resolves this by splitting drivers into three tiers by **when** they
must be available, not by how useful they are.

That resolution has a corollary worth stating up front, because it drives every
decision in Tier 1 below: a module that never loads costs the 486 nothing at
steady state. The tier that finds and mounts the boot medium is therefore the
one place in the regime where breadth is close to free and caution is the
expensive choice, not the cheap one. Tier 1 is Phase 2 of the regime, it is
underway now, and — unlike Tier 2's one-family-at-a-time modularization — it is
being built **deliberately broad**.

> **Why this lives in a doc and not in `kernel.config` comments.** The kernel
> ebuild (`configs/overlay/sys-kernel/monolith-kernel/*.ebuild`) does
> `cp .config "${CONFIGS_DIR}/kernel.config"` at the end of every build, so
> `olddefconfig`'s normalization erases any hand-written comments in that file.
> This document is the durable home for the policy. `kernel.config` is the
> machine-managed artifact; this is the contract it must satisfy.

## The three tiers

### Tier 0 — built into `bzImage` (`=y`): the 486 contract

The **minimum** set that lets a 486 reach a shell from the install media with
**zero modules loaded**. This is a *ceiling*, not a floor: every `=y` driver is
RAM the smallest supported machine pays for unconditionally, forever. Adding a
driver here must clear a high bar — "a machine that has nothing else can't boot
without it."

The boot-critical `=y` members, and why each is built in:

| Area | Symbols | Why it must be `=y` |
|------|---------|---------------------|
| Boot media | `CONFIG_ATA=y`, `CONFIG_ATA_PIIX=y`, `CONFIG_BLK_DEV_SR=y`, `CONFIG_CDROM=y` | Reach the CD-ROM before any module could be loaded from it |
| Filesystems | `CONFIG_ISO9660_FS=y`, `CONFIG_SQUASHFS=y`, `CONFIG_OVERLAY_FS=y`, `CONFIG_TMPFS=y`, `CONFIG_VFAT_FS=y` | Mount the disc, the squashfs on it, and the writable overlay |
| Early userland | `CONFIG_BLK_DEV_INITRD=y`, `CONFIG_DEVTMPFS=y`, `CONFIG_DEVTMPFS_MOUNT=y` | Run the initramfs and populate `/dev` before udev-less coldplug |
| Console | `CONFIG_SERIAL_8250=y` (+ `_CONSOLE`), `CONFIG_FB=y`, `CONFIG_FB_EFI=y` | A visible console on both serial (486/CI) and UEFI framebuffer |
| Platform | `CONFIG_ACPI=y`, `CONFIG_EFI=y` | Power-off (ACPI S5, which lets `boot-test.py` terminate QEMU) and UEFI boot |
| Module machinery | `CONFIG_MODULES=y`, `CONFIG_MODULE_UNLOAD=y` | Load Tier 1/2 at all, and let the 486 *unload* what it doesn't want |

**Do not add drivers to Tier 0 to fix a specific machine's boot** unless that
machine's boot *media* is unreachable without it (that's Tier 1's job — see
below). NICs, mice, sound, USB HID, and graphics accelerators belong in Tier 2.

> **Audit item: `CONFIG_ATA_PIIX` is not enough.** `ata_piix` covers Intel
> southbridges, but the Socket-7 486/Pentium-class world this ISO claims to
> serve was never Intel-only — VIA, SiS, and ALi southbridges were common on
> that generation of boards, and they're the myth's core constituency, not an
> edge case. Whatever gives those chipsets PATA support (`pata_legacy` /
> `ata_generic` as a floor, or the specific `pata_via` / `pata_sis` /
> `pata_ali` drivers where they do better than the generic ones) must be `=y`,
> the same as `ata_piix` — never a module, because the kid's machine *is* Tier
> 0 by definition: it has nothing else to load a module with. This document
> records the requirement; the actual `kernel.config` audit against it is
> tracked separately.

### Tier 1 — initramfs modules: "reach the media"

Drivers a given machine needs to *find and mount the squashfs* but that the 486
doesn't need built in — storage controllers, their USB/bus prerequisites, and
nothing else. They ship inside the initramfs (not the squashfs, which isn't
mounted yet) and load, by modalias coldplug, before the root pivot.

**Status: Phase 2, populated broad.** `configs/initrd-modules.txt` +
`build-initrd.sh` carry a wide manifest of storage- and bus-adapter drivers
spanning three decades of hardware, on purpose.

#### Why broad is correct here

A Tier-1 module only ever costs the 486 two things: the time to load it off the
CD once, and the RAM it occupies temporarily until `switch_root` frees the
initramfs. Neither cost survives into steady state. That's the structural
guarantee the whole regime is built on, and it holds regardless of how large
the Tier-1 manifest grows: a resident `=y` driver costs RAM forever, whether or
not the hardware it drives is present; an initrd `=m` driver the machine never
loads costs nothing once the shell comes up. Growing Tier 1 does not erode the
486 contract Tier 0 makes — it can't, by construction.

The actual bill, measured: the broad manifest is roughly 3 MB of `.ko` files
uncompressed, which gzip's down to about 1.2 MB inside the initrd cpio — on a
2x CD-ROM, on the order of four extra seconds before the shell appears. That is
the right sacrifice for this project. Trimming hardware out of Tier 1 to save
those seconds is the wrong one: it means some machine, somewhere between 1996
and 2026, finds its CD-ROM but can't find *itself* on it, which is precisely
the failure Tier 1 exists to prevent. This ISO is meant to follow you from 1996
to 2026 and beyond; a few seconds of extra spin-up is a small price for that
promise.

#### The manifest

Organized by the controller family it drives and the era of hardware it exists
for, not alphabetically — the point of this table is to show the span, not the
symbol list.

| Controller family | Representative modules | Era / hardware it serves |
|---|---|---|
| AHCI / SATA | `ahci` | 2004–present; the default SATA controller mode |
| NVMe | `nvme` | 2015–present; PCIe SSD boot |
| USB host controllers (full chain) | `uhci_hcd`, `ohci_hcd`, `ehci_hcd`/`ehci_pci`, `xhci_hcd`/`xhci_pci` | 1996 (UHCI)–2010 (xHCI). OHCI and UHCI matter as much as xHCI here: a 2002 machine booting from a USB CD-ROM is exactly what this ISO claims to follow you to |
| USB mass storage | `usb_storage`, `uas` | The USB flash drive or CD-ROM itself, once a host controller above has found it |
| Virtualized block | `virtio_blk`, `virtio_scsi` | VMs, cloud instances, and CI's own QEMU boots |
| SD/MMC | `sdhci`, `sdhci_pci`, `sdhci_acpi`, `mmc_block` | eMMC and SD-card boot media; SBCs |
| SAS/RAID HBAs — 2000s server room | `mptspi`, `mptsas` | LSI Fusion-MPT controllers, circa 2003 rackmount servers |
| SAS/RAID HBAs — 2010s server room | `mpt3sas`, `megaraid_sas` | LSI/Avago/Broadcom controllers, circa 2015 rackmount servers |
| Pre-AHCI SATA | `sata_sil`, `sata_via`, `sata_nv`, `sata_promise` | 2003–2006, SATA before AHCI existed — classic thrift-store add-in cards and chipsets |
| FireWire | `sbp2` | External FireWire storage — small, and exactly "hardware that followed someone" |

#### The firm line: no firmware-blob drivers

Breadth has one hard boundary. **No driver that requires loading a firmware
blob at runtime belongs in Tier 1** (or anywhere in the manifest, for that
matter). The brand promise here isn't only "boots on anything" — it's paired
with verifiability: every artifact on the ISO is attested, and a driver that
pulls in an opaque, separately-licensed firmware blob at load time breaks that
attestation chain. This is why WiFi — which almost universally needs
loadable firmware — is explicitly **not** in the manifest. It's deferred to a
future policy conversation about how (or whether) firmware blobs fit the
attestation model, not omitted by oversight.

#### The budget, reframed

There is an initrd size budget: **~6 MB uncompressed** triggers a required
human review before a PR that grows the manifest past it merges. Note what
that budget is *for*. The old, implicit ~2 MB expectation functioned as a
vanity metric wearing an engineering costume — a number that looked like a
constraint but wasn't actually protecting anything the structural RAM argument
above doesn't already protect. The ~6 MB line does the opposite job: it isn't
there to keep hardware out, it's there to make sure a human looks at *why* the
manifest grew before it grows further. Exclusion is not the goal; a deliberate,
reviewed decision is.

#### The escape hatch (future architecture, not built)

If real measurement — not speculation — ever shows the broad initrd
meaningfully hurting boot time on the slowest supported hardware, the
architecture already has an answer that doesn't require narrowing the
manifest: ship two initrds on one ISO, with ISOLINUX loading a lean one and
GRUB loading the full one. That buys back seconds on the machines that need
them most, at the cost of a second artifact to build, sign, and attest. It is
**not implemented now** — there's no measured problem to solve yet — but
naming it here matters: it's the reason we can go broad today without
flinching. If breadth ever turns out to be a real cost somewhere, there's
already a place to put the trade-off that isn't "quietly drop the driver."

### Tier 2 — rootfs squashfs modules (`=m`): "everything we like"

Every other driver. Compiled as `.ko`, installed into the sysroot by the
ebuild's `modules_install`, and carried into the rootfs squashfs by
`build-rootfs.sh`. After the real root is mounted, `rcS` walks `/sys` for
`modalias` files and `modprobe`s the matches (udev-less coldplug), so each
machine loads exactly the drivers its hardware advertises — and nothing else.

Phase 1 moved these out of the monolith and into Tier 2:

| Symbol | Was | Now | Driver |
|--------|-----|-----|--------|
| `CONFIG_E1000` | `=y` | `=m` | Intel e1000 (QEMU's default `pc` NIC) |
| `CONFIG_8139CP` | `=y` | `=m` | RealTek 8139C+ NIC |
| `CONFIG_8139TOO` | `=y` | `=m` | RealTek 8139 NIC |
| `CONFIG_MOUSE_PS2` | `=y` | `=m` | PS/2 mouse |
| `CONFIG_INPUT_EVDEV` | *unset* | `=m` | evdev input nodes |

## How the tiers prove themselves

- **The refund is real** — flipping the NICs and mouse to `=m` shrinks
  `bzImage`. Record the before/after size in the PR that changes the tier
  membership.
- **Coldplug actually loads them** — `boot-test.py`'s smoke suite asserts
  `lsmod` contains `e1000` (`smoke_nic_is_module`) *and* that `eth0` comes up
  with a DHCP lease. The first proves the module pipeline
  (compile → `modules_install` → squashfs → modalias coldplug → load); the
  second proves the driver then works. Keeping them separate localizes any
  fault to either the module machinery or the driver.

### The distribution model for Tier 1's broad manifest

A manifest spanning three decades of controllers cannot be exhaustively proven in CI, and QEMU
mostly can't provide the hardware to try — there is no virtual `mpt3sas`
backplane. So CI is not asked to prove the manifest's breadth; it's asked to
prove the *mechanism*, which is a much smaller and fully testable claim:

- A **NIC-less negative test** proves that a device class the running machine
  doesn't have costs nothing — no hang, no delay, no error, just an absent
  `modalias` match.
- Four **positive boot paths** — AHCI, NVMe, USB, and virtio — each prove the
  same pipeline end to end: initrd module load order, device settle timing,
  and retry-on-not-yet-enumerated all work for that class of controller.

Every other driver in the manifest rides those same four mechanisms; a
positive AHCI boot proves the coldplug-and-mount pipeline works for block
devices in general, not just for the `ahci` module specifically. What CI
deliberately does **not** attempt is per-controller proof for every entry in
the table above — proving `mpt3sas` against a real RAID backplane's firmware
gets proven the way the 486 itself gets proven: someone boots it on the real
hardware and reports back. For a project with this hardware span, that isn't a
gap in the test suite — it *is* the distribution model.

## The `CONFIG_TRIM_UNUSED_KSYMS` watch-item

`CONFIG_TRIM_UNUSED_KSYMS=y` drops kernel symbols no *built-in* code references.
When a driver moves from `=y` to `=m`, any symbol it alone kept alive can be
trimmed, and the now-modular driver fails to load with `Unknown symbol` at
`modprobe` time. If a newly-modularized Tier 2 driver won't load, suspect this
first: confirm the symbol survives, or keep the dependency `=y`. The Phase 1
drivers above load cleanly under trimming; treat it as a checklist item, not a
blanket blocker, when adding more.
