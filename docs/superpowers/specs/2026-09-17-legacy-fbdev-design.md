# Legacy fbdev drivers as Tier-2 modules — design spec

*Status: design agreed. Implementation plan: `docs/superpowers/plans/2026-09-17-legacy-fbdev.md`.*
*Tracking: DCX-43 (child of DCX-42).*

## The problem

`configs/kernel.config` builds `CONFIG_FB=y` and ships exactly four framebuffer
drivers: `FB_VESA`, `FB_EFI`, `FB_SIMPLE` (all `=y`) and `FB_HYPERV` (`=m`).
Every legacy PCI/ISA framebuffer driver in the tree is `# CONFIG_FB_* is not set`.

That is a *working* console on every machine — vesafb rides the VBE BIOS, efifb
rides GOP — but it is a generic one. A 1998 Matrox Millennium, a Voodoo3, an S3
Trio64 all end up in the same 640×480-ish VBE mode their BIOS happens to offer,
with no mode list, no native timings, and no acceleration. The Monolith's claim
is "boots on everything, 1996→2026." Booting is already satisfied; what's
missing is that vintage boxes never get their *native* driver.

## The decision, in one line

Enable the legacy PC framebuffer driver set as **Tier 2 (`=m`)** — twenty-seven
`.ko` modules loaded post-boot by modalias coldplug — and prove the mechanism
with a CI module-presence assertion plus one QEMU boot test that coldplugs
`cirrusfb` against `-vga cirrus`.

## Why Tier 2 and not Tier 0

`docs/kernel-tiers.md` sets the bar for Tier 0 (`=y`) at **"a machine that has
nothing else can't boot without it."** These drivers fail that test by
construction, and it isn't a close call:

- Every machine that could load one of these drivers *already has a console*
  before the driver exists — vesafb (`FB_VESA=y`) on BIOS, efifb (`FB_EFI=y`)
  on UEFI. The native driver is an upgrade to an already-working console, never
  the thing that makes a console appear.
- They are graphics accelerators. The tiers doc names that class explicitly:
  *"NICs, mice, sound, USB HID, and graphics accelerators belong in Tier 2."*
- Tier 0 is a ceiling, not a floor. Twenty-seven graphics drivers built into
  `bzImage` is RAM the 486 pays forever, for hardware it does not have, to
  replace a console it already has. That is the exact trade the three-tier
  regime exists to refuse.

They are equally not Tier 1: Tier 1 is "reach the boot media," and no
framebuffer is on the path to mounting a squashfs. The initramfs does not grow.

So: **`=m`, in the rootfs squashfs, coldplugged by modalias.** The cost to a
machine without the hardware is zero at steady state — the same structural
guarantee the rest of Tier 2 rests on.

## Ground truth

Every claim below was checked against the actual pinned tree — Linux
**6.12.80** (`configs/portage/versions.lock`:
`sys-kernel/monolith-kernel:6.12.80-r6:0`), files
`drivers/video/fbdev/{Kconfig,Makefile}`, `.../core/Kconfig`,
`.../geode/Kconfig`, and the per-driver `Makefile`s, fetched at the `v6.12.80`
tag. The `drivers/video/fbdev/Kconfig` at `v6.12.80` is byte-identical to the
`v6.12` release, so nothing here is stable-branch drift.

Relevant config state already in `configs/kernel.config`: `CONFIG_FB=y`,
`CONFIG_PCI=y`, `CONFIG_ISA=y`, `CONFIG_X86_32=y`, `CONFIG_MODULES=y`,
`CONFIG_APERTURE_HELPERS=y`, `CONFIG_FONT_8x16=y`, `CONFIG_BITREVERSE=y`,
`CONFIG_FB_IOMEM_HELPERS=y`, `CONFIG_FB_MODE_HELPERS=y`,
`CONFIG_FB_CFB_{FILLRECT,COPYAREA,IMAGEBLIT}=y`, `CONFIG_TRIM_UNUSED_KSYMS=y`,
`# CONFIG_I2C is not set`, `# CONFIG_FB_TILEBLITTING is not set`,
`# CONFIG_BACKLIGHT_CLASS_DEVICE is not set`.

