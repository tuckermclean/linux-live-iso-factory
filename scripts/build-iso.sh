#!/bin/bash
#
# build-iso.sh - Create bootable ISO image (BIOS + UEFI)
#
# This script creates a hybrid ISO bootable via BIOS (ISOLINUX) and UEFI (GRUB).
# The EFI System Partition contains bootia32.efi and bootx64.efi for 32/64-bit UEFI.
#
# The ISO can be tested with:
#   qemu-system-i386 -cdrom boot.iso -m 64M
#
# Or written to a USB drive:
#   dd if=boot.iso of=/dev/sdX bs=4M status=progress

set -e

# Configuration
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
ISO_DIR="/tmp/iso"

# Input files — versioned name preferred (from restore-cache or CI), falls back
# to the unversioned copy that build-packages.sh writes to output/vmlinuz.
if [ -f "${OUTPUT_DIR}/themonolith-${BUILD_VERSION}.vmlinuz" ]; then
    KERNEL_IMAGE="${OUTPUT_DIR}/themonolith-${BUILD_VERSION}.vmlinuz"
elif [ -f "${OUTPUT_DIR}/vmlinuz" ]; then
    KERNEL_IMAGE="${OUTPUT_DIR}/vmlinuz"
else
    KERNEL_IMAGE="${OUTPUT_DIR}/themonolith-${BUILD_VERSION}.vmlinuz"  # will trigger the error below
fi
INITRD_IMAGE="${OUTPUT_DIR}/themonolith-${BUILD_VERSION}.initrd"
SQUASHFS_IMAGE="${OUTPUT_DIR}/themonolith-${BUILD_VERSION}.squashfs"

# Output file
ISO_IMAGE="${OUTPUT_DIR}/themonolith-${BUILD_VERSION}.iso"

# ISOLINUX files - auto-detect Gentoo vs Debian layout
# Gentoo: /usr/share/syslinux/
# Debian: /usr/lib/ISOLINUX/ and /usr/lib/syslinux/modules/bios/
if [ -f /usr/share/syslinux/isolinux.bin ]; then
    # Gentoo layout
    SYSLINUX_DIR="/usr/share/syslinux"
    ISOLINUX_BIN="${SYSLINUX_DIR}/isolinux.bin"
    LDLINUX_C32="${SYSLINUX_DIR}/ldlinux.c32"
    LIBUTIL_C32="${SYSLINUX_DIR}/libutil.c32"
    LIBCOM32_C32="${SYSLINUX_DIR}/libcom32.c32"
    ISOHDPFX_BIN="${SYSLINUX_DIR}/isohdpfx.bin"
elif [ -f /usr/lib/ISOLINUX/isolinux.bin ]; then
    # Debian layout
    ISOLINUX_BIN="/usr/lib/ISOLINUX/isolinux.bin"
    LDLINUX_C32="/usr/lib/syslinux/modules/bios/ldlinux.c32"
    LIBUTIL_C32="/usr/lib/syslinux/modules/bios/libutil.c32"
    LIBCOM32_C32="/usr/lib/syslinux/modules/bios/libcom32.c32"
    ISOHDPFX_BIN="/usr/lib/ISOLINUX/isohdpfx.bin"
else
    log_error "syslinux/isolinux not found"
    exit 1
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check prerequisites
if [ ! -f "$KERNEL_IMAGE" ]; then
    log_error "Kernel image not found at $KERNEL_IMAGE"
    log_error "Run 'make build-kernel' first"
    exit 1
fi

if [ ! -f "$INITRD_IMAGE" ]; then
    log_error "Initrd image not found at $INITRD_IMAGE"
    log_error "Run 'make initrd' first"
    exit 1
fi

if [ ! -f "$SQUASHFS_IMAGE" ]; then
    log_error "SquashFS image not found at $SQUASHFS_IMAGE"
    log_error "Run 'make rootfs' first"
    exit 1
fi

log_info "Creating bootable ISO..."

# Clean and create ISO directory structure
rm -rf "${ISO_DIR}"
mkdir -p "${ISO_DIR}"/{isolinux,boot}

# Copy kernel, initrd, and squashfs into the ISO tree
log_info "Copying kernel, initrd, and rootfs..."
cp "$KERNEL_IMAGE"   "${ISO_DIR}/boot/vmlinuz"
cp "$INITRD_IMAGE"   "${ISO_DIR}/boot/initrd.img"
cp "$SQUASHFS_IMAGE" "${ISO_DIR}/rootfs.squashfs"

# Copy ISOLINUX bootloader
log_info "Installing ISOLINUX bootloader..."
cp "$ISOLINUX_BIN" "${ISO_DIR}/isolinux/"
cp "$LDLINUX_C32" "${ISO_DIR}/isolinux/"

