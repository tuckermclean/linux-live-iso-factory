#!/bin/bash
#
# build-rootfs.sh - Build the SquashFS root filesystem
#
# This script creates a full root filesystem with:
# - GNU coreutils, util-linux, findutils, grep, sed, gawk, tar, procps
# - sysvinit (PID 1)
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

# Output
SQUASHFS_IMAGE="${OUTPUT_DIR}/themonolith-${BUILD_VERSION}.squashfs"

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
# Create the root filesystem structure
#
create_rootfs() {
    log_info "Creating root filesystem structure..."

    rm -rf "$ROOTFS_DIR"
    mkdir -p "$ROOTFS_DIR"/{bin,sbin,usr/bin,usr/sbin,lib,usr/lib}
    mkdir -p "$ROOTFS_DIR"/{etc,home,root,tmp,var,proc,sys,dev,mnt,opt,run}
    mkdir -p "$ROOTFS_DIR"/var/{log,tmp,spool,cache}
    mkdir -p "$ROOTFS_DIR"/etc/{init.d,network}
    # /var/run and /var/lock live on the tmpfs mounted at /run so they're
    # writable even though the squashfs base is read-only.
    ln -sf /run     "$ROOTFS_DIR/var/run"
    ln -sf /run/lock "$ROOTFS_DIR/var/lock"

    # Set permissions
    chmod 1777 "$ROOTFS_DIR"/tmp
    chmod 1777 "$ROOTFS_DIR"/var/tmp
    chmod 700 "$ROOTFS_DIR"/root

    log_info "Root filesystem structure created"
}

#
# Install Gentoo sysroot packages
#
install_sysroot() {
    local sysroot="${OUTPUT_DIR}/sysroot"
    if [ -d "$sysroot" ] && [ "$(ls -A "$sysroot" 2>/dev/null)" ]; then
        log_info "Installing Gentoo sysroot packages..."
        rsync -a "$sysroot/" "$ROOTFS_DIR/"
        local sysroot_files=$(find "$sysroot" -type f | wc -l)
        log_info "Sysroot overlay applied (${sysroot_files} files)"

        # Fix terminfo case collision caused by Windows/NTFS case-insensitivity.
        # The terminfo database uses both uppercase dirs (L/Linux_console,
        # A/Apple_Terminal) and lowercase dirs (l/linux, a/ansi). On NTFS these
        # silently collapse into one directory under the uppercase name, so the
        # squashfs ends up with L/ but no l/, and ncurses can't find l/linux.
        # Create lowercase symlinks for any uppercase-only terminfo subdirs so
        # that e.g. l -> L makes l/linux reachable. On a native Linux build the
        # lowercase dirs already exist so this loop is a no-op.
        local tdir="$ROOTFS_DIR/usr/share/terminfo"
        if [ -d "$tdir" ]; then
            for dir in "$tdir"/[A-Z]; do
                [ -d "$dir" ] || continue
                local lower
                lower=$(basename "$dir" | tr 'A-Z' 'a-z')
                [ -e "$tdir/$lower" ] || ln -s "$(basename "$dir")" "$tdir/$lower"
            done
        fi

        # Copy bash skel files to root home (sourced by login/subshells)
        cp -a "$ROOTFS_DIR"/etc/skel/.bash* "$ROOTFS_DIR"/root/ 2>/dev/null || true
    else
        log_error "No sysroot found at ${sysroot}"
        log_error "Run 'make build-packages && make extract' first"
        exit 1
    fi
}

