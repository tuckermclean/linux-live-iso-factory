#!/bin/bash
#
# build-kernel.sh - Build Linux kernel for i486
#
# This script handles kernel configuration and compilation.
# It's designed to run inside the Docker container.
#
# Usage:
#   ./build-kernel.sh menuconfig  - Run interactive configuration
#   ./build-kernel.sh build       - Build the kernel
#
# The kernel is configured for minimal footprint on i486/Pentium systems:
# - M486 processor type (works on Pentium and later)
# - Minimal driver set
# - XZ-compressed initramfs support
# - No loadable module support (everything built-in for simplicity)

set -e

# Configuration
KERNEL_DIR="${BUILD_DIR}/linux-${KERNEL_VERSION}"
KERNEL_CONFIG="${CONFIGS_DIR}/kernel.config"
DEFAULT_KERNEL_CONFIG="/default-configs/kernel.config"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"

# Cross-compilation settings
export ARCH=i386
export CROSS_COMPILE="${CROSS_COMPILE:-i486-linux-musl-}"

# Number of parallel jobs
JOBS=$(nproc)

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

# Ensure we're in the kernel directory
cd "$KERNEL_DIR"

# Apply kernel patches (idempotent: -N skips already-applied)
if [ -d /patches ]; then
    for p in /patches/linux-*.patch; do
        [ -f "$p" ] || continue
        if patch -p1 -N --dry-run < "$p" >/dev/null 2>&1; then
            log_info "Applying patch: $(basename "$p")"
            patch -p1 -N < "$p"
        else
            log_info "Patch already applied: $(basename "$p")"
        fi
    done
fi

# Function to load or create config
load_config() {
    if [ -f "$KERNEL_CONFIG" ]; then
        log_info "Using existing config from $KERNEL_CONFIG"
        cp "$KERNEL_CONFIG" .config
        # Resolve any new options with defaults
        make ARCH=$ARCH olddefconfig
    elif [ -f "$DEFAULT_KERNEL_CONFIG" ]; then
        log_info "Using default config from $DEFAULT_KERNEL_CONFIG"
        cp "$DEFAULT_KERNEL_CONFIG" .config
        # Resolve any new options with defaults
        make ARCH=$ARCH olddefconfig
    else
        log_warn "No config found, generating minimal config"
        # Start with allnoconfig (everything disabled)
        make ARCH=$ARCH allnoconfig

        # Enable essential options via scripts/config
        # These are the bare minimum for a bootable system
        ./scripts/config --enable CONFIG_PRINTK
        ./scripts/config --enable CONFIG_BLK_DEV_INITRD
        ./scripts/config --enable CONFIG_RD_XZ
        ./scripts/config --disable CONFIG_RD_GZIP
        ./scripts/config --disable CONFIG_RD_BZIP2
        ./scripts/config --disable CONFIG_RD_LZMA
        ./scripts/config --disable CONFIG_RD_LZO
        ./scripts/config --disable CONFIG_RD_LZ4
        ./scripts/config --disable CONFIG_RD_ZSTD
        ./scripts/config --enable CONFIG_M486
        ./scripts/config --enable CONFIG_BLOCK
        ./scripts/config --enable CONFIG_BINFMT_ELF
        ./scripts/config --enable CONFIG_BINFMT_SCRIPT
        ./scripts/config --enable CONFIG_BLK_DEV_RAM
        ./scripts/config --set-val CONFIG_BLK_DEV_RAM_COUNT 1
        ./scripts/config --enable CONFIG_BLK_DEV_FD
        ./scripts/config --enable CONFIG_TTY
        ./scripts/config --enable CONFIG_VT
        ./scripts/config --enable CONFIG_VT_CONSOLE
        ./scripts/config --enable CONFIG_UNIX98_PTYS
        ./scripts/config --enable CONFIG_DEVTMPFS
        ./scripts/config --enable CONFIG_DEVTMPFS_MOUNT
        ./scripts/config --enable CONFIG_PROC_FS
        ./scripts/config --enable CONFIG_SYSFS
        ./scripts/config --enable CONFIG_MSDOS_FS
        ./scripts/config --enable CONFIG_NLS_CODEPAGE_437
        ./scripts/config --enable CONFIG_XZ_DEC

        # Update config to resolve dependencies
        make ARCH=$ARCH olddefconfig
    fi
}

# Function to save config back to mounted volume
save_config() {
    if [ -f .config ]; then
        log_info "Saving config to $KERNEL_CONFIG"
        cp .config "$KERNEL_CONFIG"
    fi
}

case "${1:-build}" in
    menuconfig)
        log_info "Starting kernel menuconfig..."
        log_info "Kernel version: $KERNEL_VERSION"
        log_info "Architecture: $ARCH"

        load_config

        # Run menuconfig
        make ARCH=$ARCH menuconfig

        save_config

        log_info "Configuration saved to $KERNEL_CONFIG"
        log_info "Run 'make build' to compile the kernel"
        ;;

    build)
        log_info "Building Linux kernel $KERNEL_VERSION for i486"
        log_info "Cross compiler: ${CROSS_COMPILE}gcc"
        log_info "Using $JOBS parallel jobs"

        load_config

        # Build the kernel (incremental - use 'make clean' explicitly if needed)
        log_info "Compiling kernel..."
        make ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE -j$JOBS bzImage

        # Copy the kernel image to output
        KERNEL_IMAGE="arch/x86/boot/bzImage"
        if [ -f "$KERNEL_IMAGE" ]; then
            cp "$KERNEL_IMAGE" "$OUTPUT_DIR/vmlinuz"
            log_info "Kernel image copied to $OUTPUT_DIR/vmlinuz"

            # Show kernel size
            SIZE=$(stat -c%s "$OUTPUT_DIR/vmlinuz")
            SIZE_KB=$((SIZE / 1024))
            log_info "Kernel size: ${SIZE_KB} KB"
        else
            log_error "Kernel image not found at $KERNEL_IMAGE"
            exit 1
        fi

        # Save the config we used
        save_config

        log_info "Kernel build complete!"
        ;;

    *)
        echo "Usage: $0 {menuconfig|build}"
        exit 1
        ;;
esac
