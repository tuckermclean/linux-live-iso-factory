# Minimal i486 Linux Build System

A Docker-based build environment for creating minimal bootable Linux systems targeting Pentium-class machines (i486 instruction set). Uses Gentoo crossdev cross-compilation with musl libc to produce a SquashFS-based live ISO with overlayfs.

## Features

- **Gentoo crossdev cross-compilation** for i486-linux-musl
- **Real packages**: bash, dropbear SSH, curl, nano, less, lua, and more
- **All statically linked** with musl libc — no shared library dependencies
- **SquashFS root** with overlayfs (writable layer in RAM)
- **BIOS boot** with hybrid MBR+GPT (USB and Hyper-V Gen 1 compatible)
- **Incremental builds** with binary package caching (`.gpkg.tar`)
- **Version pinning** for reproducible builds (`versions.lock`)
- **Interactive menuconfig** for kernel and BusyBox

## Quick Start

```bash
make build-image       # Build the Docker image (first time only)
make sync-portage      # Sync Gentoo portage tree
make build-packages    # Cross-compile all packages
make extract           # Extract binpkgs to output/sysroot/
make iso               # Build kernel, busybox, initrd, rootfs, ISO
make test              # Boot in QEMU
```

## Included Software

### Packages (from `configs/portage/world`)

| Package | Description |
|---------|-------------|
| app-shells/bash | Real bash shell |
| net-misc/dropbear | Lightweight SSH server/client |
| net-misc/curl | URL transfer tool |
| app-editors/nano | Text editor |
| app-arch/xz-utils | XZ compression |
| app-arch/bzip2 | bzip2 compression |
| app-arch/gzip | gzip compression |
| dev-lang/lua | Lightweight scripting language |
| sys-apps/file | File type identification |
| sys-apps/less | Pager |

### Core Components

| Component | Version |
|-----------|---------|
| Linux Kernel | 6.12.11 |
| BusyBox | 1.36.1 |
| SYSLINUX | 6.03 |

## Build Targets

Run `make help` for the full list. Summary:

**Docker:** `build-image`, `shell`

**Packages (Gentoo cross-compilation):** `sync-portage`, `build-packages`, `build-packages-resume`, `extract`

**Kernel/BusyBox:** `build`, `build-kernel`, `build-busybox`, `menuconfig-kernel`, `menuconfig-busybox`

**ISO:** `iso`, `all`

**Testing:** `test`

**Version Management:** `check-updates`, `update-versions`, `list-packages`, `show-failed`

**Maintenance:** `clean`, `clean-build`, `clean-all`

## Customization

### Kernel Configuration
```bash
make menuconfig-kernel
```

### BusyBox Configuration
```bash
make menuconfig-busybox
```

Two BusyBox configs are provided: `busybox.config` (minimal, for initrd) and `busybox-full.config` (full-featured, for rootfs).

## Boot Options

The ISO presents a boot menu via ISOLINUX. You can type a label at the `boot:` prompt or wait for the default.

| Label | Description |
|-------|-------------|
| `linux` | Boot (text mode, default) |
| `fb` | Framebuffer 1024x768 |
| `fb800` | Framebuffer 800x600 |
| `fb640` | Framebuffer 640x480 |
| `vga` | Choose video mode interactively |
| `serial` | Serial console (115200n8) |
| `debug` | Verbose boot output |
| `rescue` | Rescue shell |

To boot from a real root filesystem, append `root=`:

```
linux root=/dev/sda1              # SATA/SCSI disk
linux root=/dev/hda1              # IDE disk
serial root=/dev/sda1             # Serial console
debug root=/dev/sda1              # Verbose boot
```

## Supported Network Hardware

| Type | Driver | Use Case |
|------|--------|----------|
| DEC Tulip (21x4x) | tulip | Legacy Hyper-V, older PCI NICs |
| virtio-net | virtio_net | KVM/QEMU virtual machines |
| 3Com 3c509 | 3c509 (el3) | ISA NICs |
| 3Com 3c59x/3c90x | vortex | PCI NICs |
| Intel e1000 | e1000 | VMware, QEMU default |
| Realtek 8139 | 8139too | Common cheap NICs |
| Serial modems | ppp_async | USRobotics, dial-up |

## Networking Tools

BusyBox provides networking utilities in the initrd:
- `ip` - iproute2-compatible (ip addr, ip link, ip route, ip rule, ip neigh, ip tunnel)
- `ifconfig` - Legacy interface configuration
- `route` - Legacy routing table management
- `udhcpc` - DHCP client
- `ping`, `traceroute`, `netstat`, `arp`, `arping`
- `nc` (netcat), `wget`, `telnet`
- `slattach` - SLIP/PPP attachment for serial

`curl` is available in the rootfs for HTTPS transfers.

## Networking Quick Start

Once booted to shell:

```bash
# List network interfaces
ip link

# Bring up interface
ip link set eth0 up

# Get IP via DHCP
udhcpc -i eth0

# Or configure manually
ip addr add 192.168.1.100/24 dev eth0
ip route add default via 192.168.1.1

# For PPP/modem (serial)
slattach -p ppp /dev/ttyS0
# Then configure pppd as needed
```

Dropbear SSH is available — start it with `dropbear` after configuring networking.

## File Structure

```
├── Dockerfile                    # Gentoo crossdev build environment
├── Makefile                      # Host-side targets (Docker)
├── container-Makefile            # Container-side build logic
├── configs/
│   ├── kernel.config
│   ├── busybox.config            # Minimal (initrd)
│   ├── busybox-full.config       # Full (rootfs)
│   └── portage/
│       ├── make.conf
│       ├── world                 # Package list
│       ├── versions.lock         # Pinned versions
│       ├── bashrc                # Libtool patching hooks
│       ├── env/
│       ├── package.use/
│       ├── package.env/
│       ├── package.accept_keywords/
│       └── package.mask/
├── scripts/
│   ├── build-packages.sh
│   ├── extract-packages.sh
│   ├── build-kernel.sh
│   ├── build-busybox.sh
│   ├── build-initrd.sh
│   ├── build-rootfs.sh
│   ├── build-iso.sh
│   └── update-versions.sh
├── rootfs/
│   └── init                      # Initramfs init script
├── patches/
│   └── linux-6.12-gcc15-std-gnu11.patch
└── output/                       # Build artifacts
    ├── vmlinuz
    ├── initrd.img
    ├── rootfs.squashfs
    ├── boot.iso
    ├── packages/                 # Binary packages (.gpkg.tar)
    └── sysroot/                  # Extracted packages
```

## Requirements

- Docker
- QEMU for testing: `qemu-system-i386`

## Testing

```bash
# Boot in QEMU (serial console, Ctrl+A X to exit)
make test

# Or with graphical output
qemu-system-i386 -cdrom output/boot.iso -m 64M

# Write to USB drive
sudo dd if=output/boot.iso of=/dev/sdX bs=4M status=progress
```

## License

MIT License. See [LICENSE](LICENSE) for details.