#
# Create /etc configuration files
#
create_etc_files() {
    log_info "Creating /etc configuration files..."

    # /etc/passwd
    cat > "$ROOTFS_DIR/etc/passwd" << 'EOF'
root:x:0:0:root:/root:/bin/bash
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
    echo "monolith" > "$ROOTFS_DIR/etc/hostname"

    # /etc/motd - ANSI art banner (strip 128-byte SAUCE record from .ans file)
    head -c -128 /configs/themonolith.ans > "$ROOTFS_DIR/etc/motd"

    # /etc/issue - shown before login prompt
    printf 'The Monolith - \\l\n' > "$ROOTFS_DIR/etc/issue"

    # /etc/resolv.conf (empty, populated by DHCP)
    touch "$ROOTFS_DIR/etc/resolv.conf"

    # /etc/profile
    cat > "$ROOTFS_DIR/etc/profile" << 'EOF'
# /etc/profile - system-wide shell initialization

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export TERM="${TERM:-linux}"
export PAGER="less"
export EDITOR="vi"

# Source profile.d drop-ins
if [ -d /etc/profile.d ]; then
    for f in /etc/profile.d/*.sh; do
        [ -f "$f" ] && . "$f"
    done
fi

# Source Gentoo bash configuration (colors, prompt, aliases)
[ -f /etc/bash/bashrc ] && . /etc/bash/bashrc

# Source local profile if it exists
[ -f /etc/profile.local ] && . /etc/profile.local

PS1='\[\e[90m\]■\[\e[0m\] \[\e[92m\]tHE m0n0LiTH\[\e[0m\] \[\e[96m\]\w\[\e[91m\]\$\[\e[0m\] '
export PS1
EOF

    # /etc/securetty - ttys on which root is allowed to log in
    cat > "$ROOTFS_DIR/etc/securetty" << 'EOF'
console
tty1
tty2
ttyS0
EOF

    # /etc/shells
    cat > "$ROOTFS_DIR/etc/shells" << 'EOF'
/bin/sh
/bin/bash
EOF

    # /etc/inittab for sysvinit
    cat > "$ROOTFS_DIR/etc/inittab" << 'EOF'
# /etc/inittab - sysvinit configuration

# Default runlevel
id:3:initdefault:

# System initialization
si::sysinit:/etc/init.d/rcS

# Virtual consoles - bypass login, exec bash directly
1:2345:respawn:/sbin/agetty -n -l /bin/bash --noclear 38400 tty1
2:2345:respawn:/sbin/agetty -n -l /bin/bash 38400 tty2

# Serial console - bypass login, exec bash directly
s0:2345:respawn:/sbin/agetty -n -l /bin/bash -L ttyS0 115200 vt100

# Ctrl-Alt-Del
ca:12345:ctrlaltdel:/sbin/reboot

# Shutdown
l0:0:wait:/etc/init.d/rcK
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
mount -t tmpfs -o nosuid,mode=755 tmpfs /run

# Create dirs/files expected under /run (= /var/run)
mkdir -p /run/lock
touch /run/utmp

# Set hostname
[ -f /etc/hostname ] && echo "$(cat /etc/hostname)" > /proc/sys/kernel/hostname

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
            dhcpcd -b "$iface"
        done
        ;;
    stop)
        echo "Stopping network..."
        for iface in /sys/class/net/eth* /sys/class/net/en*; do
            [ -e "$iface" ] || continue
            iface=$(basename "$iface")
            dhcpcd -k "$iface" 2>/dev/null || true
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

    # Dropbear SSH host key generation (runs before network)
    cat > "$ROOTFS_DIR/etc/init.d/S20keygen" << 'EOF'
#!/bin/sh
#
# S20keygen - Generate Dropbear SSH host keys if missing
#

case "$1" in
    start)
        mkdir -p /etc/dropbear
        if [ ! -f /etc/dropbear/dropbear_rsa_host_key ]; then
            echo "Generating RSA host key..."
            dropbearkey -t rsa -f /etc/dropbear/dropbear_rsa_host_key > /dev/null 2>&1
        fi
        if [ ! -f /etc/dropbear/dropbear_ecdsa_host_key ]; then
            echo "Generating ECDSA host key..."
            dropbearkey -t ecdsa -f /etc/dropbear/dropbear_ecdsa_host_key > /dev/null 2>&1
        fi
        ;;
esac

exit 0
EOF
    chmod 755 "$ROOTFS_DIR/etc/init.d/S20keygen"

    log_info "/etc configuration files created"
}

#
# Create the SquashFS image
#
create_squashfs() {
    log_info "Creating SquashFS image..."

    if [ -x "$ROOTFS_DIR/bin/bash" ] ; then
        rm -f "$ROOTFS_DIR/bin/sh"
	ln -s bash "$ROOTFS_DIR/bin/sh"
    fi

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

    create_rootfs
    install_sysroot
    create_etc_files
    create_squashfs

    log_info "========================================"
    log_info "  Root Filesystem Build Complete!"
    log_info "========================================"
    log_info "SquashFS: $SQUASHFS_IMAGE"
}

main "$@"
