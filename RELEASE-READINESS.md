# Release Readiness Report

Audit date: 2026-03-05 (original: 2026-02-08)

---

## Package Build Status (2026-03-04)

### Build system fix
`build-packages.sh` was reporting all 54 successfully-built packages as failures. GPKG format
stores binpkgs in `PKGDIR/CATEGORY/PKGNAME/PKGNAME-VERSION.gpkg.tar` — an extra directory vs.
the old XPAK format — and the success check was looking one level too shallow. Fixed.
Individual per-package build logs are now copied to `output/logs/*.build.log` on failure.

### Man pages restored
Removed `noman noinfo nodoc` from `FEATURES` in `make.conf`. Man pages are now installed for
all packages. `app-text/mandoc` postinst (`makewhatis`) will succeed now that there are pages
to index.

### Dropped packages (build failures, not worth fixing now)

| Package | Failure | Replacement |
|---------|---------|-------------|
| `dev-debug/gdb` | Compile fails — native i486+musl GDB cross-compile is a significant undertaking | `dev-debug/strace` |
| `www-client/w3m` | econf fails — dependency/configure issue | `www-client/lynx` |
| `sys-process/dcron` | `emake install` fails — Makefile hardcodes or uid/gid issues in cross env | None currently |

### fortune-mod and nethack — BUILD RESOLVED, nethack runtime known gap

Both packages now build and install correctly. See git log for details.

**Nethack runtime**: "Configuration incompatibility for file 'dungeon'. Dungeon description not valid."

The nethack data files (`nhdat`, `*.lev`) are built by `dlb`, `dgn_comp`, and `lev_comp` — which
our CC_FOR_BUILD bashrc hook compiles as x86_64 binaries so they can run on the build host.
x86_64 uses 64-bit `long` (8 bytes); i486 uses 32-bit `long` (4 bytes). The `dlb_fentry` struct
contains `long foffset` and `long fsize`, so the archive index is misread by the i486 binary →
dungeon data corruption.

**Fix:** In the bashrc CC_FOR_BUILD section, add `-m32` to `CFLAGS_FOR_BUILD` and confirm the
host gcc has 32-bit multilib support (`gcc -m32`). This compiles the build tools as 32-bit x86,
matching the i486 ABI for `long`. Alternatively, patch nethack to use `int32_t`/`int64_t` instead
of `long` in the DLB archive structs.

---

## Project Summary

A Gentoo crossdev-based Docker build system that cross-compiles a Linux live ISO targeting i486 (Pentium-class) hardware. The pipeline goes: Docker image build -> Portage cross-compile -> kernel build -> initramfs -> SquashFS rootfs -> ISOLINUX ISO.

The package set has grown from a minimal BusyBox-based image to a full GNU/Linux userland with editors, development tools, network clients, filesystem utilities, and amusements (~61 world packages). The ISO size will be significantly larger than the original ~23 MB estimate; exact size TBD after the expanded build completes.

**Overall assessment: The core build pipeline is complete and functional.** The gaps are mostly around release polish, not missing functionality.

---

## Open Issues

### Should Fix

### 1. Dynamic linking — performance and correctness gap

Several packages ignore `USE=static` and build as dynamically-linked PIE binaries:
`sys-apps/util-linux` (mount, agetty, mountpoint, etc.), `sys-apps/iproute2` (ip),
`net-misc/dhcpcd`, `sys-process/procps`, `app-arch/tar`, `sys-apps/gawk`, and others.

This matters for two reasons:
- **Performance**: every exec of these binaries requires the dynamic linker to do library
  lookups and relocations. On a 486 booting from CD-ROM, that means extra seeks and page
  faults on every shell command. A fully static userland would be noticeably snappier.
- **Correctness**: the live sysroot installs `lib/ld-musl-i386.so.1` as a symlink to the
  crossdev absolute path (`/usr/i486-linux-musl/usr/lib/libc.so`), which is dangling on
  the live system. `extract-packages.sh` works around this by replacing the symlink with
  the actual binary, but this is a band-aid.

**Fix:** Audit each dynamic binary. Many can be forced static with package-specific
`LDFLAGS=-static` env overrides or USE flags. For packages with no static option
(e.g. util-linux), consider patching the ebuild or replacing with a BusyBox applet
equivalent (BusyBox provides static mount, ip, agetty, etc. and is designed for exactly
this use case).

### 2. Root login with no password
- `/etc/shadow` is created by `build-rootfs.sh`, but root has no password set
- Anyone booting the ISO has passwordless root
- For a live ISO this may be intentional, but should be explicitly documented
- **Fix:** At least add a warning banner on the login console, or a first-boot password prompt. Document the decision either way.

### 2. `rescue` boot label was broken (fixed in `build-iso.sh`)
- The `LABEL rescue` entry in the generated `isolinux.cfg` was not passing `rescue` to the kernel
- The init script parses a `rescue` kernel parameter to drop to a shell — without it, the rescue label just booted silently without `quiet`, not to a rescue shell
- **Fixed:** `APPEND initrd=/boot/initrd.img rescue` now correctly passes the parameter

