#!/bin/bash
#
# build-iso.sh - Create bootable ISO image
#
# This script creates a BIOS-bootable ISO using ISOLINUX.
# It also includes UEFI boot support via a FAT filesystem image.
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
KERNEL_IMAGE="${OUTPUT_DIR}/vmlinuz"
INITRD_IMAGE="${OUTPUT_DIR}/initrd.img"
SQUASHFS_IMAGE="${OUTPUT_DIR}/rootfs.squashfs"

# Output file
ISO_IMAGE="${OUTPUT_DIR}/boot.iso"

# ISOLINUX files (from syslinux package)
ISOLINUX_BIN="/usr/lib/ISOLINUX/isolinux.bin"
LDLINUX_C32="/usr/lib/syslinux/modules/bios/ldlinux.c32"
LIBUTIL_C32="/usr/lib/syslinux/modules/bios/libutil.c32"
LIBCOM32_C32="/usr/lib/syslinux/modules/bios/libcom32.c32"

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
SAY   linux     - Normal boot (drops to shell)
SAY   serial    - Boot with serial console
SAY
SAY Append root=/dev/xxx to boot from disk.
SAY

# Main boot entry
LABEL linux
    MENU LABEL Boot Minimal Linux
    KERNEL /boot/vmlinuz
    APPEND initrd=/boot/initrd.img quiet

# Serial console boot (useful for headless machines or QEMU -nographic)
LABEL serial
    MENU LABEL Boot with Serial Console
    KERNEL /boot/vmlinuz
    APPEND initrd=/boot/initrd.img console=ttyS0,9600n8

# Debug boot with verbose output
LABEL debug
    MENU LABEL Boot with Debug Output
    KERNEL /boot/vmlinuz
    APPEND initrd=/boot/initrd.img debug

# Rescue shell (same as default, but explicit)
LABEL rescue
    MENU LABEL Rescue Shell
    KERNEL /boot/vmlinuz
    APPEND initrd=/boot/initrd.img
EOF

# Create EFI boot support
log_info "Creating UEFI boot support..."

# Check if we have the UEFI syslinux files
SYSLINUX_EFI32="/usr/lib/SYSLINUX.EFI/efi32/syslinux.efi"
LDLINUX_EFI32="/usr/lib/syslinux/modules/efi32/ldlinux.e32"

if [ -f "$SYSLINUX_EFI32" ] && [ -f "$LDLINUX_EFI32" ]; then
    # Create EFI system partition image
    EFI_IMG="${ISO_DIR}/boot/efi.img"
    EFI_SIZE=8192  # 8MB for EFI partition (needs to fit kernel + initrd)

    log_info "Creating EFI boot image..."
    dd if=/dev/zero of="$EFI_IMG" bs=1K count=$EFI_SIZE 2>/dev/null
    mkfs.vfat -F 12 "$EFI_IMG" >/dev/null

    # Create temporary mount point
    EFI_MNT="/tmp/efi_mnt"
    mkdir -p "$EFI_MNT"

    # Mount and populate EFI image using mtools (no root required)
    mmd -i "$EFI_IMG" ::/EFI
    mmd -i "$EFI_IMG" ::/EFI/BOOT
    mcopy -i "$EFI_IMG" "$SYSLINUX_EFI32" ::/EFI/BOOT/BOOTIA32.EFI
    mcopy -i "$EFI_IMG" "$LDLINUX_EFI32" ::/EFI/BOOT/

    # Copy syslinux config for EFI
    mcopy -i "$EFI_IMG" "${ISO_DIR}/isolinux/isolinux.cfg" ::/EFI/BOOT/syslinux.cfg

    # Copy kernel and initrd to EFI image
    mmd -i "$EFI_IMG" ::/boot
    mcopy -i "$EFI_IMG" "$KERNEL_IMAGE" ::/boot/vmlinuz
    mcopy -i "$EFI_IMG" "$INITRD_IMAGE" ::/boot/initrd.img

    log_info "UEFI boot support added (32-bit EFI)"
    HAS_EFI=true
else
    log_warn "UEFI syslinux files not found, creating BIOS-only ISO"
    HAS_EFI=false
fi

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

# Build xorriso command
XORRISO_CMD=(
    xorriso -as mkisofs
    -o "$ISO_IMAGE"
    -R -J                           # Rock Ridge + Joliet extensions
    -V "MINLINUX"                   # Volume ID
    -b isolinux/isolinux.bin        # BIOS boot image
    -c isolinux/boot.cat            # Boot catalog
    -no-emul-boot                   # No floppy emulation
    -boot-load-size 4               # Load 4 sectors
    -boot-info-table                # Patch boot image with info table
    -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin  # Make ISO hybrid (USB bootable)
)

# Add EFI boot if available
if [ "$HAS_EFI" = true ]; then
    XORRISO_CMD+=(
        -eltorito-alt-boot
        -e boot/efi.img
        -no-emul-boot
        -isohybrid-gpt-basdat
    )
fi

# Add the ISO directory
XORRISO_CMD+=("$ISO_DIR")

# Run xorriso
"${XORRISO_CMD[@]}" 2>/dev/null

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
if [ "$HAS_EFI" = true ]; then
    log_info "  - UEFI (32-bit):   Yes"
else
    log_info "  - UEFI (32-bit):   No (syslinux-efi not found)"
fi
log_info "  - USB hybrid:      Yes"
log_info ""
log_info "Test with QEMU:"
log_info "  qemu-system-i386 -cdrom $ISO_IMAGE -m 64M"
log_info ""
log_info "Write to USB:"
log_info "  dd if=$ISO_IMAGE of=/dev/sdX bs=4M status=progress"