## The list — 24 symbols, 27 modules

All are `tristate` with dependencies satisfied on this config, so all survive
`olddefconfig` as `=m`.

| Symbol | `.ko` | Kconfig `depends on` | Hardware |
|---|---|---|---|
| `FB_CIRRUS` | `cirrusfb` | `FB && (ZORRO \|\| PCI)` | Cirrus Logic GD-543x/544x/5480 |
| `FB_PM2` | `pm2fb` | `FB && ((AMIGA && BROKEN) \|\| PCI)` | 3DLabs Permedia 2/2V |
| `FB_PM3` | `pm3fb` | `FB && PCI` | 3DLabs Permedia 3 |
| `FB_CYBER2000` | `cyber2000fb` | `FB && PCI && HAS_IOPORT && (BROKEN \|\| !SPARC64)` | Integraphics CyberPro 20x0/5000 |
| `FB_VGA16` | `vga16fb` | `FB && X86` | Plain VGA, 16-colour planar |
| `FB_HGA` | `hgafb` | `FB && X86` | Hercules mono |
| `FB_NVIDIA` | `nvidiafb` | `FB && PCI` | nVidia TNT and newer |
| `FB_RIVA` | `rivafb` | `FB && PCI` | nVidia Riva 128 / early GeForce |
| `FB_I740` | `i740fb` | `FB && PCI` | Intel740 |
| `FB_MATROX` | `matroxfb_base` (+ `matroxfb_{accel,DAC1064,Ti3026,misc}`) | `FB && PCI` | Matrox Millennium/Mystique/G100–G550 |
| `FB_RADEON` | `radeonfb` | `FB && PCI` | ATI Radeon |
| `FB_ATY128` | `aty128fb` | `FB && PCI` | ATI Rage 128 |
| `FB_ATY` | `atyfb` (+ `macmodes`) | `FB && !SPARC32` | ATI Mach64 |
| `FB_S3` | `s3fb` | `FB && PCI && HAS_IOPORT` | S3 Trio / Virge |
| `FB_SAVAGE` | `savagefb` | `FB && PCI` | S3 Savage |
| `FB_SIS` | `sisfb` | `FB && PCI && HAS_IOPORT` | SiS 300/315/330/340, XGI |
| `FB_NEOMAGIC` | `neofb` | `FB && PCI && HAS_IOPORT` | NeoMagic (90s laptops) |
| `FB_KYRO` | `kyrofb` | `FB && PCI` | IMG Kyro / STG4000 |
| `FB_3DFX` | `tdfxfb` | `FB && PCI && HAS_IOPORT` | 3Dfx Banshee / Voodoo3 / VSA-100 |
| `FB_VOODOO1` | `sstfb` | `FB && PCI` | 3Dfx Voodoo Graphics / Voodoo2 |
| `FB_VT8623` | `vt8623fb` | `FB && PCI && HAS_IOPORT` | VIA CastleRock (Apollo CLE266) |
| `FB_TRIDENT` | `tridentfb` | `FB && PCI && HAS_IOPORT` | Trident TGUI / Blade / CyberBlade |
| `FB_ARK` | `arkfb` | `FB && PCI && HAS_IOPORT` | ARK Logic 2000PV |
| `FB_SM712` | `sm712fb` | `FB && PCI && HAS_IOPORT` | Silicon Motion SM712 |
| `FB_GEODE` **(bool gate `=y`)** | — | `FB && PCI && (X86_32 \|\| …) && !UML` | menu gate only, no code |
| ↳ `FB_GEODE_LX` | `lxfb` | `FB && FB_GEODE` | AMD Geode LX |
| ↳ `FB_GEODE_GX` | `gxfb` | `FB && FB_GEODE` | AMD Geode GX |
| ↳ `FB_GEODE_GX1` | `gx1fb` | `FB && FB_GEODE` | AMD Geode GX1 |