# Copy additional modules if they exist (for menu support, etc.)
for module in "$LIBUTIL_C32" "$LIBCOM32_C32"; do
    if [ -f "$module" ]; then
        cp "$module" "${ISO_DIR}/isolinux/"
    fi
done

# Create ISOLINUX configuration
log_info "Creating ISOLINUX configuration..."
cat > "${ISO_DIR}/isolinux/isolinux.cfg" << EOF
# ISOLINUX configuration for Minimal i486 Linux
#
# Boot options:
#   - Default boots to initramfs shell
#   - Append root=/dev/xxx to specify root filesystem
#   - Append init=/path/to/init to specify init program
#
# Examples:
#   root=/dev/sda1              - Boot from first SATA/SCSI partition
#   root=/dev/hda1              - Boot from first IDE partition
#   root=/dev/fd0               - Boot from floppy
#   console=ttyS0,9600n8        - Serial console at 9600 baud

# Timeout in 1/10 seconds (50 = 5 seconds)
TIMEOUT 50

# Default entry
DEFAULT fb800

# Prompt for user input
PROMPT 1

# Display message
SAY
SAY =========================================
SAY   tHE m0n0LiTH  ${BUILD_VERSION}
SAY =========================================
SAY
SAY Press ENTER to boot, or type a label:
SAY   linux     - Normal boot (text console)
SAY   fb        - Framebuffer 1024x768
SAY   fb800     - Framebuffer 800x600
SAY   serial    - Serial console
SAY   vga=ask   - Choose video mode
SAY

# Main boot entry (text mode)
LABEL linux
    MENU LABEL Boot The Monolith ${BUILD_VERSION}
    KERNEL /boot/vmlinuz
    APPEND initrd=/boot/initrd.img
# Framebuffer 1024x768x16
LABEL fb
    MENU LABEL Boot with Framebuffer (1024x768)
    KERNEL /boot/vmlinuz
    APPEND initrd=/boot/initrd.img quiet vga=791

# Framebuffer 800x600x16 (safer for old hardware)
LABEL fb800
    MENU LABEL Boot with Framebuffer (800x600)
    KERNEL /boot/vmlinuz
    APPEND initrd=/boot/initrd.img quiet vga=788

# Framebuffer 640x480x16 (safest)
LABEL fb640
    MENU LABEL Boot with Framebuffer (640x480)
    KERNEL /boot/vmlinuz
    APPEND initrd=/boot/initrd.img quiet vga=785

# Ask for video mode
LABEL vga
    MENU LABEL Boot (choose video mode)
    KERNEL /boot/vmlinuz
    APPEND initrd=/boot/initrd.img vga=ask

# Serial console boot (useful for headless machines or QEMU -nographic)
LABEL serial
    MENU LABEL Boot with Serial Console
    KERNEL /boot/vmlinuz
    APPEND initrd=/boot/initrd.img console=ttyS0,115200n8

# Debug boot with verbose output
LABEL debug
    MENU LABEL Boot with Debug Output
    KERNEL /boot/vmlinuz
    APPEND initrd=/boot/initrd.img debug

# Rescue shell — passes 'rescue' to kernel so init drops to a shell
LABEL rescue
    MENU LABEL Rescue Shell
    KERNEL /boot/vmlinuz
    APPEND initrd=/boot/initrd.img rescue
EOF

# UEFI boot via GRUB EFI — the standard approach used by every Linux live distro.
#
# GRUB runs as EFI/BOOT/BOOTX64.EFI on the ISO9660 tree (CD/DVD path) and also
# lives inside a FAT ESP image for hybrid USB boot. GRUB uses the EFI Handover
# Protocol to load our 32-bit i486 kernel from a 64-bit UEFI environment.
#
# We pin to GRUB 2.12 (same version Ubuntu 24.04 ships) to avoid a regression
# introduced in 2.14 where grub_fatal() fires on Hyper-V EFI memory regions that
# are reported as free but refuse AllocatePages at fixed addresses.

log_info "Building GRUB EFI image (BOOTX64.EFI)..."
mkdir -p "${ISO_DIR}/EFI/BOOT" "${ISO_DIR}/boot/grub"

# Copy background image into the ISO tree so GRUB can load it at boot
if [ -f /configs/bootbg.png ]; then
    cp /configs/bootbg.png "${ISO_DIR}/boot/grub/bootbg.png"
else
    log_warn "bootbg.png not found at /configs/bootbg.png — GRUB will boot without background"
fi

GRUB_CFG=$(mktemp)
cat > "$GRUB_CFG" << GRUBEOF
set timeout=5
set default=1

# Locate the ISO9660 volume by label. On UEFI boot, GRUB's root defaults to the
# ESP (FAT image), so /boot/vmlinuz would not be found. search switches root to
# the ISO9660 partition before any linux/initrd commands run.
search --no-floppy --set=root --label MONOLITH

