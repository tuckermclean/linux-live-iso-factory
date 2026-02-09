# Release Readiness Report

Audit date: 2026-02-08

## Project Summary

A Gentoo crossdev-based Docker build system that cross-compiles a minimal Linux live ISO targeting i486 (Pentium-class) hardware. The pipeline goes: Docker image build -> Portage cross-compile -> kernel/BusyBox build -> initramfs -> SquashFS rootfs -> ISOLINUX ISO. The final ISO is ~23 MB.

**Overall assessment: The core build pipeline is complete and functional.** The gaps are mostly around release polish, not missing functionality.

---

## Must Fix

### 1. Missing LICENSE file
- README says "Public domain" but there's no `LICENSE` or `UNLICENSE` file
- Anyone evaluating the repo can't confidently determine the license
- **Fix:** Add an `UNLICENSE` file (or `LICENSE` with CC0/MIT/etc.)

### 2. USB boot media detection is limited
- `rootfs/init` only scans CD-ROM devices: `/dev/sr0`, `/dev/sr1`, `/dev/cdrom`, `/dev/hdc`, `/dev/hdd`
- Also checks `/dev/disk/by-label/MINLINUX` and `LIVECD`
- No scanning of `/dev/sd*` or `/dev/vd*` for USB stick boot
- The ISO is hybrid (USB-bootable via isohybrid), but the init script won't find the rootfs on USB
- **Fix:** Add USB device scanning to init (`/dev/sda*`, `/dev/sdb*`, etc.) or scan all block devices

### 3. No SSH host key generation
- Dropbear is installed but no host keys are pre-generated or generated on first boot
- Dropbear will fail to start without host keys
- **Fix:** Add host key generation to the init/startup scripts (`dropbearkey -t rsa -f /etc/dropbear/dropbear_rsa_host_key`)

---

## Should Fix

### 4. SquashFS uses gzip, not xz
- `build-rootfs.sh` uses default mksquashfs compression (gzip)
- Kernel has `CONFIG_SQUASHFS_XZ=y` enabled
- XZ would save ~30-40% on the 18 MB rootfs
- **Fix:** Add `-comp xz` to the mksquashfs command (or document the gzip choice if intentional for speed on i486)

### 5. No clean shutdown sequence
- BusyBox init with a basic `/etc/inittab`
- `rcS` startup script created by `build-rootfs.sh` is minimal (mount filesystems, start mdev, bring up networking)
- No service management, no shutdown scripts, no `rc.K` (kill script)
- **Fix:** Add a shutdown/reboot script that kills processes, syncs filesystems, and unmounts cleanly

### 6. Root login with no password
- `/etc/passwd` sets root with no password
- `/etc/shadow` not created
- Anyone booting the ISO has passwordless root
- For a live ISO this may be intentional, but should be explicitly documented
- **Fix:** At least add a warning banner on the login console, or a first-boot password prompt. Document the decision either way.

### 7. Incomplete .gitignore
- Current `.gitignore` covers `output/` and `build/` but misses `.claude/` (Claude Code project settings)
- **Fix:** Add `.claude/` entry

---

## Nice to Have

### 8. Hardcoded versions with no update mechanism
- Kernel 6.12.11, BusyBox 1.36.1, SYSLINUX 6.03 are hardcoded in Dockerfile ENV vars
- `update-versions.sh` handles Portage package versions but NOT kernel/BusyBox/SYSLINUX
- **Fix:** Either document the manual update process or extend `update-versions.sh` to cover these

### 9. No EFI boot support (BIOS only)
- Build creates a stub EFI partition (empty FAT12, for Hyper-V Gen 1 GPT hybrid only)
- No actual EFI bootloader (no GRUB EFI, no systemd-boot, no EFI shell)
- Modern hardware (post-2012) increasingly drops BIOS/CSM support
- **Fix:** Add a minimal GRUB EFI or systemd-boot stub for UEFI machines
- May be intentional given the i486 target audience — worth documenting either way

### 10. No persistence support
- System uses tmpfs overlay over SquashFS — all changes lost on reboot
- No option to save session to USB or partition
- **Fix:** Add a `persist` kernel parameter that looks for a labeled partition to use as the overlay upper dir

### 11. No CI/CD
- No `.github/workflows/`, `.gitlab-ci.yml`, or equivalent
- The build requires Docker and takes significant time, but at minimum a smoke test that the Dockerfile builds would catch regressions
- **Fix:** A GitHub Actions workflow that runs `make build-image` on push

### 12. QEMU test target is minimal
- `make test` just launches QEMU with the ISO — no automated validation
- No check that the system boots successfully, network comes up, or SSH is reachable
- **Fix:** A QEMU + expect/pexpect script that validates boot-to-login

### 13. No CONTRIBUTING or developer onboarding docs
- The README exists and is decent, but there's no:
  - Architecture overview for contributors
  - Troubleshooting guide (cross-compilation is notoriously finicky)
  - Explanation of the weird workarounds (BUILD_DIR unsetting, libtool patching, etc.)

### 14. No kernel module support
- All drivers built-in, no loadable module support
- Fine for current minimal use case, but limits extensibility
- If additional hardware support is ever needed, the kernel must be recompiled

---

## Issues That Looked Weird But Are Actually Fine

- **Portage sandbox disabled** — intentional, required for cross-compilation
- **`ACCEPT_KEYWORDS="*"`** — correct for embedded profile without arch parent chain
- **`BUILD_DIR` unset before emerge** — documented workaround for multilib-minimal.eclass
- **Bash-specific syntax in scripts** — all scripts have `#!/bin/bash` shebang
- **Large Docker image (~1.5-2 GB)** — unavoidable with Gentoo stage3 + crossdev toolchain
- **No kernel modules** — intentional, everything built-in for simplicity
- **Libtool bashrc patching** — necessary workaround for static linking, properly implemented

---

## Priority Summary

| Priority | # | Item | Effort |
|----------|---|------|--------|
| Must-fix | 1 | LICENSE file | 5 min |
| Must-fix | 2 | USB boot detection in init | 30 min |
| Must-fix | 3 | Dropbear host key generation | 15 min |
| Should-fix | 4 | SquashFS xz compression | 5 min |
| Should-fix | 5 | Clean shutdown sequence | 30 min |
| Should-fix | 6 | Document/handle root password | 15 min |
| Should-fix | 7 | .gitignore cleanup | 5 min |
| Nice-to-have | 8 | Version update docs/tooling | 1 hr |
| Nice-to-have | 9 | EFI boot support | 2-4 hr |
| Nice-to-have | 10 | Persistence support | 2-3 hr |
| Nice-to-have | 11 | CI/CD pipeline | 1-2 hr |
| Nice-to-have | 12 | Automated boot testing | 2-3 hr |
| Nice-to-have | 13 | Developer docs | 1-2 hr |
| Nice-to-have | 14 | Kernel module support | 1+ hr |