`FB_GEODE` is the one `=y` in this change and it is **not** a Tier-0 addition:
it is a `bool` menu gate with no object file attached (`obj-$(CONFIG_FB_GEODE)
+= geode/`), so setting it `y` adds nothing to `bzImage`. The three drivers
behind it are `=m` like everything else.

### Sub-options that must be set explicitly

`olddefconfig` will pick the Kconfig default for every sub-option, and for
several of these the default is wrong for us. These are the traps:

**Drivers that build empty at their defaults.** `atyfb`, `matroxfb` and `sisfb`
gate their actual chip support behind `bool` sub-options that default to `n` on
x86. Enable the symbol alone and you get a `.ko` that supports no hardware:

```
CONFIG_FB_MATROX_MILLENIUM=y
CONFIG_FB_MATROX_MYSTIQUE=y
CONFIG_FB_MATROX_G=y
CONFIG_FB_MATROX_I2C=m
CONFIG_FB_ATY_CT=y
CONFIG_FB_ATY_GX=y
CONFIG_FB_SIS_300=y
CONFIG_FB_SIS_315=y
```

(`FB_SIS` already `select FB_SIS_300 if !FB_SIS_315`, so 300 would arrive
anyway; we set both so the symbol list states the intent rather than relying on
a conditional select.)

**The DDC → `CONFIG_I2C=y` trap — this is the important one.**
`FB_DDC` is a `tristate`. Kconfig's `select` raises the target to *at least* the
selecting symbol's value, so a **`bool`** sub-option at `y` forces `FB_DDC=y`,
which `select I2C` forces `CONFIG_I2C=y` — i2c-core built into `bzImage`. Three
such sub-options are `default y`:

| Sub-option | Default | Type | Effect if left at default |
|---|---|---|---|
| `FB_RADEON_I2C` | `y` | bool | `FB_DDC=y` → `I2C=y` (built-in) |
| `FB_3DFX_I2C` | `y` | bool | `FB_DDC=y` → `I2C=y` (built-in) |
| `FB_CYBER2000_DDC` | `y` | bool | `FB_DDC=y` → `I2C=y` (built-in) |

Silently growing Tier 0 by a whole subsystem is exactly the failure mode the
tiers doc warns about, so all three are forced off:

```
# CONFIG_FB_RADEON_I2C is not set
# CONFIG_FB_3DFX_I2C is not set
# CONFIG_FB_CYBER2000_DDC is not set
# CONFIG_FB_NVIDIA_I2C is not set
# CONFIG_FB_SAVAGE_I2C is not set
```

(The last two already default to `n`; we write them out so a future
`olddefconfig` on a newer kernel that flips their default can't quietly
re-open the hole, and so `verify-legacy-fbdev-config.sh` has something to
assert against.)

The cost: `radeonfb`, `tdfxfb` and `cyber2000fb` lose DDC/EDID monitor probing
and fall back to their built-in mode tables or an explicit `video=` boot
parameter. That is a worse *default resolution* on three drivers, not a worse
console — and the alternative is i2c-core resident in RAM on the 486 forever.
The trade goes the way the doctrine says it goes.

`FB_I740` and `FB_TRIDENT` `select FB_DDC` directly from a `tristate` at `m`,
which resolves to `FB_DDC=m` → `I2C=m`, `I2C_ALGOBIT=m`. That is Tier 2 and
therefore fine: i2c-core only loads if `i740fb` or `tridentfb` loads.

### Symbols `olddefconfig` will add on its own

Expected, not hand-written — the plan asserts they land this way rather than
pre-writing them:

