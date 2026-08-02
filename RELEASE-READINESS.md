# Release Readiness Report

Audit date: 2026-08-02 (previous: 2026-03-05, original: 2026-02-08)

This pass re-verified every item from the 2026-03-05 audit against the current
tree (not against memory of past audits), closed out an engineering cleanup
batch (nethack ABI verification, mandoc.db, clean shutdown, root password
banner, static-linking audit tooling, persistence, version-pin honesty), and
found one new gap while doing so (dropbear is never actually started — see
Open Issues). Items are only listed as resolved where the current code was
directly inspected; nothing here is carried forward from the previous report
without re-checking.

---

## Project Summary

A Gentoo crossdev-based Docker build system that cross-compiles a Linux live
ISO targeting i486 (Pentium-class) hardware. The pipeline goes: Docker image
build -> Portage cross-compile -> kernel build -> initramfs -> SquashFS
rootfs -> ISO (ISOLINUX BIOS + GRUB EFI, hybrid CD/USB).

The package set is a full GNU/Linux userland — editors, development tools,
network clients, filesystem utilities, and amusements (~65 world packages) —
built musl-libc, i486, and as close to fully statically linked as upstream
ebuilds allow.

**Overall assessment: the core build pipeline, boot chain (BIOS + UEFI), and
CI are complete and functional.** Remaining gaps are release polish (a few
small runtime rough edges) and nice-to-haves (persistence boot-testing,
developer docs, optional bigger variants).

---

## Resolved Issues

Dated entries below reflect when this audit pass verified/fixed the item, not
necessarily when the underlying code first landed (git history is the source
of truth for that).

### Nethack dungeon ABI mismatch — RESOLVED (verified 2026-08-02)
- Original finding: `dlb`/`dgn_comp`/`lev_comp` build-host tools compiled as
  x86_64 (64-bit `long`) but are read by i486 nethack (32-bit `long`),
  corrupting the DLB archive index (`nhdat`).
- The fix (`CFLAGS_FOR_BUILD="-O2 -m32"` in `configs/portage/make.conf`,
  consumed by the `CC_FOR_BUILD` hook in `configs/portage/bashrc`, which also
  forces `LFLAGS`/`LDFLAGS` to `-m32` for `makedefs`/`lev_comp`/`dgn_comp`/
  `dlb`) was already present in the tree (git commit `bfb3a1d`) — this audit
  verified it's wired correctly end to end.
- **Added 2026-08-02:** the Dockerfile now fails the image build early with a
  clear error if the host `gcc` lacks `-m32` multilib support, instead of
  letting a missing prerequisite surface later as silent dungeon-data
  corruption.
- **Still deferred:** confirming nethack actually launches with a valid
  dungeon on real i486 hardware/QEMU is a boot-time check — defers to the T5
  CI boot harness. This audit could only verify the build-time toolchain
  configuration (no Docker/QEMU available in this environment).

### mandoc.db stale on first boot — RESOLVED (2026-08-02)
- `man` worked, but printed `outdated mandoc.db ... run makewhatis
  /usr/share/man` on first boot, because `makewhatis` bakes in the
  build-container path, not the live `/usr/share/man` path.
- **Fixed:** `scripts/build-rootfs.sh`'s generated `rcS` now runs
  `makewhatis /usr/share/man` once at startup (sub-second — rootfs is a tmpfs
  overlay in RAM and there are only a few dozen man pages).

### Clean shutdown sequence — RESOLVED (2026-08-02)
- `rcK` (kill script: `killall5 -15`/`-9`, `umount -a -r`, `sync`) and its
  wiring into `/etc/inittab` (`ca:12345:ctrlaltdel:/sbin/reboot`,
  `l0:0:wait:/etc/init.d/rcK`) already existed in the tree — this was more
  complete than the previous audit's "no rc.K, no shutdown scripts" implied.
