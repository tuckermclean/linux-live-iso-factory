#!/bin/bash
#
# build-busybox.sh - Build BusyBox for i486
#
# This script handles BusyBox configuration and compilation.
# It's designed to run inside the Docker container.
#
# Usage:
#   ./build-busybox.sh menuconfig  - Run interactive configuration
#   ./build-busybox.sh build       - Build busybox
#
# BusyBox is built:
# - Statically linked against musl (no shared libs needed)
# - Minimal applet set for initramfs pivot_root functionality
# - Optimized for size (-Os)

set -e

# Configuration
BUSYBOX_DIR="${BUILD_DIR}/busybox-${BUSYBOX_VERSION}"
BUSYBOX_CONFIG="${CONFIGS_DIR}/busybox.config"
DEFAULT_BUSYBOX_CONFIG="/default-configs/busybox.config"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"

# Cross-compilation settings
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

# Ensure we're in the busybox directory
cd "$BUSYBOX_DIR"

# Function to load or create config
load_config() {
    if [ -f "$BUSYBOX_CONFIG" ]; then
        log_info "Using existing config from $BUSYBOX_CONFIG"
        cp "$BUSYBOX_CONFIG" .config
        # Resolve any new options with defaults
        yes "" | make CROSS_COMPILE=$CROSS_COMPILE oldconfig
    elif [ -f "$DEFAULT_BUSYBOX_CONFIG" ]; then
        log_info "Using default config from $DEFAULT_BUSYBOX_CONFIG"
        cp "$DEFAULT_BUSYBOX_CONFIG" .config
        # Resolve any new options with defaults
        yes "" | make CROSS_COMPILE=$CROSS_COMPILE oldconfig
    else
        log_warn "No config found, generating minimal config"
        # Start with allnoconfig
        make CROSS_COMPILE=$CROSS_COMPILE allnoconfig

        # Enable essential options
        # These create a minimal but functional busybox for initramfs
        ./scripts/kconfig/merge_config.sh -m .config - <<EOF
CONFIG_STATIC=y
CONFIG_LFS=y
CONFIG_FEATURE_SH_IS_ASH=y
CONFIG_ASH=y
CONFIG_ASH_OPTIMIZE_FOR_SIZE=y
CONFIG_ASH_ALIAS=y
CONFIG_FEATURE_EDITING=y
CONFIG_FEATURE_EDITING_MAX_LEN=1024
CONFIG_INIT=y
CONFIG_LINUXRC=y
CONFIG_CAT=y
CONFIG_CP=y
CONFIG_DF=y
CONFIG_ECHO=y
CONFIG_LS=y
CONFIG_MKDIR=y
CONFIG_MV=y
CONFIG_RM=y
CONFIG_SYNC=y
CONFIG_TEST=y
CONFIG_TEST1=y
CONFIG_TEST2=y
CONFIG_CLEAR=y
CONFIG_VI=y
CONFIG_FEATURE_VI_COLON=y
CONFIG_MDEV=y
CONFIG_MOUNT=y
CONFIG_FEATURE_MOUNT_FLAGS=y
CONFIG_UMOUNT=y
EOF

        # Update config to resolve dependencies
        yes "" | make CROSS_COMPILE=$CROSS_COMPILE oldconfig
    fi
}

# Function to save config back to mounted volume
save_config() {
    if [ -f .config ]; then
        log_info "Saving config to $BUSYBOX_CONFIG"
        cp .config "$BUSYBOX_CONFIG"
    fi
}

case "${1:-build}" in
    menuconfig)
        log_info "Starting busybox menuconfig..."
        log_info "BusyBox version: $BUSYBOX_VERSION"
        log_info "Cross compiler: ${CROSS_COMPILE}gcc"

        load_config

        # Run menuconfig
        make CROSS_COMPILE=$CROSS_COMPILE menuconfig

        save_config

        log_info "Configuration saved to $BUSYBOX_CONFIG"
        log_info "Run 'make build-busybox' to compile BusyBox"
        ;;

    build)
        log_info "Building BusyBox $BUSYBOX_VERSION for i486"
        log_info "Cross compiler: ${CROSS_COMPILE}gcc"
        log_info "Using $JOBS parallel jobs"

        load_config

        # Verify static linking is enabled
        if ! grep -q "CONFIG_STATIC=y" .config; then
            log_warn "CONFIG_STATIC not set, enabling it"
            sed -i 's/# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config
            yes "" | make CROSS_COMPILE=$CROSS_COMPILE oldconfig
        fi

        # Build busybox (incremental - use 'make clean' explicitly if needed)
        log_info "Compiling BusyBox..."
        make CROSS_COMPILE=$CROSS_COMPILE -j$JOBS

        # Verify the binary is static (accepts both "statically linked" and "static-pie linked")
        if file busybox | grep -qE "statically linked|static-pie linked"; then
            log_info "BusyBox is statically linked (good!)"
        else
            log_error "BusyBox is NOT statically linked!"
            file busybox
            exit 1
        fi

        # Verify the binary is i386
        if file busybox | grep -q "Intel 80386"; then
            log_info "BusyBox is compiled for i386 (good!)"
        else
            log_warn "BusyBox may not be compiled for i386:"
            file busybox
        fi

        # Copy busybox to output
        cp busybox "$OUTPUT_DIR/busybox"
        log_info "BusyBox binary copied to $OUTPUT_DIR/busybox"

        # Show binary size
        SIZE=$(stat -c%s "$OUTPUT_DIR/busybox")
        SIZE_KB=$((SIZE / 1024))
        log_info "BusyBox size: ${SIZE_KB} KB"

        # Save the config we used
        save_config

        log_info "BusyBox build complete!"
        ;;

    *)
        echo "Usage: $0 {menuconfig|build}"
        exit 1
        ;;
esac