### 3. README PPP example referenced `pppd`, which is not installed
- The Networking Quick Start section showed `slattach -p ppp /dev/ttyS0` followed by "Then configure pppd as needed"
- `pppd` is not in the world file and is not built into the image; `slattach` provides SLIP line attachment only
- **Fixed:** README example updated to SLIP and notes that pppd is not included

### 4. `toram` kernel parameter is undocumented
- The init script supports `toram`, which copies the SquashFS rootfs entirely into RAM before mounting
- This allows the boot media (CD/USB) to be removed after boot — a significant usability feature for live systems
- **Fix:** Document `toram` in README boot options (now done) and consider adding it as an explicit ISOLINUX label

### 5. mandoc.db stale on first boot

`man` works correctly, but on first boot it will print:
```
man: outdated mandoc.db lacks <pkg>(N) entry, run makewhatis /usr/share/man
```

Root cause: `mandoc.db` is built during `mandoc`'s `pkg_postinst` in the build container,
at which point only mandoc itself is installed. It is also regenerated in `extract-packages.sh`,
but `makewhatis` stores absolute paths — the build path (`/output/sysroot/usr/share/man`)
is not the live path (`/usr/share/man`), so the db is always stale on the live system.

**Workaround:** Run `makewhatis /usr/share/man` once on the live system. The warning can be
suppressed and the db corrected in one command. Pages display correctly regardless of the warning.

**Fix:** Add `makewhatis /usr/share/man` to the rcS startup script (run once, fast, in RAM).

### 6. No clean shutdown sequence
- BusyBox init with a basic `/etc/inittab`
- `rcS` startup script created by `build-rootfs.sh` is minimal (mount filesystems, start mdev, bring up networking)
- No service management, no shutdown scripts, no `rc.K` (kill script)
- **Fix:** Add a shutdown/reboot script that kills processes, syncs filesystems, and unmounts cleanly

### 7. Incomplete `.gitignore`
- `.gitignore` was missing `.claude/` (Claude Code project settings directory)
- **Fixed:** `.claude/` entry added

---

## Nice to Have

### 7. Hardcoded kernel/BusyBox/SYSLINUX versions with no update mechanism
- Kernel 6.12.11, BusyBox 1.36.1 are hardcoded in Dockerfile `ENV` vars
- `update-versions.sh` handles Portage package versions but NOT kernel/BusyBox
- SYSLINUX is installed via `emerge sys-boot/syslinux` with no version pin; the `ENV SYSLINUX_VERSION=6.03` in the Dockerfile is purely informational — it doesn't actually constrain what emerge installs, so it could silently become wrong
- **Fix:** Either document the manual update process or extend `update-versions.sh` to cover these; replace `ENV SYSLINUX_VERSION` with a comment

### 8. No EFI boot support (BIOS only)
- Build creates a stub EFI partition (empty FAT12, for Hyper-V Gen 1 GPT hybrid only)
- No actual EFI bootloader (no GRUB EFI, no systemd-boot, no EFI shell)
- Modern hardware (post-2012) increasingly drops BIOS/CSM support
- **Fix:** Add a minimal GRUB EFI or systemd-boot stub for UEFI machines
- May be intentional given the i486 target audience — worth documenting either way

### 9. No persistence support
- System uses tmpfs overlay over SquashFS — all changes lost on reboot
- No option to save session to USB or partition
- **Fix:** Add a `persist` kernel parameter that looks for a labeled partition to use as the overlay upper dir

### 10. No CI/CD
- No `.github/workflows/`, `.gitlab-ci.yml`, or equivalent
- The build requires Docker and takes significant time, but at minimum a smoke test that the Dockerfile builds would catch regressions
- **Fix:** A GitHub Actions workflow that runs `make build-image` on push

### 11. QEMU test target is minimal
- `make test` just launches QEMU with the ISO — no automated validation
- No check that the system boots successfully, network comes up, or SSH is reachable
- **Fix:** A QEMU + expect/pexpect script that validates boot-to-login

### 12. No CONTRIBUTING or developer onboarding docs
- The README exists and is decent, but there's no:
  - Architecture overview for contributors
  - Troubleshooting guide (cross-compilation is notoriously finicky)
  - Explanation of the weird workarounds (BUILD_DIR unsetting, libtool patching, etc.)

### 13. No kernel module support
- All drivers built-in, no loadable module support
- Fine for current minimal use case, but limits extensibility
- If additional hardware support is ever needed, the kernel must be recompiled

### 14. man-db replaced by mandoc
- `sys-apps/man-db` pulls in `virtual/tmpfiles` → `sys-apps/systemd-utils[tmpfiles]`, which has a hard `REQUIRED_USE` on `PYTHON_SINGLE_TARGET` with no lightweight alternative available in the tree
- Replaced by `app-text/mandoc`, which provides `man`, `apropos`, and `whatis` without the dependency chain
- Man page content (`sys-apps/man-pages`) is still installed

