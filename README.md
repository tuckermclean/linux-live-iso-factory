# The Monolith

> One live ISO that boots on everything from a bare-metal 486 to a modern UEFI machine — a full GNU/Linux userland, cross-compiled from source against musl libc, with a cryptographically attested supply chain end to end.

[![Build](https://github.com/tuckermclean/linux-live-iso-factory/actions/workflows/build.yml/badge.svg)](https://github.com/tuckermclean/linux-live-iso-factory/actions/workflows/build.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Dashboard](https://img.shields.io/badge/dashboard-live-4af626)](https://themonolith.s3.amazonaws.com/)

**Dashboard (build history, SBOMs, CVE status):** https://themonolith.s3.amazonaws.com/
**Repo:** https://github.com/tuckermclean/linux-live-iso-factory

No tagged GitHub Release exists yet — nightly/on-push builds are published to the S3 bucket above (`themonolith.iso` = latest, `themonolith-<tag>.iso` = pinned per build) and are what's referenced throughout this README.

---

## Try it in your browser

The dashboard's **Boot** view runs a full i486 boot — kernel, initrd, SquashFS rootfs, login prompt — inside an x86 WebAssembly emulator ([v86](https://github.com/copy/v86)) in your tab. No plugins, no install, no server:

**https://themonolith.s3.amazonaws.com/#/boot**

The ISO (~131 MB as of the latest published build) is streamed on demand via HTTP range requests, so only the sectors the boot sequence actually touches get downloaded. Expect 1–3 minutes to a login prompt depending on your connection. A standalone version of the same demo lives in this repo at [`boot.html`](boot.html) if you'd rather open it locally.

---

## Verify a release

Every build that completes the attestation pipeline is signed with [GitHub Artifact Attestations](https://docs.github.com/en/actions/security-guides/using-artifact-attestations-to-establish-provenance-for-builds) (SLSA v1.0 provenance via Sigstore). Once you've downloaded an ISO:

```bash
# 1. Verify the SLSA provenance attestation against this repo
gh attestation verify themonolith-<tag>.iso --owner tuckermclean

# 2. Cross-check the file you have against the attested digest
sha256sum themonolith-<tag>.iso
```

The `sha256sum` output must equal the digest inside the attestation, which is the same digest recorded as `metadata.component.hashes[0]` in that build's enriched SBOM (`bom.cdx.json`, per the current `scripts/attestation.sh`) — SBOM, SLSA subject, and ISO checksum are all the same value, so any one of them cross-checks the other two.

**Worked example** (build `20260406-1149887`, verified 2026-08-02):

```bash
$ gh attestation verify themonolith-20260406-1149887.iso --owner tuckermclean
# ...
✓ Verification succeeded

$ sha256sum themonolith-20260406-1149887.iso
0123a68dfe5e49ad3d262cc1adf702b6e30cec88bfd9a5436e400a63c0bdf376  themonolith-20260406-1149887.iso
```

Attestation artifacts for every build are public at `https://themonolith.s3.amazonaws.com/attestation/<build-tag>/`:

| File | Contents |
|---|---|
| `sbom.cdx.json` | Raw Syft CycloneDX SBOM |
| `bom.cdx.json` | SBOM with CPE overrides, license data, and the ISO's own SHA-256 as a top-level component hash |
| `license-report.json` | Per-package license policy check |
| `cve-report.cdx.json` | Grype CVE findings (CycloneDX VEX) |
| `unowned-report.json` | Files on disk not owned by any Portage package |
| `slsa-provenance.json` | SLSA v1.0 in-toto provenance statement |
| `attestation-summary.json` | Machine-readable pass/fail for all pillars |

(Filenames per the current `scripts/attestation.sh`. Older published builds — including the worked example below — used a prior naming scheme, e.g. `sbom-enriched.cdx.json` / `cve-report.json`; check the specific build's directory listing if in doubt.)

---

## What's inside

### Package set

The [world file](configs/portage/world) lists 71 top-level Gentoo packages, cross-compiled for `i486-linux-musl` and installed as `.gpkg.tar` binary packages. Pulling in their dependencies, the most recent published build attests **102 packages** total (see the [dashboard](https://themonolith.s3.amazonaws.com/) for the live count — it changes as packages are added/removed).

<details>
<summary>Full package list (from <code>configs/portage/world</code>)</summary>

| Category | Packages |
|---|---|
| Kernel / init | `sys-kernel/monolith-kernel`, `sys-apps/sysvinit` |
| Initrd | `sys-apps/busybox` (savedconfig, static, initrd only) |
| Shells | `app-shells/bash`, `app-shells/dash`, `app-shells/zsh`, `app-shells/bash-completion` |
| Core GNU userland | `sys-apps/coreutils`, `sys-apps/util-linux`, `sys-apps/findutils`, `sys-apps/grep`, `sys-apps/sed`, `sys-apps/gawk`, `sys-apps/diffutils`, `app-arch/tar`, `app-text/tree` |
| Core libraries | `sys-libs/readline`, `sys-libs/ncurses`, `sys-libs/zlib`, `dev-libs/libpcre2`, `dev-libs/openssl` |
| File utilities | `sys-apps/file`, `sys-apps/less` |
| Editors | `app-editors/vim`, `app-editors/nano` |
| Man pages | `sys-apps/man-pages`, `app-text/mandoc` |
| Dev tools | `sys-devel/binutils`, `dev-build/make`, `dev-debug/strace`, `sys-devel/patch` |
| Scripting | `dev-lang/lua` |
| Compression | `app-arch/xz-utils`, `app-arch/bzip2`, `app-arch/gzip`, `app-arch/zip`, `app-arch/unzip` |
| Networking (config) | `sys-apps/iproute2`, `sys-apps/net-tools`, `net-misc/iputils`, `net-misc/dhcpcd` |
| Remote access | `net-misc/dropbear` |
| Network clients | `net-misc/curl`, `net-misc/wget`, `net-misc/whois`, `net-analyzer/netcat`, `net-analyzer/traceroute`, `www-client/lynx` |
| Network analysis | `net-misc/socat`, `net-analyzer/iftop`, `net-analyzer/tcpdump` |
| Terminal / users | `app-misc/tmux`, `sys-apps/shadow` |
| System utilities | `sys-process/procps`, `sys-process/htop`, `sys-process/lsof`, `app-admin/sysklogd` |
| Filesystem tools | `sys-fs/e2fsprogs`, `sys-fs/dosfstools`, `sys-fs/squashfs-tools` |
| File search / sync | `net-misc/rsync`, `sys-apps/the_silver_searcher` |
| Hardware info | `sys-apps/smartmontools`, `sys-apps/hdparm`, `sys-apps/dmidecode` |
| Mouse support | `sys-libs/gpm` |
| Amusements | `games-misc/bsd-games`, `app-misc/figlet`, `app-misc/cmatrix`, `app-misc/sl`, `games-roguelike/nethack` |

</details>

Notably **not** included, and why: `sys-devel/gdb` (i486+musl cross-build not worth the effort — use `strace`), `www-client/w3m` (build failure — use `lynx`), `net-analyzer/nmap` and `sys-apps/man-db` (pull in a Python dependency chain not worth the ISO-size cost), `sys-devel/gcc` (no native compiler on the live system, to keep the ISO small), and `net-misc/ppp` (kernel PPP support is built in via `CONFIG_PPP_ASYNC`/`CONFIG_SLIP`, but the userspace `pppd` binary isn't — SLIP over serial works out of the box, full PPP does not).

### Core components

| Component | Version | Source |
|---|---|---|
| Linux kernel | 6.12.80 | `configs/portage/versions.lock` |
| musl libc (cross target) | 1.2.6 | `configs/portage/crossdev.lock` |
| Cross GCC | 15.2.1_p20260214 | `configs/portage/crossdev.lock` |
| binutils | 2.46.0 | `configs/portage/versions.lock` |
| BusyBox (initrd only) | 1.36.1-r4 | `configs/portage/versions.lock` |
| SYSLINUX / GRUB | resolved from the pinned Portage snapshot (`BUILD_EPOCH`) at build time, not separately pinned | `Dockerfile` |

Every package version is pinned in `configs/portage/versions.lock`; the cross-toolchain (musl + GCC) is pinned separately in `configs/portage/crossdev.lock`. A single `BUILD_EPOCH` (`Dockerfile`) pins both the Gentoo stage3 base image and the Portage snapshot to the same date, so a given epoch always resolves to the same toolchain and ebuild tree.

Linking is static-first (`USE="static static-libs"` in `configs/portage/make.conf`) but not universally static yet: `util-linux`, `iproute2`, `dhcpcd`, `procps`, `tar`, `gawk`, and a few others currently ignore the static USE flag and build as dynamically-linked PIE binaries — a tracked gap, not a design goal.

---

## Boot support matrix

| Path | Mechanism | Status |
|---|---|---|
| BIOS | ISOLINUX | Built on every ISO |
| UEFI 64-bit | GRUB (`grub-mkstandalone`, `BOOTX64.EFI`), FAT16 ESP | Built on every ISO, verified under QEMU + OVMF |
| UEFI 32-bit | Dockerfile enables `GRUB_PLATFORMS="efi-32 efi-64"` in the builder toolchain, but `scripts/build-iso.sh` only emits a 64-bit (`x86_64-efi`) standalone image today | **Not built** — toolchain-ready, not wired up (TODO) |
| Hybrid USB/CD | GPT + MBR hybrid via `xorriso -isohybrid-gpt-basdat`, with the EFI System Partition GUID patched post-build | Built on every ISO |

### ISOLINUX boot labels (`boot:` prompt)

| Label | Effect |
|---|---|
| `linux` | Normal boot, text console (default) |
| `fb` | Framebuffer, 1024x768 |
| `fb800` | Framebuffer, 800x600 |
| `fb640` | Framebuffer, 640x480 (safest on old hardware) |
| `vga` | Prompt interactively for a video mode |
| `serial` | Serial console, `ttyS0` at 115200n8 |
| `debug` | Verbose boot output |
| `rescue` | Drop straight to a rescue shell |

`toram` (copy the SquashFS into RAM so the boot media can be ejected) is a kernel parameter, not its own ISOLINUX label — append it manually, e.g. `linux toram`. GRUB's UEFI menu does have a dedicated **toram** entry alongside normal/framebuffer/serial/debug/rescue ones (`scripts/build-iso.sh`).

To boot from a real root filesystem instead of the live overlay, append `root=`:

```
linux root=/dev/sda1     # SATA/SCSI disk
linux root=/dev/hda1     # IDE disk
serial root=/dev/sda1    # serial console
linux toram               # copy rootfs to RAM, media ejectable
```

### Hardware / platform targets

The kernel is built with `-march=i486 -mtune=i486` (`configs/portage/make.conf`) and ships drivers for DEC Tulip (`CONFIG_TULIP`), 3Com Vortex (`CONFIG_VORTEX`), Intel e100/e1000 (`CONFIG_E100`, `CONFIG_E1000`), Realtek 8139/8169 (`CONFIG_8139TOO`, `CONFIG_R8169`), and VirtIO-net (`CONFIG_VIRTIO_NET`) — covering real vintage NICs through QEMU/KVM and Hyper-V paravirtual devices. GPT+MBR hybrid layout with `-iso_mbr_part_type 0x00` targets Hyper-V Gen 1 BIOS boot specifically. UEFI 64-bit boot is verified under QEMU + OVMF (`RELEASE-READINESS.md`).

---

## Supply chain / attestation

`make attestation` runs a multi-pillar pipeline (`scripts/attestation.sh`) against the extracted sysroot and the assembled ISO:

1. **SBOM generation** — [Syft](https://github.com/anchore/syft) scans the sysroot's Portage package DB into a CycloneDX SBOM.
2. **CPE enrichment** (`scripts/enrich-sbom.py`) — maps Portage package names to CPE identifiers (with a manual override list at `configs/attestation/cpe-overrides.yaml`) so CVE scanners can match them, and stamps the ISO's own SHA-256 into the SBOM's top-level component hash.
3. **License compliance** (`scripts/check-licenses.py`) — every package's Portage `LICENSE` field is mapped to SPDX and checked against `configs/attestation/license-policy.yaml`.
4. **CVE gate** (`scripts/check-cves.sh`, via [Grype](https://github.com/anchore/grype)) — fails the build on any matched CVE not explicitly excluded.
5. **Unowned files audit** (`scripts/check-unowned.py`) — flags any file on disk not claimed by a Portage package.
6. **SLSA v1.0 provenance** (`scripts/generate-provenance.py`) — an in-toto statement recording the exact git commit, GitHub Actions run, Gentoo stage3 digest, Portage snapshot, and kernel source hash that produced the ISO. Signed via GitHub's Sigstore-backed Artifact Attestations in CI.
7. **Builder attestation** (`make attest-builder`, optional) — SBOM + CVE scan of the *builder image itself*, not just the ISO contents.

All artifacts for every build are synced to `s3://themonolith/attestation/<build-tag>/` and rolled up into `builds-index.json`, which the dashboard SPA (`web/`) renders as a build-history table with links into each build's detail and package pages.

A `scripts/nightly-cve-monitor.py` script exists to re-scan every historical build's SBOM against the latest CVE database and mark previously-clean releases `revoked` if new CVEs surface — **this is not currently wired into a scheduled GitHub Actions job** (the weekly `schedule:` trigger in `.github/workflows/build.yml` re-runs a full build, not this script). Treat "nightly re-scan" as a capability that exists in the codebase, not yet an active guarantee.

---

## Build instructions

Everything runs through Docker; `make help` prints the full target list. This machine builds nothing itself — verify targets against `Makefile` before relying on this table.

**Docker**
| Target | Does |
|---|---|
| `build-image` | Build the builder image (Gentoo stage3 + crossdev toolchain), pulling from `REGISTRY` first if set |
| `push-image` / `pull-image` | Push/pull the builder image to/from a registry |
| `shell` | Drop into a container shell |

**Packages**
| Target | Does |
|---|---|
| `sync-portage` | Sync the Portage tree, pinned to `BUILD_EPOCH` |
| `build-packages` | Cross-compile everything in `configs/portage/world` |
| `build-packages-resume` | Resume, skipping already-built packages |
| `build-rootfs` | Install binpkgs → SquashFS rootfs + initramfs |
| `extract` | Alias for the install-only step of `build-rootfs` |

**Configuration**
| Target | Does |
|---|---|
| `menuconfig-kernel` | Interactive kernel config, saved to `configs/kernel.config` |
| `menuconfig-busybox` | Interactive BusyBox config, saved to `configs/portage/savedconfig/sys-apps/busybox` (initrd only) |

**ISO / test**
| Target | Does |
|---|---|
| `iso` | Assemble the bootable ISO from squashfs + initrd + vmlinuz |
| `all` | `build-image` → `sync-portage` → `build-packages` → `build-rootfs` → `iso` |
| `test` | Boot the ISO in QEMU via BIOS (`qemu-system-i386`) |
| `test-uefi` | Boot the ISO in QEMU via UEFI (`qemu-system-x86_64` + OVMF) |

**Attestation / dashboard**
| Target | Does |
|---|---|
| `attestation` | Run the SBOM/license/CVE/provenance pipeline (requires `build-rootfs` first) |
| `attest-builder` | Same, plus SBOM+CVE scan of the builder image itself |
| `dashboard` | Generate `builds-index.json` and stage `web/` static assets |
| `grype-db-update` | Update the local Grype CVE database |

**Version management**
| Target | Does |
|---|---|
| `check-updates` | Show available Portage updates vs. pinned versions |
| `update-versions` | Refresh `versions.lock` |
| `update-build-pins` | Refresh `BUILD_EPOCH`/stage3 date in the `Dockerfile` |
| `update-all` | Both of the above |
| `list-packages` | Print `configs/portage/world` |
| `show-failed` | Show packages that failed the last build |

**Maintenance:** `clean`, `clean-build`, `clean-all`

```bash
make build-image     # once, or after Dockerfile changes
make sync-portage     # once, or to pick up package updates
make all              # image → packages → rootfs → iso
make test              # boot in QEMU
```

### Requirements

- Docker
- `qemu-system-i386` (BIOS test) / `qemu-system-x86_64` + OVMF (`ovmf`/`edk2-ovmf` package, UEFI test)
- For the attestation pipeline: the builder image ships Syft + Grype already; `make attestation` needs `output/sysroot/` populated by `build-rootfs` first

---

## Networking

BusyBox in the initrd provides `ip`, `ifconfig`, `route`, `udhcpc`, `ping`, `traceroute`, `netstat`, `arp`, `nc`, `wget`, `telnet`, and `slattach`. The full rootfs additionally has `sys-apps/iproute2`, `net-tools`, `dhcpcd`, `curl`, `wget`, `whois`, `netcat`, `traceroute`, `socat`, `iftop`, and `tcpdump` from Portage.

```bash
ip link                       # list interfaces
ip link set eth0 up
dhcpcd eth0                   # DHCP (or: udhcpc -i eth0 in the initrd)
ip addr add 192.168.1.100/24 dev eth0
ip route add default via 192.168.1.1

# SLIP over a serial line (pppd is not built — see "What's inside" above)
slattach -l -p slip /dev/ttyS0
```

Dropbear SSH is available — start it with `dropbear` after networking is up. `/etc/init.d/S20keygen` generates RSA and ECDSA host keys on first boot if they don't exist yet.

---

## Customization

```bash
make menuconfig-kernel     # → configs/kernel.config
make menuconfig-busybox    # → configs/portage/savedconfig/sys-apps/busybox (initrd only)
```

To add or remove userland packages, edit `configs/portage/world` and run `make build-packages`. Per-package Portage tuning (`USE` flags, keywords, env overrides) lives under `configs/portage/package.*`.

---

## Testing

```bash
make test                                                    # QEMU, BIOS, serial console (Ctrl+A X to exit)
make test-uefi                                                # QEMU, UEFI via OVMF
qemu-system-i386 -cdrom output/themonolith-<tag>.iso -m 64M   # graphical output
sudo dd if=output/themonolith-<tag>.iso of=/dev/sdX bs=4M status=progress   # write to USB
```

There is no automated boot validation (no expect/pexpect smoke test) yet — `make test`/`test-uefi` just launch QEMU for manual inspection.

---

## License

MIT License. See [LICENSE](LICENSE) for details.
