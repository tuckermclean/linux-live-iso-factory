# Kernel module tiers — the three-tier driver regime

The Monolith runs on everything from an i486 with a few MB of RAM to a modern
UEFI box. Those two worlds have opposite needs: the 486 cannot spare RAM for
drivers it will never use, while the modern box wants broad hardware coverage.
Compiling *everything* into the kernel (`=y`) satisfies the modern box and
starves the 486; compiling everything as modules starves nothing but risks a
machine that can't find its own boot media.

The regime resolves this by splitting drivers into three tiers by **when** they
must be available, not by how useful they are.

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

### Tier 1 — initramfs modules: "reach the media"

Drivers a given machine needs to *find and mount the squashfs* but that the 486
doesn't need built in — e.g. AHCI, NVMe, USB mass-storage, and their bus/HID
prerequisites for boot from those media. They ship inside the initramfs (not the
squashfs, which isn't mounted yet) and load before the root pivot.

**Status: not yet populated.** Today the only supported boot medium is the
CD-ROM, whose driver is Tier 0, so the initramfs carries no modules. Tier 1 is
Phase 2 of the regime (`configs/initrd-modules.txt` + `build-initrd.sh`).

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

## The `CONFIG_TRIM_UNUSED_KSYMS` watch-item

`CONFIG_TRIM_UNUSED_KSYMS=y` drops kernel symbols no *built-in* code references.
When a driver moves from `=y` to `=m`, any symbol it alone kept alive can be
trimmed, and the now-modular driver fails to load with `Unknown symbol` at
`modprobe` time. If a newly-modularized Tier 2 driver won't load, suspect this
first: confirm the symbol survives, or keep the dependency `=y`. The Phase 1
drivers above load cleanly under trimming; treat it as a checklist item, not a
blanket blocker, when adding more.