- **Gap found and fixed:** `/etc/inittab` only ran `rcK` for runlevel 0
  (halt/poweroff). Runlevel 6 (`reboot`) had no matching entry, so a plain
  `reboot` skipped the kill script entirely — processes weren't signalled and
  filesystems weren't synced/unmounted before the kernel reboot syscall.
  Added `l6:6:wait:/etc/init.d/rcK` to close this.

### Root password policy — RESOLVED (2026-08-02)
- Root has always been intentionally passwordless (fine for a live ISO), but
  it was never stated anywhere a user would see it before logging in.
- **Fixed:** `/etc/issue` (shown before the login prompt on every console) now
  explicitly states root has no password and tells the user how to set one.
- **Still open (by design):** the longer-form security note belongs in
  `README.md`, which this batch intentionally did not touch (another agent
  owns README changes in this round). Suggested text for that agent to fold
  in, e.g. under a "Security" heading:

  > **Root has no password by default.** This is intentional — it's a live/
  > rescue ISO, and requiring a password before you can even get a shell
  > would defeat the point. `/etc/issue` states this on every console before
  > login. If you expose this system (network services, a shared machine),
  > run `passwd` first, or expect anyone on the wire/console to have root.

### Static-linking audit — PARTIALLY RESOLVED (2026-08-02), see Open Issues
- Verified `configs/portage/env/static.conf` (`-static -no-pie`,
  `--disable-shared`) and `configs/portage/package.use/static` (`*/* static
  static-libs` plus ~50 explicit per-package overrides, including the
  specific packages the previous audit called out: util-linux, iproute2,
  dhcpcd, procps, tar, gawk) are both already comprehensive — this is much
  further along than the previous audit's framing suggested.
- **Added:** `scripts/static-audit.sh` — walks a built rootfs/sysroot with
  `file`, reports every dynamically-linked ELF to
  `output/reports/static-audit.txt`, wired into `build-rootfs.sh` to run
  automatically after `create_squashfs` (report-only, writes outside
  `ROOTFS_DIR`, so it cannot perturb the SquashFS bytes or the attestation
  digest chain). Supports `--strict` for CI gating once the known-offender
  list below is empty.
- **Known remaining gap:** `sys-apps/util-linux`'s client utilities (`mount`,
  `agetty`, `mountpoint`) have no `static` USE flag upstream — the
  `static -nls -udev` line in `package.use/static` is honored for the parts
  of util-linux that support it, but silently ignored for the rest. BusyBox
  already provides static `mount`/`mountpoint` as substitutes; there is no
  BusyBox `agetty` substitute currently wired in (`CONFIG_GETTY is not set`
  in the BusyBox savedconfig) — `/etc/inittab` still spawns util-linux's
  `agetty`. Not fixed in this pass — this environment cannot build the
  sysroot to verify a substitution end to end, and it's exactly the kind of
  change that needs a real boot test. Left for a future batch with build
  access, verified via `scripts/static-audit.sh`.
- **`ld-musl-i386.so.1` symlink→binary copy in `extract-packages.sh`:
  evaluated, kept.** As long as util-linux's client utilities remain
  dynamically linked, a working dynamic linker must exist on the live
  system, or those binaries fail to exec at all. Removing this is deferred
  to CI: run `static-audit.sh --strict` against a real build; only remove
  once it comes back clean.

### Persistence support — RESOLVED (2026-08-02), boot-test pending
- Added a `persist` kernel parameter. `rootfs/init` now coldplug-scans block
  devices with BusyBox `mdev -s` (populates `/dev/disk/by-label/*` via
  BusyBox's built-in volume-ID probing — already compiled in via
  `CONFIG_VOLUMEID=y` in the savedconfig, just never invoked before), looks
  for a partition labeled `MONOLITH_PERSIST`, and if found mounts it as the
  overlayfs upper/work storage instead of tmpfs. Falls back to tmpfs (with a
  clear warning) if `persist` is requested but no such partition exists, or
  if mounting it fails.
