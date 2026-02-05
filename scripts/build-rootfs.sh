#!/bin/bash
#
# build-rootfs.sh - Build the SquashFS root filesystem
#
# This script creates a full root filesystem with:
# - Full-featured BusyBox (all applets)
# - Bash shell
# - Proper /etc structure
# - SquashFS compressed image
#
# The rootfs is designed to be mounted read-only with a tmpfs overlay.

set -e

# Configuration
ROOTFS_DIR="/rootfs-build"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
CONFIGS_DIR="${CONFIGS_DIR:-/configs}"
BUILD_DIR="${BUILD_DIR:-/build}"

# Cross-compilation settings
export CROSS_COMPILE="${CROSS_COMPILE:-i486-linux-musl-}"

# BusyBox config
BUSYBOX_FULL_CONFIG="${CONFIGS_DIR}/busybox-full.config"
BUSYBOX_SRC="${BUILD_DIR}/busybox-${BUSYBOX_VERSION}"

# Output
SQUASHFS_IMAGE="${OUTPUT_DIR}/rootfs.squashfs"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Number of parallel jobs
JOBS=$(nproc)

#
# Build full-featured BusyBox for rootfs
#
build_busybox_full() {
    log_info "Building full-featured BusyBox for rootfs..."

    # Use a separate build directory to not conflict with initrd busybox
    local bb_build="${BUILD_DIR}/busybox-full-build"
    rm -rf "$bb_build"
    cp -a "$BUSYBOX_SRC" "$bb_build"
    cd "$bb_build"

    if [ -f "$BUSYBOX_FULL_CONFIG" ]; then
        log_info "Using config from $BUSYBOX_FULL_CONFIG"
        cp "$BUSYBOX_FULL_CONFIG" .config
        yes "" | make CROSS_COMPILE=$CROSS_COMPILE oldconfig
    else
        log_info "Generating defconfig"
        make CROSS_COMPILE=$CROSS_COMPILE defconfig
        sed -i 's/^# CONFIG_STATIC is not set$/CONFIG_STATIC=y/' .config
        yes "" | make CROSS_COMPILE=$CROSS_COMPILE oldconfig
    fi

    log_info "Compiling BusyBox (full)..."
    make CROSS_COMPILE=$CROSS_COMPILE -j$JOBS

    # Verify static
    if file busybox | grep -qE "statically linked|static-pie linked"; then
        log_info "BusyBox (full) is statically linked"
    else
        log_error "BusyBox (full) is NOT statically linked!"
        exit 1
    fi

    log_info "BusyBox (full) build complete"
}

#
# Create the root filesystem structure
#
create_rootfs() {
    log_info "Creating root filesystem structure..."

    rm -rf "$ROOTFS_DIR"
    mkdir -p "$ROOTFS_DIR"/{bin,sbin,usr/bin,usr/sbin,lib,usr/lib}
    mkdir -p "$ROOTFS_DIR"/{etc,home,root,tmp,var,proc,sys,dev,mnt,opt,run}
    mkdir -p "$ROOTFS_DIR"/var/{log,tmp,run,lock,spool,cache}
    mkdir -p "$ROOTFS_DIR"/etc/{init.d,network}

    # Set permissions
    chmod 1777 "$ROOTFS_DIR"/tmp
    chmod 1777 "$ROOTFS_DIR"/var/tmp
    chmod 700 "$ROOTFS_DIR"/root

    log_info "Root filesystem structure created"
}

#
# Install BusyBox into rootfs
#
install_busybox() {
    log_info "Installing BusyBox into rootfs..."

    local bb_build="${BUILD_DIR}/busybox-full-build"

    # Copy busybox binary
    cp "$bb_build/busybox" "$ROOTFS_DIR/bin/busybox"
    chmod 755 "$ROOTFS_DIR/bin/busybox"

    # Create symlinks for all applets
    cd "$ROOTFS_DIR/bin"
    for applet in $("$ROOTFS_DIR/bin/busybox" --list); do
        [ "$applet" = "busybox" ] && continue
        ln -sf busybox "$applet" 2>/dev/null || true
    done

    # Create symlinks in /sbin for traditional locations
    cd "$ROOTFS_DIR/sbin"
    for applet in init halt reboot poweroff mount umount mdev; do
        ln -sf ../bin/busybox "$applet" 2>/dev/null || true
    done

    # Create symlinks in /usr/bin
    cd "$ROOTFS_DIR/usr/bin"
    for applet in env; do
        ln -sf ../../bin/busybox "$applet" 2>/dev/null || true
    done

    log_info "BusyBox installed with $(ls "$ROOTFS_DIR/bin" | wc -l) applets"
}