`CONFIG_VGASTATE=m`, `CONFIG_FB_SVGALIB=m`, `CONFIG_FB_DDC=m`, `CONFIG_I2C=m`
(+ its own defaults), `CONFIG_I2C_ALGOBIT=m`, `CONFIG_FB_TILEBLITTING=y`
(selected by `FB_S3`/`FB_ARK`/`FB_VT8623`/`FB_MATROX`), `CONFIG_FB_BACKLIGHT=m`
and `CONFIG_BACKLIGHT_CLASS_DEVICE=m` (via the `default y`
`FB_{ATY,ATY128,RADEON}_BACKLIGHT` bools — harmless here because `FB_BACKLIGHT`
is itself a `tristate` selected from `tristate=m` parents, so it stays modular
and never reaches Tier 0).

`FB_TILEBLITTING=y` is the only genuine `bzImage` growth in the change: a small
core helper, unavoidable because four drivers `select` it, and measured in the
PR's size delta.

## Exclusions, and why

### Excluded on mechanism — cannot be `=m` at all

| Symbol | Kconfig | Why excluded |
|---|---|---|
| `FB_ASILIANT` | `bool`, `depends on (FB = y)` | Not a tristate. The *only* available value is `y`, i.e. Tier 0, for an Asiliant/Chips 69000 accelerator that no machine needs to boot. Enabling it would violate the Tier-0 bar; there is no `=m` form to fall back to. |
| `FB_IMSTT` | `bool`, `depends on (FB = y)` | Same mechanism. Additionally an IMS Twin Turbo is a card bundled with Macintoshes, not a legacy PC framebuffer. |

These two are the reason the brief's candidate list and the final list differ by
more than taste: they are structurally ineligible for the tier this change
targets. Making them `=y` is available to a future decision that argues the
Tier-0 case on its own merits; this change does not make that argument.

### Excluded on scope — not a legacy PC framebuffer

| Symbol | What it actually is |
|---|---|
| `FB_ARC` | Arc *Monochrome LCD board* — a KS-108 panel wired to an embedded x86 SBC over 16 bits of GPIO, needing a hand-specified IO address. No PCI/ISA ID, no modalias, never shipped in a PC. |
| `FB_N411` | Apollo/Hecuba e-ink devkit (pulls `FB_HECUBA`). Same family as `FB_METRONOME`. |
| `FB_METRONOME` | E-ink controller. |
| `FB_IBM_GXT4500` | IBM GXT4500P/6000P — PowerPC workstation card. |
| `FB_CARMINE`, `FB_MB862XX`, `FB_OPENCORES`, `FB_S1D13XXX` | Embedded SoC / FPGA display controllers. |
| `FB_UDL`, `FB_SMSCUFX` | USB DisplayLink. USB-attached 2010s dongles — neither legacy nor PC-bus framebuffers. Out of scope, not a firmware objection. |
| `FB_VIRTUAL` | `vfb`, a fake framebuffer for testing. Actively harmful on real hardware: it registers an `fb0` backed by nothing. |

### The firmware line — verified, not assumed

`docs/kernel-tiers.md` draws a hard line at drivers that pull a runtime firmware
blob, because an opaque separately-licensed blob breaks the attestation chain.
The doctrine says verify rather than assume, so we did: all 27 driver source
files for the included set were fetched at `v6.12.80` and grepped for
`request_firmware`, `firmware_request`, and `MODULE_FIRMWARE`.

**Result: 0 hits across 27/27 files.** Every driver in this set is
register-level and blob-free. Nothing in the candidate list was excluded on
firmware grounds — the line simply isn't crossed.

That is a point-in-time check on a pinned tree, so the plan converts it into a
standing CI assertion (`modinfo -F firmware` empty for each shipped module)
rather than leaving it as a claim in a document. The existing
`CONFIG_EXTRA_FIRMWARE` covenant check is preserved alongside it.

## Test strategy

