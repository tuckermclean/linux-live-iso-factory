# The Monolith

> One live ISO that boots on everything from a bare-metal 486 to a modern UEFI machine — a full GNU/Linux userland, cross-compiled from source against musl libc, with a cryptographically attested supply chain end to end.

[![Build](https://github.com/tuckermclean/linux-live-iso-factory/actions/workflows/build.yml/badge.svg)](https://github.com/tuckermclean/linux-live-iso-factory/actions/workflows/build.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Dashboard](https://img.shields.io/badge/dashboard-live-4af626)](https://themonolith.s3.amazonaws.com/)

**Dashboard (build history, SBOMs, CVE status):** https://themonolith.s3.amazonaws.com/
**Repo:** https://github.com/tuckermclean/linux-live-iso-factory

The first tagged release is `v0.1.0-rc1`, published as a GitHub **prerelease** (see [`docs/releasing.md`](docs/releasing.md) for the versioning scheme and the RC/prerelease rules). Alongside any tagged release, every nightly/on-push build is published to the S3 bucket above (`themonolith.iso` = latest, `themonolith-<tag>.iso` = pinned per build) and is what's referenced throughout this README.

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

The [world file](configs/portage/world) lists 99 top-level atoms, cross-compiled for `i486-linux-musl` and installed as `.gpkg.tar` binary packages. A handful are custom `monolith-*` overlay ebuilds (kernel, base rootfs helpers, perl, sqlite) plus the Rust-built `rl144` game, the `stele` browser, and the TinyX GUI stack — the rest come from the pinned Gentoo tree. Pulling in dependencies raises the total; see the [dashboard](https://themonolith.s3.amazonaws.com/) for the live attested package count, which changes as packages are added or removed.

<details>
<summary>Full package list (from <code>configs/portage/world</code>)</summary>

| Category | Packages |
|---|---|
| Kernel / init | `sys-kernel/monolith-kernel`, `sys-apps/sysvinit` |
| Rootfs helpers | `app-misc/monolith-base` (owns the hand-authored `/etc`, init scripts, `monolith-net`/`monolith-router`/lazy-console shell, guestbook fixture — formerly installed by `build-rootfs.sh`) |
| Initrd | `sys-apps/busybox` (savedconfig, static, initrd only) |
| Shells | `app-shells/bash`, `app-shells/dash`, `app-shells/zsh`, `app-shells/bash-completion` |
| Core GNU userland | `sys-apps/coreutils`, `sys-apps/util-linux`, `sys-apps/findutils`, `sys-apps/grep`, `sys-apps/sed`, `sys-apps/gawk`, `sys-apps/diffutils`, `app-arch/tar`, `app-text/tree` |
| Core libraries | `sys-libs/readline`, `sys-libs/ncurses`, `sys-libs/zlib`, `dev-libs/libpcre2`, `dev-libs/openssl` |
| File utilities | `sys-apps/file`, `sys-apps/less` |
| Editors | `app-editors/vim`, `app-editors/nano` |
| Man pages | `sys-apps/man-pages`, `app-text/mandoc` |
| Dev tools | `sys-devel/binutils`, `dev-build/make`, `dev-debug/strace`, `sys-devel/patch`, `dev-debug/gdb` (target-native, ptrace-based) |
| Scripting | `dev-lang/lua`, `dev-lang/monolith-perl` (static, `-Uusedl`, CGI.pm 4.10 rider; no CPAN/XS loading) |
| Databases | `dev-db/monolith-sqlite` (static CLI + `libsqlite3.a`, from the amalgamation) |
| Compression | `app-arch/xz-utils`, `app-arch/bzip2`, `app-arch/gzip`, `app-arch/zip`, `app-arch/unzip`, `app-arch/cpio` |
| Networking (config) | `sys-apps/iproute2`, `sys-apps/net-tools`, `net-misc/iputils`, `net-misc/dhcpcd`, `sys-apps/ethtool` |
| Firewall / DHCP-DNS | `net-firewall/nftables`, `net-dns/dnsmasq` (see `monolith-router`, SP2/SP3) |
| Dial-up / WAN | `net-dialup/ppp` (pppd + chat; loadable plugins disabled — all-static) |
| Remote access | `net-misc/dropbear` |
| Network clients | `net-misc/curl`, `net-misc/wget`, `net-misc/whois`, `net-analyzer/netcat`, `net-analyzer/traceroute`, `www-client/lynx`, `mail-client/mutt`, `net-irc/irssi` |
| Network analysis | `net-misc/socat`, `net-analyzer/iftop`, `net-analyzer/tcpdump`, `net-analyzer/mtr`, `net-misc/iperf:3` |
| Terminal / users | `app-misc/tmux`, `sys-apps/shadow` |
| System utilities | `sys-process/procps`, `sys-process/htop`, `sys-process/lsof`, `sys-process/psmisc`, `app-admin/sysklogd`, `sys-apps/pv`, `<sys-fs/ncdu-2` |
| Module tools | `sys-apps/kmod` (modprobe/lsmod/depmod in the booted rootfs) |
| Filesystem tools | `sys-fs/e2fsprogs`, `sys-fs/dosfstools`, `sys-fs/squashfs-tools` |
| File search / sync | `net-misc/rsync`, `sys-apps/the_silver_searcher` |
| Hardware info | `sys-apps/smartmontools`, `sys-apps/hdparm`, `sys-apps/dmidecode` |
| Console font / keymaps | `sys-apps/kbd` (setfont/loadkeys), `media-fonts/terminus-font` |
| Mouse support | `sys-libs/gpm` |
| GUI / X (bitmap-only, no freetype) | `x11-base/monolith-xserver` (TinyX Xfbdev), `x11-base/xorg-proto`, `x11-libs/libxcb`, `x11-libs/libX11`, `x11-libs/libXext`, `x11-terms/monolith-st`, `x11-wm/monolith-dwm` |
| Browser | `www-client/stele` (Rust, no JavaScript; framebuffer + X11 backends) |
| Amusements | `games-misc/bsd-games`, `app-misc/figlet`, `app-misc/cmatrix`, `app-misc/sl`, `games-roguelike/rl144` (Rust roguelike), `=games-roguelike/nethack-3.6.7-r1` |

</details>

Notably **not** included, and why: `www-client/w3m` (build failure — use `lynx` or `stele`), `net-analyzer/nmap` and `sys-apps/man-db` (pull in a Python dependency chain not worth the ISO-size cost), and `sys-devel/gcc` (no native compiler on the live system, to keep the ISO small). `bc` and `jq` are wanted but currently blocked on a masked `libxml2` cross-build (see the note in `configs/portage/world`).

### Core components

| Component | Version | Source |
|---|---|---|
| Linux kernel | 6.12.80-r6 (`monolith-kernel`) | `configs/portage/versions.lock` |
| musl libc (cross target) | 1.2.6 | `configs/portage/crossdev.lock` |
| Cross GCC | 15.3.1_p20260717 | `configs/portage/crossdev.lock` |
| binutils | 2.46.1 | `configs/portage/versions.lock` |
| perl (static, `-Uusedl`) | 5.42.0-r5 (`monolith-perl`) | `configs/portage/versions.lock` |
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
| `linux` | Normal boot, text console |
| `fb` | Framebuffer, 1024x768 (`vga=791`) |
| `fb800` | Framebuffer, 800x600 (`vga=788`) — **default**, 30s timeout |
| `fb640` | Framebuffer, 640x480 (`vga=785`, safest on old hardware) |
| `vga` | Prompt interactively for a video mode (`vga=ask`) |
| `serial` | Serial console, `ttyS0` at 115200n8 |
| `debug` | Verbose boot output |
| `persist` | Boot with the `MONOLITH_PERSIST` persistence partition |
| `rescue` | Drop straight to a rescue shell |

`toram` (copy the SquashFS into RAM so the boot media can be ejected) is a kernel parameter, not its own ISOLINUX label — append it manually, e.g. `linux toram`. GRUB's UEFI menu does have a dedicated **toram** entry, alongside normal/framebuffer/serial/debug/rescue/**persistent** ones (`scripts/build-iso.sh`).

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

## Dashboard

The [dashboard](https://themonolith.s3.amazonaws.com/) is a dependency-free static single-page app (`web/`) — vanilla ES modules, hash-routed, no framework or bundler. It fetches build/attestation JSON live from the public S3 bucket. Its views:

| Route | View |
|---|---|
| `#/` | Landing page |
| `#/boot` | In-browser i486 boot demo (v86 WebAssembly emulator) |
| `#/downloads` | ISO downloads |
| `#/builds` | Build history / attestation index (labeled "Attestation" in the nav) |
| `#/build/<tag>` | Per-build deep dive: SBOM, CVEs, licenses, unowned files, provenance, builder, verify |
| `#/compare/<a>/<b>` | Two-build side-by-side comparison |
| `#/package/<name>` | A package's history across builds |

The only keyboard shortcut is `t` (toggle theme); the old global `g`/`/` shortcuts were removed (`web/app/router.js`). `make dashboard` runs `scripts/generate-dashboard.py` to aggregate every build's `attestation-summary.json` into a timestamp-sorted `builds-index.json` (plus `latest-build.json`) and copies the `web/` assets into `output/web/`; publishing to S3 is a separate step.

---

## Build instructions

Everything runs through Docker; `make help` prints the full target list. This machine builds nothing itself — verify targets against `Makefile` before relying on this table.

**Docker**
| Target | Does |
|---|---|
| `build-image` | Build the builder image (Gentoo stage3 + crossdev toolchain), pulling from `REGISTRY` first if set |
| `push-image` / `pull-image` | Push/pull the builder image to/from a registry |
| `restore-cache` | Reproduce CI's cache setup locally: `pull-image` + `sync-portage` + `aws s3 sync` of the binpkgs for the current `BUILD_EPOCH`. Needs both `REGISTRY` and `S3_BUCKET` set (`REGISTRY=ghcr.io/user S3_BUCKET=my-bucket make restore-cache`) |
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
| `bump-pins` | Bump `BUILD_EPOCH` correctly: pins → rebuild image → `versions.lock` |
| `list-packages` | Print `configs/portage/world` |
| `show-failed` | Show packages that failed the last build |

(A couple of CI-internal targets — `print-registry-tag` and `regen-manifest` — exist in the `Makefile` but are not meant for day-to-day use; `make help` lists the user-facing set.)

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

BusyBox in the initrd provides `ip`, `ifconfig`, `route`, `udhcpc`, `ping`, `traceroute`, `netstat`, `arp`, `nc`, `wget`, `telnet`, and `slattach`. The full rootfs additionally has `iproute2`, `net-tools`, `ethtool`, `dhcpcd`, `curl`, `wget`, `whois`, `netcat`, `traceroute`, `mtr`, `iperf3`, `socat`, `iftop`, and `tcpdump` from Portage, plus `nftables` + `dnsmasq` (firewall/NAT and LAN DHCP/DNS, wired up by `monolith-router`) and `ppp` (`pppd` + `chat`) for serial/PPPoE WAN links.

```bash
ip link                       # list interfaces
ip link set eth0 up
dhcpcd eth0                   # DHCP (or: udhcpc -i eth0 in the initrd)
ip addr add 192.168.1.100/24 dev eth0
ip route add default via 192.168.1.1

# SLIP over a serial line (kernel CONFIG_SLIP)
slattach -l -p slip /dev/ttyS0

# PPP over serial / PPPoE (pppd + chat are built; loadable plugins disabled)
pppd /dev/ttyS0 115200 noauth
```

Dropbear SSH is available — start it with `dropbear` after networking is up. `/etc/init.d/S20keygen` generates RSA and ECDSA host keys on first boot if they don't exist yet.

---

## Graphical environment (X)

The disc ships a minimal, **bitmap-only** X stack — no freetype, fontconfig, or Xft anywhere (see the design doctrines in [`AGENTS.md`](AGENTS.md)):

- **`x11-base/monolith-xserver`** — a static TinyX/kdrive `Xfbdev` server that renders straight to the Linux framebuffer (`vesafb`), zero dlopen. It links a vendored v1 `x11-libs/libXfont` (the `::gentoo` tree ships only the incompatible libXfont2).
- **`x11-terms/monolith-st`** and **`x11-wm/monolith-dwm`** — the suckless terminal and dynamic window manager, both patched off Xft/fontconfig onto core X11 bitmap fonts. `dwm`'s default `Mod+Shift+Return` spawns `st`.
- **`media-fonts/terminus-font`** is the default X font; `fonts.dir` is generated from each PCF's `FONT` property by `scripts/pcf-fontname.py`, and a `fonts.alias` maps `fixed`/`variable` to Terminus.

`startx` brings up `dwm` managing an `st` terminal. The X client libraries (`libX11`, `libxcb`, `libXext`, `xorg-proto`) are cross-built static; each client statically bakes its own `libX11`.

**Stele** (`www-client/stele`) is a from-scratch document-web browser written in Rust — one static binary, **no JavaScript by construction**. It has both a direct-framebuffer backend (`/dev/fb0`, with a compiled-in bitmap font — needs neither X nor fonts on the disc) and an X11 backend. It is actively developed and repinned each build (see the pin in `configs/portage/versions.lock` and `configs/overlay/www-client/stele`).

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

`make test`/`test-uefi` just launch QEMU for manual inspection. The automated
checks live elsewhere:

- **Boot validation** — `scripts/boot-test.py` is a pexpect-driven QEMU harness
  that proves the ISO boots to a usable shell (not merely that `xorriso` didn't
  crash). CI runs it via `.github/workflows/boot-test.yml` across `bios`, `uefi`,
  and `toram` modes plus per-storage-controller module variants (`ahci`, `nvme`,
  `usb`, `virtio`) and a `nicless` negative control.
- **Shell unit tests** — `scripts/tests/*.sh` are standalone POSIX-sh tests that
  stub out hardware/root, so each runs anywhere: `sh scripts/tests/monolith-net.test.sh`.
  `.github/workflows/pr-validate.yml` runs the whole suite (alongside `bash -n`,
  `py_compile`, YAML well-formedness, `actionlint`, and `shellcheck`) on every PR.

---

## License

MIT License. See [LICENSE](LICENSE) for details.
