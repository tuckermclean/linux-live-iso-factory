#!/bin/bash
#
# build-initrd.sh - Create initramfs for minimal Linux
#
# This script creates a minimal initramfs (initial RAM filesystem) that:
# - Provides early userspace with BusyBox
# - Mounts essential filesystems (/proc, /sys, /dev)
# - Parses root= kernel parameter
# - Pivots to the real root filesystem
#
# The initramfs is compressed with XZ for minimal size (important for
# floppy-era machines and slow CD-ROM drives).

set -e

# Configuration
INITRD_DIR="${INITRD_DIR:-/initrd}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
ROOTFS_SKELETON="/rootfs"

# Input files
BUSYBOX_BIN="${OUTPUT_DIR}/busybox"

# Output file
INITRD_IMAGE="${OUTPUT_DIR}/initrd.img"

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
if [ ! -f "$BUSYBOX_BIN" ]; then
    log_error "BusyBox binary not found at $BUSYBOX_BIN"
    log_error "Run 'make build-busybox' first"
    exit 1
fi

log_info "Creating initramfs..."

# Clean and create initrd directory structure
rm -rf "${INITRD_DIR}"/*
mkdir -p "${INITRD_DIR}"/{bin,sbin,etc,proc,sys,dev,mnt,newroot,tmp,var/run,usr/share/udhcpc,etc/iproute2}

log_info "Installing BusyBox..."

# Copy busybox and create symlinks for all applets
cp "$BUSYBOX_BIN" "${INITRD_DIR}/bin/busybox"
chmod +x "${INITRD_DIR}/bin/busybox"

# Create symlinks for all busybox applets
# We run busybox --list to get all available applets
cd "${INITRD_DIR}/bin"
for applet in $(./busybox --list); do
    # Skip busybox itself
    [ "$applet" = "busybox" ] && continue

    # Create symlink if it doesn't exist
    if [ ! -e "$applet" ]; then
        ln -s busybox "$applet"
    fi
done

# Also create symlinks in /sbin for traditional locations
cd "${INITRD_DIR}/sbin"
for applet in init mount umount mdev; do
    if [ -e "${INITRD_DIR}/bin/$applet" ] || "${INITRD_DIR}/bin/busybox" --list | grep -qw "$applet"; then
        ln -sf ../bin/busybox "$applet"
    fi
done

log_info "Installing init script..."

# Copy init script from skeleton
if [ -f "${ROOTFS_SKELETON}/init" ]; then
    cp "${ROOTFS_SKELETON}/init" "${INITRD_DIR}/init"
    chmod +x "${INITRD_DIR}/init"
else
    log_error "Init script not found at ${ROOTFS_SKELETON}/init"
    exit 1
fi

# Create minimal /etc files
log_info "Creating configuration files..."

# /etc/passwd - minimal, just root
cat > "${INITRD_DIR}/etc/passwd" << 'EOF'
root:x:0:0:root:/:/bin/sh
EOF

# /etc/group - minimal
cat > "${INITRD_DIR}/etc/group" << 'EOF'
root:x:0:
EOF

# /etc/fstab - mostly for documentation, init handles mounting
cat > "${INITRD_DIR}/etc/fstab" << 'EOF'
# /etc/fstab - static filesystem information
# This initramfs mounts filesystems via /init script
# <device>  <mount point>  <type>  <options>  <dump>  <pass>
proc        /proc          proc    defaults   0       0
sysfs       /sys           sysfs   defaults   0       0
devtmpfs    /dev           devtmpfs defaults  0       0
EOF

# /etc/inittab for BusyBox init (if using init instead of /init script directly)
cat > "${INITRD_DIR}/etc/inittab" << 'EOF'
# /etc/inittab - BusyBox init configuration
#
# Format: <id>:<runlevels>:<action>:<process>
#
# This is a minimal inittab for the initramfs.
# The main init logic is in /init script.

# Start system initialization
::sysinit:/init

# Spawn a shell on console if init script doesn't pivot
::respawn:-/bin/sh

# Graceful shutdown
::shutdown:/bin/umount -a -r
EOF

# /etc/resolv.conf - DNS configuration (initially empty, populated by DHCP)
touch "${INITRD_DIR}/etc/resolv.conf"

# /etc/hosts - basic hosts file
cat > "${INITRD_DIR}/etc/hosts" << 'EOF'
127.0.0.1   localhost
::1         localhost
EOF

# Copy udhcpc default script
log_info "Installing networking scripts..."
if [ -f "${ROOTFS_SKELETON}/usr/share/udhcpc/default.script" ]; then
    cp "${ROOTFS_SKELETON}/usr/share/udhcpc/default.script" "${INITRD_DIR}/usr/share/udhcpc/default.script"
    chmod +x "${INITRD_DIR}/usr/share/udhcpc/default.script"
else
    log_warn "udhcpc default.script not found, DHCP may not work"
fi

# Create minimal /etc/iproute2 config for tc (traffic control)
cat > "${INITRD_DIR}/etc/iproute2/rt_tables" << 'EOF'
# Reserved values
255     local
254     main
253     default
0       unspec
EOF

# Create device nodes
# Note: devtmpfs will handle most devices, but we need a few for early boot
log_info "Creating essential device nodes..."
cd "${INITRD_DIR}/dev"

# Console and null are needed before devtmpfs is mounted
mknod -m 622 console c 5 1 2>/dev/null || true
mknod -m 666 null c 1 3 2>/dev/null || true
mknod -m 666 zero c 1 5 2>/dev/null || true
mknod -m 666 tty c 5 0 2>/dev/null || true

# Show initrd contents for debugging
log_info "Initramfs contents:"
find "${INITRD_DIR}" -type f -o -type l | head -50
echo "..."

# Calculate uncompressed size
UNCOMPRESSED_SIZE=$(du -sk "${INITRD_DIR}" | cut -f1)
log_info "Uncompressed initramfs size: ${UNCOMPRESSED_SIZE} KB"

# Create the cpio archive and compress with gzip (low memory decompression for i486)
log_info "Creating compressed initramfs image..."
cd "${INITRD_DIR}"
find . -print0 | cpio --null -o -H newc 2>/dev/null | gzip -9 > "${INITRD_IMAGE}"

# Show final size
COMPRESSED_SIZE=$(stat -c%s "${INITRD_IMAGE}")
COMPRESSED_SIZE_KB=$((COMPRESSED_SIZE / 1024))
log_info "Compressed initramfs size: ${COMPRESSED_SIZE_KB} KB"
log_info "Compression ratio: $(echo "scale=1; ${UNCOMPRESSED_SIZE} / ${COMPRESSED_SIZE_KB}" | bc)x"

log_info "Initramfs created at ${INITRD_IMAGE}"