The tiers doc already settled the philosophy for a manifest this broad: *CI is
not asked to prove the breadth, it's asked to prove the mechanism.* QEMU cannot
give us a Voodoo3 or an ARK 2000PV, and pretending otherwise would mean piling
on tests that can't mean anything — which the working guide explicitly calls
out as the wrong instinct ("tests aren't free… every boot test must mean
something"). So: three layers, each proving a claim it can actually prove.

**1. Intent check — `scripts/tests/verify-legacy-fbdev-config.sh`** (free, runs
in `pr-validate.yml`, which already loops over `scripts/tests/*.sh`).
Asserts every driver symbol is `=m` in `configs/kernel.config`, `FB_GEODE=y`,
the chip sub-options are `y`, the three DDC traps are off, and — the point of
the check — that a later `olddefconfig` regen did not silently drop any of
them. Modelled directly on `verify-nic-zoo-config.sh`. Re-asserts the
`CONFIG_EXTRA_FIRMWARE` covenant.

**2. Build-time proof — a `build.yml` step, "Assert legacy fbdev kernel modules
built and shipped."** Sibling of the existing NIC assertion: all 27 `.ko` files
exist under `output/sysroot/lib/modules/$KVER$LOCALVERSION`, so the chain
compile → `modules_install` → sysroot → squashfs is proven, not assumed. Plus
`modinfo -F firmware` empty for each, which turns the firmware doctrine into an
enforced gate.

Layer 2 is what catches the failure the brief worries about: a symbol that
`olddefconfig` drops because a dependency isn't met produces no `.ko`, and the
step fails loudly instead of the config quietly regressing on the next
`cp .config configs/kernel.config`.

**3. Runtime proof — one QEMU boot test, `--mode vga --vga-model cirrus`.**
`-vga cirrus` is a real PCI Cirrus GD5446 with a real modalias, and `cirrusfb`
is in our set, so this exercises the whole Tier-2 path end to end: modalias
coldplug matches a *graphics* device and `lsmod` shows `cirrusfb`. Structurally
identical to the existing `--mode nic --nic-model …` matrix, and it reuses
`build_bios_cmd` the same way `build_nic_cmd` does.

One positive coldplug is the right number. The tiers doc's distribution model
applies unchanged: every other driver in the table rides the same mechanism a
`cirrusfb` load proves, and per-card proof "gets proven the way the 486 itself
gets proven — someone boots it on the real hardware and reports back."

### Watch-items for implementation

- **`CONFIG_TRIM_UNUSED_KSYMS=y`.** kbuild's symbol trimming accounts for
  modules as well as built-ins, so in-tree `=m` drivers keep their own
  dependencies alive. Expected to be a non-event, but it is the first suspect
  if a module fails to `modprobe` with `Unknown symbol` — the tiers doc names
  it as a standing checklist item.
- **`vga16fb` and `hgafb` have no PCI/ISA modalias** and will never coldplug.
  They ship as manually-`modprobe`-able drivers — the same shape as the ISA
  `ne` NIC, which `monolith-net probe` handles. An equivalent fbdev probe verb
  is out of scope here; noted as a follow-up.
- **Size delta.** `docs/kernel-tiers.md` requires the PR to record before/after.
  Two numbers: `bzImage` (should move only by `FB_TILEBLITTING`) and the rootfs
  squashfs / ISO (the 27 modules). The initrd must not change at all — if it
  does, something landed in Tier 1 by mistake.
- **Ebuild revbump.** Editing an overlay ebuild in place reuses a stale S3
  binpkg under `--usepkg`. This change edits `configs/kernel.config`, not the
  ebuild, so a revbump `-r6` → `-r7` plus the matching `versions.lock` bump is
  needed to force the kernel to actually rebuild. Confirm against the
  savedconfig-hash purge step in `build.yml` before assuming either way.

## Success condition

A green CI run on the PR in which: `verify-legacy-fbdev-config.sh` passes, the
27 `.ko` files are present in the sysroot with no firmware requirements, the new
`cirrusfb` coldplug boot test passes, and the existing boot matrix is unchanged.