#
# Create /etc configuration files
#
create_etc_files() {
    log_info "Creating /etc configuration files..."

    # /etc/passwd
    cat > "$ROOTFS_DIR/etc/passwd" << 'EOF'
root:x:0:0:root:/root:/bin/sh
nobody:x:65534:65534:nobody:/nonexistent:/bin/false
EOF

    # /etc/group
    cat > "$ROOTFS_DIR/etc/group" << 'EOF'
root:x:0:
wheel:x:10:root
nobody:x:65534:
EOF

    # /etc/shadow (root with no password - login disabled by default)
    cat > "$ROOTFS_DIR/etc/shadow" << 'EOF'
root:*:19000:0:99999:7:::
nobody:*:19000:0:99999:7:::
EOF
    chmod 600 "$ROOTFS_DIR/etc/shadow"

    # /etc/fstab
    cat > "$ROOTFS_DIR/etc/fstab" << 'EOF'
# /etc/fstab - static filesystem information
# <device>       <mount point>  <type>   <options>         <dump> <pass>
proc             /proc          proc     defaults          0      0
sysfs            /sys           sysfs    defaults          0      0
devtmpfs         /dev           devtmpfs defaults          0      0
tmpfs            /tmp           tmpfs    defaults,nosuid   0      0
tmpfs            /run           tmpfs    defaults,nosuid   0      0
EOF

    # /etc/hosts
    cat > "$ROOTFS_DIR/etc/hosts" << 'EOF'
127.0.0.1       localhost
::1             localhost ip6-localhost ip6-loopback
EOF

    # /etc/hostname
    echo "i486-linux" > "$ROOTFS_DIR/etc/hostname"

    # /etc/resolv.conf (empty, populated by DHCP)
    touch "$ROOTFS_DIR/etc/resolv.conf"

    # /etc/profile
    cat > "$ROOTFS_DIR/etc/profile" << 'EOF'
# /etc/profile - system-wide shell initialization

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export TERM="${TERM:-linux}"
export PAGER="less"
export EDITOR="vi"

# Set prompt
if [ "$(id -u)" -eq 0 ]; then
    PS1='\h:\w# '
else
    PS1='\u@\h:\w$ '
fi

# Aliases
alias ll='ls -la'
alias la='ls -A'
alias l='ls -CF'

# Source local profile if it exists
[ -f /etc/profile.local ] && . /etc/profile.local
EOF

    # /etc/shells
    cat > "$ROOTFS_DIR/etc/shells" << 'EOF'
/bin/sh
/bin/ash
EOF

    # /etc/inittab for BusyBox init
    cat > "$ROOTFS_DIR/etc/inittab" << 'EOF'
# /etc/inittab - BusyBox init configuration

# System initialization
::sysinit:/etc/init.d/rcS

# Main console
::respawn:-/bin/sh

# Additional consoles (if available)
tty2::respawn:-/bin/sh
tty3::respawn:-/bin/sh

# Serial console (if kernel console=ttyS0)
ttyS0::respawn:-/bin/sh

# Graceful shutdown
::shutdown:/etc/init.d/rcK
::ctrlaltdel:/sbin/reboot
EOF

    # /etc/init.d/rcS - startup script
    cat > "$ROOTFS_DIR/etc/init.d/rcS" << 'EOF'
#!/bin/sh
# System startup script

echo "Starting system initialization..."

# Mount virtual filesystems (if not already mounted by initramfs)
mountpoint -q /proc || mount -t proc proc /proc
mountpoint -q /sys || mount -t sysfs sysfs /sys
mountpoint -q /dev || mount -t devtmpfs devtmpfs /dev

# Create necessary device nodes
mkdir -p /dev/pts /dev/shm
mount -t devpts devpts /dev/pts 2>/dev/null
mount -t tmpfs tmpfs /dev/shm 2>/dev/null

# Mount tmpfs filesystems
mount -t tmpfs -o nosuid tmpfs /tmp
mount -t tmpfs -o nosuid tmpfs /run

# Set hostname
[ -f /etc/hostname ] && hostname -F /etc/hostname

# Start mdev for hotplug
if [ -x /sbin/mdev ]; then
    echo /sbin/mdev > /proc/sys/kernel/hotplug
    mdev -s
fi

# Run init scripts
for script in /etc/init.d/S*; do
    [ -x "$script" ] && "$script" start
done

echo "System initialization complete."
EOF
    chmod 755 "$ROOTFS_DIR/etc/init.d/rcS"

    # /etc/init.d/rcK - shutdown script
    cat > "$ROOTFS_DIR/etc/init.d/rcK" << 'EOF'
#!/bin/sh
# System shutdown script

echo "System shutting down..."

# Stop init scripts
for script in /etc/init.d/K*; do
    [ -x "$script" ] && "$script" stop
done

# Kill all processes
killall5 -15
sleep 1
killall5 -9

# Unmount filesystems
umount -a -r 2>/dev/null

sync
EOF
    chmod 755 "$ROOTFS_DIR/etc/init.d/rcK"

    # /etc/network/interfaces (for ifup/ifdown)
    cat > "$ROOTFS_DIR/etc/network/interfaces" << 'EOF'
# /etc/network/interfaces
auto lo
iface lo inet loopback

# Uncomment and modify for static IP:
#auto eth0
#iface eth0 inet static
#    address 192.168.1.100
#    netmask 255.255.255.0
#    gateway 192.168.1.1

# Or for DHCP:
#auto eth0
#iface eth0 inet dhcp
EOF

    # udhcpc default script
    mkdir -p "$ROOTFS_DIR/usr/share/udhcpc"
    cp /rootfs/usr/share/udhcpc/default.script "$ROOTFS_DIR/usr/share/udhcpc/" 2>/dev/null || \
    cat > "$ROOTFS_DIR/usr/share/udhcpc/default.script" << 'DHCP_EOF'
#!/bin/sh
# udhcpc default script

[ -z "$1" ] && exit 1

case "$1" in
    deconfig)
        ip addr flush dev $interface
        ip link set $interface up
        ;;
    renew|bound)
        ip addr flush dev $interface
        ip addr add $ip/${mask:-24} dev $interface

        if [ -n "$router" ]; then
            ip route add default via $router dev $interface
        fi

        if [ -n "$dns" ]; then
            echo -n > /etc/resolv.conf
            for ns in $dns; do
                echo "nameserver $ns" >> /etc/resolv.conf
            done
        fi

        [ -n "$domain" ] && echo "search $domain" >> /etc/resolv.conf
        ;;