# Graphical terminal with background image
insmod gfxterm
insmod png
terminal_output gfxterm
background_image /boot/grub/bootbg.png

menuentry "tHE m0n0LiTH ${BUILD_VERSION}" {
    linux /boot/vmlinuz    initrd /boot/initrd.img
}

menuentry "tHE m0n0LiTH ${BUILD_VERSION} (framebuffer)" {
    linux /boot/vmlinuz video=efifb    initrd /boot/initrd.img
}

menuentry "tHE m0n0LiTH ${BUILD_VERSION} (serial)" {
    linux /boot/vmlinuz console=ttyS0,115200n8
    initrd /boot/initrd.img
}

menuentry "tHE m0n0LiTH ${BUILD_VERSION} (debug)" {
    linux /boot/vmlinuz debug
    initrd /boot/initrd.img
}

menuentry "tHE m0n0LiTH ${BUILD_VERSION} (rescue shell)" {
    linux /boot/vmlinuz rescue
    initrd /boot/initrd.img
}

menuentry "tHE m0n0LiTH ${BUILD_VERSION} (toram)" {
    linux /boot/vmlinuz toram    initrd /boot/initrd.img
}
GRUBEOF

grub-mkstandalone \
    --format=x86_64-efi \
    --output="${ISO_DIR}/EFI/BOOT/BOOTX64.EFI" \
    --modules="part_gpt part_msdos fat iso9660 linux normal echo all_video test \
               keystatus gfxmenu regexp probe efi_gop efi_uga search configfile \
               gzio serial gfxterm png" \
    "boot/grub/grub.cfg=${GRUB_CFG}"
rm -f "$GRUB_CFG"

# USB UEFI: minimal FAT ESP containing just BOOTX64.EFI.
# On CD, GRUB reads kernel/initrd from the ISO9660 tree via its iso9660 module.
# On USB, GRUB reads them from the ISO9660 portion of the hybrid image the same
# way — the ESP only needs the bootloader binary itself.
log_info "Creating EFI System Partition image (for USB hybrid boot)..."
EFI_IMG="${ISO_DIR}/boot/efi.img"
EFI_BINARY_SIZE=$(stat -c%s "${ISO_DIR}/EFI/BOOT/BOOTX64.EFI")
EFI_IMG_MB=$(( (EFI_BINARY_SIZE + 1048576 + 1048575) / 1048576 ))
[ "$EFI_IMG_MB" -lt 8 ] && EFI_IMG_MB=8
log_info "EFI image size: ${EFI_IMG_MB} MB"
dd if=/dev/zero of="$EFI_IMG" bs=1M count="$EFI_IMG_MB" 2>/dev/null
mkfs.vfat -F 16 -s 1 -n "EFIBOOT" "$EFI_IMG" >/dev/null
mmd   -i "$EFI_IMG" ::/EFI
mmd   -i "$EFI_IMG" ::/EFI/BOOT
mcopy -i "$EFI_IMG" "${ISO_DIR}/EFI/BOOT/BOOTX64.EFI" ::/EFI/BOOT/BOOTX64.EFI

# Show ISO directory structure
log_info "ISO directory structure:"
find "${ISO_DIR}" -type f | head -20

# Calculate sizes
KERNEL_SIZE=$(stat -c%s "$KERNEL_IMAGE")
INITRD_SIZE=$(stat -c%s "$INITRD_IMAGE")
KERNEL_SIZE_KB=$((KERNEL_SIZE / 1024))
INITRD_SIZE_KB=$((INITRD_SIZE / 1024))
log_info "Kernel size: ${KERNEL_SIZE_KB} KB"
log_info "Initrd size: ${INITRD_SIZE_KB} KB"

# Create the ISO image
log_info "Creating ISO image..."

# Write to a temp file first, then move to output.
# xorriso/libburn can fail on bind-mounted filesystems (e.g. WSL2 + Docker).
ISO_TMP=$(mktemp /tmp/boot.iso.XXXXXX)
trap "rm -f '$ISO_TMP'" EXIT

# Build xorriso command
XORRISO_CMD=(
    xorriso -as mkisofs
    -o "$ISO_TMP"
    -R -J                           # Rock Ridge + Joliet extensions
    -V "MONOLITH"                   # Volume ID
    -b isolinux/isolinux.bin        # BIOS boot image
    -c isolinux/boot.cat            # Boot catalog
    -no-emul-boot                   # No floppy emulation
    -boot-load-size 4               # Load 4 sectors
    -boot-info-table                # Patch boot image with info table
    -isohybrid-mbr "$ISOHDPFX_BIN"  # Make ISO hybrid (USB bootable)
    -iso_mbr_part_type 0x00         # Type 0x00 for Hyper-V BIOS compat
)

