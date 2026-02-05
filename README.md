# Minimal i486 Linux Build System

A Docker-based build environment for creating minimal bootable Linux systems targeting Pentium-class machines (i486 instruction set).

## Features

- **Cross-compilation**: Pre-built i486-linux-musl toolchain from musl.cc
- **Minimal footprint**: Kernel and initramfs optimized for size
- **XZ compression**: Maximum compression for slow CD-ROM/floppy era machines
- **BIOS + UEFI**: Hybrid ISO bootable on both legacy and modern systems
- **Interactive configuration**: menuconfig support for kernel and BusyBox
- **Networking support**: Full TCP/IP stack with iproute2-compatible tools

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

The BusyBox configuration includes:
- `ip` - Full iproute2-compatible interface (ip addr, ip link, ip route, ip rule, ip neigh, ip tunnel)
- `ifconfig` - Legacy interface configuration
- `route` - Legacy routing table management
- `udhcpc` - DHCP client
- `ping`, `traceroute`, `netstat`, `arp`, `arping`
- `nc` (netcat), `wget`, `telnet`
- `tc` - Traffic control
- `slattach` - SLIP/PPP attachment for serial

## Quick Start

```bash
# Build the Docker image
make build-image

# Use default configs (or customize with menuconfig)
make copy-default-configs

# Build everything
make iso

# Test in QEMU
make test
```

## Customization

### Kernel Configuration
```bash
make menuconfig-kernel
```

### BusyBox Configuration
```bash
make menuconfig-busybox
```

## Versions

| Component | Version |
|-----------|---------|
| Linux Kernel | 6.12.11 |
| BusyBox | 1.36.1 |
| SYSLINUX | 6.03 |

## Boot Options

The ISO boots to an initramfs shell by default. To boot from a real root filesystem:

```
linux root=/dev/sda1              # SATA/SCSI disk
linux root=/dev/hda1              # IDE disk
serial root=/dev/sda1             # Serial console
debug root=/dev/sda1              # Verbose boot
```

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

## File Structure

```
├── Dockerfile              # Build environment
├── Makefile                # Host-side convenience targets
├── container-Makefile      # Container-side build orchestration
├── scripts/
│   ├── build-kernel.sh     # Kernel compilation
│   ├── build-busybox.sh    # BusyBox compilation
│   ├── build-initrd.sh     # Initramfs creation
│   └── build-iso.sh        # ISO creation
├── configs/
│   ├── kernel.config       # Kernel .config
│   └── busybox.config      # BusyBox .config
├── rootfs/
│   └── init                # Initramfs init script
└── output/
    ├── vmlinuz             # Kernel image
    ├── initrd.img          # Compressed initramfs
    └── boot.iso            # Bootable ISO
```

## Requirements

- Docker
- QEMU (for testing): `qemu-system-i386`

## Testing on Real Hardware

```bash
# Write to USB drive
sudo dd if=output/boot.iso of=/dev/sdX bs=4M status=progress

# Or burn to CD-ROM
```

## License

Public domain - do what you want.