esac

exit 0
DHCP_EOF
    chmod 755 "$ROOTFS_DIR/usr/share/udhcpc/default.script"

    # /etc/init.d/S40network - network startup
    cat > "$ROOTFS_DIR/etc/init.d/S40network" << 'EOF'
#!/bin/sh
# Network initialization

case "$1" in
    start)
        echo "Starting network..."

        # Bring up loopback
        ip link set lo up
        ip addr add 127.0.0.1/8 dev lo 2>/dev/null

        # Find and configure ethernet interfaces via DHCP
        for iface in /sys/class/net/eth* /sys/class/net/en*; do
            [ -e "$iface" ] || continue
            iface=$(basename "$iface")
            echo "  Configuring $iface via DHCP..."
            ip link set "$iface" up
            udhcpc -i "$iface" -b -q -p "/var/run/udhcpc.$iface.pid" 2>/dev/null &
        done
        ;;
    stop)
        echo "Stopping network..."
        killall udhcpc 2>/dev/null
        for iface in /sys/class/net/eth* /sys/class/net/en*; do
            [ -e "$iface" ] || continue
            iface=$(basename "$iface")
            ip link set "$iface" down 2>/dev/null
        done
        ;;
    restart)
        $0 stop
        $0 start
        ;;
    *)
        echo "Usage: $0 {start|stop|restart}"
        exit 1
        ;;
esac

exit 0
EOF
    chmod 755 "$ROOTFS_DIR/etc/init.d/S40network"

    log_info "/etc configuration files created"
}

#
# Create the SquashFS image
#
create_squashfs() {
    log_info "Creating SquashFS image..."

    # Calculate uncompressed size
    local size_kb=$(du -sk "$ROOTFS_DIR" | cut -f1)
    log_info "Uncompressed rootfs size: ${size_kb} KB"

    # Create SquashFS with gzip compression (low memory for i486)
    mksquashfs "$ROOTFS_DIR" "$SQUASHFS_IMAGE" \
        -comp gzip \
        -b 131072 \
        -no-xattrs \
        -noappend \
        -quiet

    # Show compressed size
    local squash_size=$(stat -c%s "$SQUASHFS_IMAGE")
    local squash_size_kb=$((squash_size / 1024))
    log_info "Compressed SquashFS size: ${squash_size_kb} KB"
    log_info "Compression ratio: $(echo "scale=1; ${size_kb} / ${squash_size_kb}" | bc)x"

    log_info "SquashFS image created at $SQUASHFS_IMAGE"
}

#
# Main
#
main() {
    log_info "========================================"
    log_info "  Building Root Filesystem"
    log_info "========================================"

    build_busybox_full
    create_rootfs
    install_busybox
    create_etc_files
    create_squashfs

    log_info "========================================"
    log_info "  Root Filesystem Build Complete!"
    log_info "========================================"
    log_info "SquashFS: $SQUASHFS_IMAGE"
}

main "$@"
