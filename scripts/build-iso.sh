#!/bin/bash
#
# build-iso.sh - Create bootable ISO image
#
# This script creates a BIOS-bootable ISO using ISOLINUX.
# A stub EFI partition creates a hybrid MBR+GPT layout for Hyper-V compatibility.
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

# Input files
KERNEL_IMAGE="${OUTPUT_DIR}/themonolith-${BUILD_VERSION}.vmlinuz"
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

# Copy kernel, initrd, and squashfs
log_info "Copying kernel, initrd, and rootfs..."
cp "$KERNEL_IMAGE" "${ISO_DIR}/boot/vmlinuz"
cp "$INITRD_IMAGE" "${ISO_DIR}/boot/initrd.img"
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
cat > "${ISO_DIR}/isolinux/isolinux.cfg" << 'EOF'
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
DEFAULT linux

# Prompt for user input
PROMPT 1

# Display message
SAY
SAY =========================================
SAY   Minimal i486 Linux
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
    MENU LABEL Boot The Monolith
    KERNEL /boot/vmlinuz
    APPEND initrd=/boot/initrd.img quiet

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

# Create stub EFI partition image for GPT hybrid structure.
# Hyper-V Gen 1 (BIOS mode) needs a GPT partition table in the ISO to boot.
# A minimal empty FAT image triggers xorriso's hybrid MBR+GPT layout via
# -isohybrid-gpt-basdat. The EFI partition is non-functional — boot is BIOS only.
log_info "Creating stub EFI partition for GPT hybrid layout..."
EFI_IMG="${ISO_DIR}/boot/efi.img"
dd if=/dev/zero of="$EFI_IMG" bs=1K count=512 2>/dev/null
mkfs.vfat -F 12 "$EFI_IMG" >/dev/null

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
log_info "  - BIOS (ISOLINUX): Yes"
log_info "  - GPT hybrid:      Yes (Hyper-V Gen 1 compatible)"
log_info "  - USB hybrid:      Yes"
log_info ""
log_info "Test with QEMU:"
log_info "  qemu-system-i386 -cdrom $ISO_IMAGE -m 64M"
log_info ""
log_info "Write to USB:"
log_info "  dd if=$ISO_IMAGE of=/dev/sdX bs=4M status=progress"