### 15. nmap not included
- `net-analyzer/nmap` has a hard `REQUIRED_USE` constraint requiring a `PYTHON_SINGLE_TARGET` selection even when all Python-dependent features (`-nse -ndiff -zenmap`) are disabled
- Adding Python to the cross-compilation environment is too heavy a dependency for one tool
- **Fix:** Add `dev-lang/python` to world, then add `net-analyzer/nmap PYTHON_SINGLE_TARGET=python3_12 -nse -ndiff -zenmap` to package.use; or wait until nmap upstream decouples its Python dependency

### 15. No native compiler on the live system
- `sys-devel/gcc` was omitted to keep the ISO small (gcc adds 200-400 MB uncompressed)
- Users cannot compile software on the running system
- **Fix:** Add `sys-devel/gcc` to world with C/C++ only (`-ada -d -fortran -go -objc -objc++`), plus `dev-lang/perl` (required by build tooling) and optionally `games-misc/cowsay` (fun, Perl script)
- Consider building a separate "developer" ISO variant with gcc included

### 17. No graphical environment
- Minimal X stack: xorg-server (fbdev driver) + dwm + st + dmenu + terminus-font + xinit
- Piggybacks on the existing boot-time framebuffer — no GPU driver or udev needed
- xf86-video-fbdev talks directly to /dev/fb0; xf86-input-evdev handles keyboard/mouse
- dwm is ~2000 lines of C; configured by editing source and recompiling
- May require an /etc/X11/xorg.conf.d/10-evdev.conf snippet in build-rootfs.sh
  to declare input devices explicitly (xorg-server without udev can't auto-detect them)

---

## Issues That Looked Weird But Are Actually Fine

- **Portage sandbox disabled** — intentional, required for cross-compilation
- **`ACCEPT_KEYWORDS="*"`** — correct for embedded profile without arch parent chain
- **`BUILD_DIR` unset before emerge** — documented workaround for multilib-minimal.eclass
- **Bash-specific syntax in scripts** — all scripts have `#!/bin/bash` shebang
- **Large Docker image (~1.5-2 GB)** — unavoidable with Gentoo stage3 + crossdev toolchain
- **No kernel modules** — intentional, everything built-in for simplicity
- **Libtool bashrc patching** — necessary workaround for static linking, properly implemented
- **initrd uses XZ, rootfs SquashFS uses gzip** — intentional asymmetry: the initrd is small and xz decompresses once at boot; the SquashFS is decompressed continuously at runtime so gzip is faster and less memory-intensive on i486 hardware
- **SquashFS uses gzip, not xz** — kernel has `CONFIG_SQUASHFS_XZ=y` but mksquashfs uses `-comp gzip` explicitly; xz would save ~30% space but gzip is faster to decompress on memory-constrained i486 machines; this is a deliberate trade-off

---

## Resolved Issues (from original 2026-02-08 audit)

### R1. Missing LICENSE file — RESOLVED
- Original finding: no LICENSE file; README incorrectly said "Public domain"
- **Fixed:** MIT License added; README updated to say "MIT License"

### R2. USB boot media detection was limited — RESOLVED
- Original finding: `rootfs/init` only scanned CD-ROM devices and disk-by-label paths; no scanning of `/dev/sd*` or `/dev/vd*`
- **Fixed:** init now falls back to iterating `/sys/block/*`, trying every block device and its partitions

### R3. No SSH host key generation — RESOLVED
- Original finding: Dropbear installed but no host key generation; dropbear would fail to start
- **Fixed:** `build-rootfs.sh` creates `/etc/init.d/S20keygen` which generates RSA and ECDSA host keys on first boot if missing

---

## Priority Summary

| Priority | # | Item | Effort |
|----------|---|------|--------|
| Should-fix | 1 | Dynamic linking — static rebuild or BusyBox replacement | 4-8 hr |
| Should-fix | 1b | Nethack dungeon ABI mismatch — `-m32` for CC_FOR_BUILD | 1 hr |
| Should-fix | 2 | Document/handle root password | 15 min |
| Should-fix | 2 | rescue label bug | fixed |
| Should-fix | 3 | README PPP example | fixed |
| Should-fix | 4 | Document toram | fixed |
| Should-fix | 5 | mandoc.db stale on first boot — add makewhatis to rcS | 5 min |
| Should-fix | 6 | Clean shutdown sequence | 30 min |
| Should-fix | 7 | .gitignore cleanup | fixed |
| Nice-to-have | 7 | Version update docs/tooling + SYSLINUX_VERSION | 1 hr |
| Nice-to-have | 8 | EFI boot support | 2-4 hr |
| Nice-to-have | 9 | Persistence support | 2-3 hr |
| Nice-to-have | 10 | CI/CD pipeline | 1-2 hr |
| Nice-to-have | 11 | Automated boot testing | 2-3 hr |
| Nice-to-have | 12 | Developer docs | 1-2 hr |
| Nice-to-have | 13 | Kernel module support | 1+ hr |
| Nice-to-have | 14 | man-db (replaced by mandoc; man-db needs Python via tmpfiles) | 1-2 hr |
| Nice-to-have | 15 | nmap (needs Python dep) | 1-2 hr |
| Nice-to-have | 16 | Native compiler (gcc + perl + cowsay) | 2-4 hr |
| Nice-to-have | 17 | Graphical environment (dwm over fbdev) | 2-4 hr |