- Added `LABEL persist` to the ISOLINUX config and a matching GRUB
  `menuentry` in `scripts/build-iso.sh`.
- Create the partition with: `mkfs.ext4 -L MONOLITH_PERSIST /dev/sdXN`
- **Known limitation, documented in code:** the initramfs only has BusyBox,
  which provides `fsck.minix` but no ext4/vfat fsck. A full fsck before
  mount is best-effort (attempted only if an `fsck` applet happens to be on
  PATH); an ext4 journal replay on mount covers ordinary unclean-shutdown
  recovery. A real fsck could be added later by shipping a static
  `fsck.ext4` binary in the initramfs, at the cost of initrd size.
- **Boot-test variant needed:** this audit could not build or boot-test the
  round trip (write a file with `persist`, reboot, confirm it's still
  there). Coordinate with whoever owns the T5 CI boot harness to add a
  persistence boot-test variant (boot with `persist` + a pre-labeled
  scratch disk, write a marker file, reboot, verify the marker survives).

### Version pinning honesty — RESOLVED (2026-08-02)
- Kernel (`sys-kernel/monolith-kernel`) and BusyBox (`sys-apps/busybox`) were
  already fully covered by `configs/portage/versions.lock` /
  `scripts/update-versions.sh` — both are ordinary entries in
  `configs/portage/world`, so `make update-versions` already tracks them
  like every other world package. The previous audit's claim that these were
  "hardcoded in Dockerfile ENV vars" no longer matches the tree (no such ENV
  vars exist in the current Dockerfile) — corrected.
- SYSLINUX: confirmed the informational `ENV SYSLINUX_VERSION=6.03` no longer
  exists in the Dockerfile either, but nothing had replaced it with an
  explanation. **Fixed:** added a comment block above the host-tools
  `emerge` line in the Dockerfile explaining that syslinux/grub/mtools/etc.
  are intentionally pinned only indirectly, via `BUILD_EPOCH` (the portage
  snapshot date) — not a per-package version atom — and why that's the
  correct model for host-only build tools that never enter the target
  sysroot. `scripts/update-versions.sh`'s header comment now states this
  scope boundary explicitly too.

### Package build system — RESOLVED (2026-03-04, re-verified 2026-08-02)
- `build-packages.sh`'s GPKG success-check depth bug, `noman noinfo nodoc`
  removal (man pages now install for every package), and the `dlb`/nethack
  build (as opposed to runtime) failures were fixed in the 2026-03-04 pass
  and remain fixed.
- **Dropped packages** (confirmed still absent from `configs/portage/world`,
  decision still stands): `dev-debug/gdb` (replaced by `dev-debug/strace`),
  `www-client/w3m` (replaced by `www-client/lynx`), `sys-process/dcron` (no
  replacement).

### rescue label, README PPP example, toram documentation, .gitignore — RESOLVED (2026-03-05, re-verified 2026-08-02)
- All four fixes from the previous audit were re-checked against the current
  tree and remain correct: `LABEL rescue` passes `rescue` on the kernel
  command line; the README's networking quick-start uses `slattach` and
  notes `pppd` isn't installed; `toram` is documented in the README boot
  options table; `.claude/` is in `.gitignore`.

### EFI boot support — RESOLVED (previously; re-verified 2026-08-02)
- GRUB EFI (32-bit and 64-bit) via `grub-mkstandalone`, the El Torito
  sector-count overflow fix, GPT ESP type-GUID patch, and FAT16-not-FAT32
  ESP image are all present and unchanged in `scripts/build-iso.sh`.
  `make test-uefi` exists in the Makefile for local QEMU+OVMF verification.