# EFI alt-boot entry triggers GPT hybrid layout (Hyper-V Gen 1 compat)
XORRISO_CMD+=(
    -eltorito-alt-boot
    -e boot/efi.img
    -no-emul-boot
    -isohybrid-gpt-basdat
)

# Add the ISO directory
XORRISO_CMD+=("$ISO_DIR")

# Run xorriso
"${XORRISO_CMD[@]}"

# Fix GPT partition 2 type GUID: xorriso's -isohybrid-gpt-basdat marks the EFI
# partition with the Microsoft Basic Data GUID (EBD0A0A2-...). UEFI firmware
# (including OVMF) only recognises an EFI System Partition by its proper GUID
# (C12A7328-F81F-11D2-BA4B-00A0C93EC93B). Without this patch USB UEFI boot
# fails because the firmware never mounts the FAT image as an ESP.
log_info "Patching GPT: setting EFI System Partition type GUID on partition 2..."
python3 - "$ISO_TMP" << 'PYEOF'
import sys, struct, zlib

path = sys.argv[1]
with open(path, 'r+b') as f:
    raw = bytearray(f.read())

SECTOR = 512

# GUID bytes (mixed-endian as stored in GPT partition entries):
#   C12A7328-F81F-11D2-BA4B-00A0C93EC93B
ESP_GUID = bytes([
    0x28,0x73,0x2A,0xC1, 0x1F,0xF8, 0xD2,0x11,
    0xBA,0x4B,0x00,0xA0,0xC9,0x3E,0xC9,0x3B,
])

def patch_gpt(header_lba, part_array_lba, is_backup=False):
    hdr_off  = header_lba    * SECTOR
    part_off = part_array_lba * SECTOR

    hdr = raw[hdr_off : hdr_off + 92]
    if hdr[0:8] != b'EFI PART':
        print(f"  No GPT signature at LBA {header_lba}, skipping", file=sys.stderr)
        return

    num_parts  = struct.unpack_from('<I', hdr, 80)[0]
    entry_size = struct.unpack_from('<I', hdr, 84)[0]

    # Patch entry index 1 (partition 2, 0-based)
    e_off = part_off + 1 * entry_size
    raw[e_off : e_off + 16] = ESP_GUID

    # Recompute partition array CRC32 (all entries, little-endian, seed 0)
    part_array = raw[part_off : part_off + num_parts * entry_size]
    part_crc = zlib.crc32(part_array) & 0xFFFFFFFF
    struct.pack_into('<I', raw, hdr_off + 88, part_crc)

    # Recompute GPT header CRC32 (first 92 bytes, header CRC field zeroed)
    hdr_for_crc = bytearray(raw[hdr_off : hdr_off + 92])
    struct.pack_into('<I', hdr_for_crc, 16, 0)
    hdr_crc = zlib.crc32(bytes(hdr_for_crc)) & 0xFFFFFFFF
    struct.pack_into('<I', raw, hdr_off + 16, hdr_crc)

# Primary GPT: header at LBA 1, partition array at LBA 2
patch_gpt(header_lba=1, part_array_lba=2)

# Backup GPT: header at the last sector, partition array 33 sectors before it
total_sectors = len(raw) // SECTOR
patch_gpt(header_lba=total_sectors - 1, part_array_lba=total_sectors - 33)

with open(path, 'r+b') as f:
    f.write(raw)

print("  GPT partition 2 type GUID → EFI System Partition")
PYEOF

# Move to final output location and make readable outside the container
mv "$ISO_TMP" "$ISO_IMAGE"
chmod 644 "$ISO_IMAGE"

# Show final ISO size
ISO_SIZE=$(stat -c%s "$ISO_IMAGE")
ISO_SIZE_KB=$((ISO_SIZE / 1024))
ISO_SIZE_MB=$((ISO_SIZE / 1024 / 1024))

log_info "=========================================="
log_info "ISO image created successfully!"
log_info "=========================================="
log_info "File: $ISO_IMAGE"
log_info "Size: ${ISO_SIZE_KB} KB (${ISO_SIZE_MB} MB)"
log_info ""
log_info "Boot support:"
log_info "  - BIOS (ISOLINUX):        Yes"
log_info "  - UEFI 64-bit (GRUB 2.12): Yes (BOOTX64.EFI)"
log_info "  - GPT hybrid:             Yes"
log_info "  - USB hybrid:             Yes"
log_info ""
log_info "Test with QEMU:"
log_info "  qemu-system-i386 -cdrom $ISO_IMAGE -m 64M"
log_info ""
log_info "Write to USB:"
log_info "  dd if=$ISO_IMAGE of=/dev/sdX bs=4M status=progress"