### CI/CD pipeline — RESOLVED (previously; re-verified 2026-08-02)
- `.github/workflows/build.yml` exists and runs the build. (The previous
  audit listed this as entirely missing — that's no longer accurate; exact
  date it was added isn't tracked here, but it is present and current.)

---

## Open Issues

### Should Fix

#### 1. Dynamic linking gap: util-linux client utilities (agetty, mount, mountpoint)
See "Static-linking audit" above under Resolved for the full analysis —
listed here too because it's the one concrete remaining action item.
`scripts/static-audit.sh` now exists to verify this on a real build; the fix
itself (patch the ebuild, or wire in a BusyBox/alternate `agetty`) needs
build access this environment doesn't have.

#### 2. dropbear SSH daemon is installed but never started (newly found, 2026-08-02)
- `net-misc/dropbear` is in `configs/portage/world`, and `S20keygen`
  generates its ECDSA host key on first boot — but no init script actually
  starts the `dropbear` daemon itself. Grepped the full `scripts/` and
  `rootfs/` trees to confirm: `dropbear` (the daemon binary) is invoked
  nowhere except `dropbearkey` in `S20keygen`.
- Practical effect: SSH is currently unreachable on this image regardless of
  the passwordless-root banner added this pass — there's no listening
  service to reach. Not a security regression (arguably safer as shipped),
  but almost certainly not the intent given the host-key generation script
  and the `net-misc/dropbear` dependency exist.
- **Fix:** add an `/etc/init.d/S6xdropbear` (after `S40network`) that starts
  `dropbear` (likely `dropbear -R` since keys are pre-generated by
  `S20keygen`, or drop `-R` and rely on the existing keygen step).

### Nice to Have

#### 3. QEMU test target has no automated pass/fail check
- `make test` / `make test-uefi` boot the ISO in QEMU but don't validate
  boot-to-login automatically.
- **Fix:** a QEMU + expect/pexpect (or similar) script that validates the
  boot sequence reaches a login prompt. This is presumably the scope of the
  "T5 boot harness" referenced elsewhere in this project's task tracking;
  if so, the persistence and nethack boot-test items above should be folded
  into that harness rather than built separately.

#### 4. No CONTRIBUTING or developer onboarding docs
- No architecture overview for contributors, no troubleshooting guide for
  cross-compilation's rough edges, no explanation of the accumulated
  workarounds (`BUILD_DIR` unsetting, libtool patching, the CC_FOR_BUILD
  nethack hook, etc.) collected in `configs/portage/bashrc`.

#### 5. Kernel module support is compiled in but unused
- Correction to the previous audit: `configs/kernel.config` does have
  `CONFIG_MODULES=y` set — the kernel itself can load modules. However,
  `sys-kernel/monolith-kernel`'s ebuild doesn't run `make modules` /
  `modules_install`, so no `.ko` files are ever built or shipped, and
  nothing in the initrd/rootfs would install them if they existed. In
  practice this is still "no module support" — just a smaller gap to close
  (wire up module build/install) than "recompile the kernel with
  `CONFIG_MODULES=y` first."

#### 6. man-db replaced by mandoc — unchanged, confirmed still correct
- `sys-apps/man-db` pulls in `virtual/tmpfiles` → `systemd-utils[tmpfiles]`
  with a hard Python `REQUIRED_USE`; `app-text/mandoc` avoids this while
  still providing `man`/`apropos`/`whatis`. Still the right call.

#### 7. nmap not included
- `net-analyzer/nmap`'s `REQUIRED_USE` still forces a `PYTHON_SINGLE_TARGET`
  selection even with `-nse -ndiff -zenmap`. Unchanged from previous audit.

#### 8. No native compiler on the live system
- `sys-devel/gcc` still intentionally omitted (200-400 MB uncompressed).
  Unchanged from previous audit; a "developer" ISO variant remains a
  reasonable follow-up.

#### 9. No graphical environment
- Unchanged from previous audit (minimal fbdev + dwm + st + dmenu stack was
  scoped but not built).

#### 10. `toram` has no explicit ISOLINUX label
- GRUB already has a `toram` menuentry (`scripts/build-iso.sh`); ISOLINUX
  does not have a matching `LABEL toram` (it's reachable via manual kernel
  append at the ISOLINUX prompt, just not a menu entry). Small, low-risk
  follow-up — noticed while adding the `persist` label in this pass but out
  of scope for this batch.

#### 11. package.use/static references packages no longer in world
- `mail-client/mutt`, `net-irc/irssi`, and `www-client/w3m` all have USE
  overrides in `configs/portage/package.use/static` but are not in
  `configs/portage/world` (confirmed via grep). Harmless (Portage ignores
  USE settings for packages it isn't building) but worth a cleanup pass —
  either re-add them to world if they were meant to ship, or delete the
  dead entries.

---

## Issues That Looked Weird But Are Actually Fine

- **Portage sandbox disabled** — intentional, required for cross-compilation
- **`ACCEPT_KEYWORDS="*"`** — correct for embedded profile without arch parent chain
- **`BUILD_DIR` unset before emerge** — documented workaround for multilib-minimal.eclass
- **Bash-specific syntax in scripts** — all scripts have `#!/bin/bash` shebang
  (`rootfs/init` is the one script that must stay POSIX `/bin/sh` — it runs
  under BusyBox ash in the initramfs before bash exists; verified it still
  has no bashisms after this pass's edits)
- **Large Docker image (~1.5-2 GB)** — unavoidable with Gentoo stage3 + crossdev toolchain
- **initrd uses XZ, rootfs SquashFS uses gzip** — intentional asymmetry: the initrd is small and xz decompresses once at boot; the SquashFS is decompressed continuously at runtime so gzip is faster and less memory-intensive on i486 hardware
- **SquashFS uses gzip, not xz** — kernel has `CONFIG_SQUASHFS_XZ=y` but mksquashfs uses `-comp gzip` explicitly; xz would save ~30% space but gzip is faster to decompress on memory-constrained i486 machines; this is a deliberate trade-off
- **`scripts/static-audit.sh` runs unconditionally in `build-rootfs.sh`, but never fails the build** — by design; it's a verification/reporting step, not a gate, and gating on it would require actually fixing the util-linux gap first (see Open Issues #1)

---

## Priority Summary

| Priority | Item | Status |
|----------|------|--------|
| Should-fix | Dynamic linking (util-linux client utils) | Open — needs build access |
| Should-fix | dropbear never started | Open — newly found 2026-08-02 |
| Nice-to-have | Automated QEMU boot validation (T5 harness) | Open |
| Nice-to-have | CONTRIBUTING / developer docs | Open |
| Nice-to-have | Kernel module build/install wiring | Open |
| Nice-to-have | nmap (Python dep) | Open |
| Nice-to-have | Native compiler variant | Open |
| Nice-to-have | Graphical environment | Open |
| Nice-to-have | `toram` ISOLINUX label | Open |
| Nice-to-have | Dead package.use entries (mutt/irssi/w3m) | Open |
| Resolved | Nethack ABI (`-m32`) + Dockerfile multilib check | 2026-08-02 |
| Resolved | mandoc.db stale on boot | 2026-08-02 |
| Resolved | Clean shutdown (runlevel 6 gap) | 2026-08-02 |
| Resolved | Root password banner | 2026-08-02 |
| Resolved | Static-audit tooling (partial — see Open #1) | 2026-08-02 |
| Resolved | Persistence (`persist` param) | 2026-08-02, boot-test pending |
| Resolved | Version-pin honesty (SYSLINUX comment, kernel/BusyBox already covered) | 2026-08-02 |
| Resolved | Package build system (GPKG depth, man pages) | 2026-03-04 |
| Resolved | rescue label / README PPP / toram docs / .gitignore | 2026-03-05 |
| Resolved | EFI boot support | previously, re-verified 2026-08-02 |
| Resolved | CI/CD pipeline | previously, re-verified 2026-08-02 |
| Resolved | LICENSE file, USB boot detection, SSH host keygen | original audit |
