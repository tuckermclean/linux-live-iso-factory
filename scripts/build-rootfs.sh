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

        # X core fonts: index the bitmap font dirs and reclaim `fixed` for
        # Terminus (GUI "Terminus by default" pass). The font ebuilds' own
        # fonts.dir generation runs in pkg_postinst via mkfontscale, which never
        # fires on a cross/ROOT install (the target sysroot has no mkfontscale),
        # AND the builder image can't currently be rebuilt to add a host
        # mkfontscale (its TOOLCHAIN_EPOCH portage snapshot was pruned upstream;
        # see the Dockerfile). So we index the fonts ourselves by reading each
        # PCF's own FONT property (scripts/pcf-fontname.py — an AUTHORITATIVE
        # XLFD straight from the file, not a guess) and writing fonts.dir. Then
        # ship our OWN alias dir mapping `fixed`/`variable`/bold/heading to
        # Terminus XLFDs; startx lists it FIRST in the server's -fp path so it
        # wins over font-misc-misc's fonts.alias (which claims `fixed` for the
        # classic 6x13 — font path order is the alias tiebreaker).
        local fontsroot="$ROOTFS_DIR/usr/share/fonts"
        local script_dir pcfname
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        pcfname="${script_dir}/pcf-fontname.py"
        if [ -d "$fontsroot" ] && [ -f "$pcfname" ]; then
            log_info "Indexing X bitmap fonts (PCF FONT property) + Terminus alias..."
            local fdir pcf xlfd n tmp
            for fdir in "$fontsroot"/terminus; do
                [ -d "$fdir" ] || continue
                tmp="$fdir/.fonts.dir.tmp"; : > "$tmp"; n=0
                for pcf in "$fdir"/*.pcf "$fdir"/*.pcf.gz; do
                    [ -f "$pcf" ] || continue
                    if xlfd="$(python3 "$pcfname" "$pcf" 2>/dev/null)" && [ -n "$xlfd" ]; then
                        printf '%s %s\n' "$(basename "$pcf")" "$xlfd" >> "$tmp"
                        n=$((n + 1))
                    else
                        log_warn "could not read FONT property from $pcf — skipping"
                    fi
                done
                { printf '%d\n' "$n"; cat "$tmp"; } > "$fdir/fonts.dir"
                rm -f "$tmp"
                log_info "  indexed ${n} font(s) into $(basename "$fdir")/fonts.dir"
            done

            local aliasdir="$fontsroot/monolith"
            mkdir -p "$aliasdir"
            local ter16="-xos4-terminus-medium-r-normal--16-160-72-72-c-80-iso10646-1"
            local ter16b="-xos4-terminus-bold-r-normal--16-160-72-72-c-80-iso10646-1"
            local ter32="-xos4-terminus-medium-r-normal--32-320-72-72-c-160-iso10646-1"
            {
                printf 'fixed\t\t%s\n'      "$ter16"
                printf 'variable\t%s\n'     "$ter16"
                printf 'fixed-bold\t%s\n'   "$ter16b"
                printf 'heading\t\t%s\n'    "$ter32"
            } > "$aliasdir/fonts.alias"
            # An alias-only dir still needs a fonts.dir (count 0) for the server's
            # FontFile FPE to accept it as a valid font directory.
            printf '0\n' > "$aliasdir/fonts.dir"

            # LANDMINE GUARD: the server refuses to start if `fixed` doesn't
            # resolve, and the alias is only as good as its XLFD strings. The
            # index above wrote the AUTHORITATIVE XLFDs (each PCF's own FONT
            # property) into terminus/fonts.dir — so verify every XLFD we alias
            # to actually appears there. A wrong foundry/size/registry string
            # then fails the BUILD, with the real XLFDs printed, not just the boot.
            local terdir="$fontsroot/terminus/fonts.dir"
            if [ ! -f "$terdir" ]; then
                log_error "terminus/fonts.dir was not generated ($terdir) — is terminus-font[pcf] installed?"
                exit 1
            fi
            for xlfd in "$ter16" "$ter16b" "$ter32"; do
                if ! grep -qF -- "$xlfd" "$terdir"; then
                    log_error "aliased Terminus XLFD absent from generated fonts.dir: $xlfd"
                    log_error "actual terminus/fonts.dir (correct the alias XLFDs to match these):"
                    cat "$terdir" >&2
                    exit 1
                fi
            done
            log_info "X fonts indexed; all aliased Terminus XLFDs verified present in fonts.dir"
        else
            log_warn "$fontsroot or $pcfname missing — X core fonts NOT indexed (GUI will fail to find 'fixed')"
        fi

        # Copy bash skel files to root home (sourced by login/subshells)
        cp -a "$ROOTFS_DIR"/etc/skel/.bash* "$ROOTFS_DIR"/root/ 2>/dev/null || true

        # agetty -l /bin/bash starts bash as a non-login interactive shell, so
        # /etc/profile is never auto-sourced and env vars like PAGER are unset.
        # Source /etc/profile from .bashrc with a guard to prevent double-loading
        # in real login shells (which already source /etc/profile before .bashrc).
        cat >> "$ROOTFS_DIR/root/.bashrc" << 'EOF'

# Source system environment for non-login shells (e.g. agetty auto-login)
[ -z "$_MONOLITH_ENV" ] && [ -f /etc/profile ] && . /etc/profile
EOF
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

    # /etc/monolith-release - baked-in build version for advisory check
    echo "${BUILD_VERSION:-unknown}" > "$ROOTFS_DIR/etc/monolith-release"

    # /etc/motd - ANSI art banner (strip 128-byte SAUCE record from .ans file)
    head -c -128 /configs/themonolith.ans > "$ROOTFS_DIR/etc/motd"
    printf 'tHE m0n0LiTH %s\n\n' "${BUILD_VERSION:-unknown}" >> "$ROOTFS_DIR/etc/motd"

    # /etc/issue - shown before login prompt on the TTY.
    # Root has no password (see /etc/shadow above) — intentional for a live
    # ISO, but called out explicitly here rather than left as a silent
    # default, so nobody boots this on a network they don't control assuming
    # it's protected.
    cat > "$ROOTFS_DIR/etc/issue" << EOF
The Monolith ${BUILD_VERSION:-unknown} - \\l

Root login has NO PASSWORD. This is intentional for a live/rescue ISO.
Set one with "passwd" before exposing this system, or its network
services (e.g. dropbear SSH, if started), to an untrusted network.

EOF

    # /etc/os-release - standard distro identification
    cat > "$ROOTFS_DIR/etc/os-release" << EOF
NAME="The Monolith"
VERSION="${BUILD_VERSION:-unknown}"
ID=themonolith
ID_LIKE=gentoo
PRETTY_NAME="The Monolith ${BUILD_VERSION:-unknown}"
VERSION_ID="${BUILD_VERSION:-unknown}"
BUILD_ID="${BUILD_VERSION:-unknown}"
ANSI_COLOR="1;32"
HOME_URL="https://themonolith.s3.us-west-2.amazonaws.com"
EOF

    # /etc/resolv.conf (empty, populated by DHCP)
    touch "$ROOTFS_DIR/etc/resolv.conf"

    # /etc/profile
    cat > "$ROOTFS_DIR/etc/profile" << 'EOF'
# /etc/profile - system-wide shell initialization

export _MONOLITH_ENV=1   # guard: prevents double-sourcing from .bashrc

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
EOF

    # /etc/profile.d/50-dropbear-hint.sh — dropbear SSH is installed but NOT
    # started at boot (deliberate for a live ISO). Show the user, on interactive
    # login, the one command to start it if they want remote access. The ECDSA
    # host key is generated at boot by /etc/init.d/S20keygen.
    #
    # Ordering contract (Task 6, hint hygiene — see the monolith-base
    # ebuild's src_install, profile.d section for the full statement):
    # ACTIONABLE-group, after 40-advisory.sh (security banner outranks a
    # convenience hint). Renamed from 10-dropbear-hint.sh in Task 6.
    #
    # /run-flag policy: this fires on EVERY login ON PURPOSE — it is a
    # security-posture reminder (sshd present but off, root has no
    # password) that is meant to repeat deliberately, not a one-shot
    # tip. Do NOT add a once-guard to it.
    mkdir -p "$ROOTFS_DIR/etc/profile.d"
    cat > "$ROOTFS_DIR/etc/profile.d/50-dropbear-hint.sh" << 'EOF'
# Interactive-shell hint: dropbear is available but not running by default.
# Prints on EVERY login ON PURPOSE (security-posture reminder, not a
# one-shot tip) — see the ordering contract in scripts/build-rootfs.sh
# above this heredoc. Do NOT add a once-per-boot guard here.
case "$-" in
    *i*)
        if command -v dropbear >/dev/null 2>&1 && \
           ! pgrep -x dropbear >/dev/null 2>&1; then
            printf '\nSSH server (dropbear) is installed but not running.\n'
            printf 'Start it with:  dropbear        # listen on port 22 (root has no password)\n\n'
        fi
        ;;
esac
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
/bin/dash
/bin/ash
/bin/bash
EOF

    # /etc/inittab for sysvinit
    cat > "$ROOTFS_DIR/etc/inittab" << 'EOF'
# /etc/inittab - sysvinit configuration

# Default runlevel
id:3:initdefault:

# System initialization
si::sysinit:/etc/init.d/rcS

# Virtual consoles - bypass login; lazy shell (bash only on first keypress,
# see /usr/sbin/monolith-console) so idle consoles keep no bash resident.
1:2345:respawn:/sbin/agetty -n -l /usr/sbin/monolith-console --noclear 38400 tty1
2:2345:respawn:/sbin/agetty -n -l /usr/sbin/monolith-console 38400 tty2

# Serial console - bypass login; same lazy shell as the VTs.
s0:2345:respawn:/sbin/agetty -n -l /usr/sbin/monolith-console -L ttyS0 115200 vt100

# Ctrl-Alt-Del
ca:12345:ctrlaltdel:/sbin/reboot

# Shutdown / reboot: sysvinit's halt, poweroff and reboot commands request a
# switch to runlevel 0 (halt/poweroff) or 6 (reboot) respectively. Both
# runlevels must run the same kill script — killall5, sync, unmount,
# remount-ro — or a `reboot` (runlevel 6) skips it while `halt`/`poweroff`
# (runlevel 0) don't.
l0:0:wait:/etc/init.d/rcK
l6:6:wait:/etc/init.d/rcK
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

# ── Load drivers for detected hardware (Tier 2 modules) ─────────────────────
# One coldplug pass: read every device's modalias and modprobe the match. On an
# ISA-era 486 this loads approximately nothing (few/no modalias-emitting devices);
# on PCI/modern machines the device tree self-assembles — NIC, mouse, sound, ...
# Modules live in the squashfs; zero RAM cost until a matching device exists.
# No udev, no daemon. Runs before S40network so a modular NIC is up for DHCP.
if command -v modprobe >/dev/null 2>&1 && [ -d "/lib/modules/$(uname -r)" ]; then
    find /sys -name modalias -exec sort -u {} + 2>/dev/null \
        | xargs -r modprobe -abq 2>/dev/null || true
fi

# Set hostname
[ -f /etc/hostname ] && echo "$(cat /etc/hostname)" > /proc/sys/kernel/hostname

# Console font: Terminus, if it's aboard (Monolith UX Pass Task 5, "the kid's
# font, everywhere"). Guarded on both setfont and the font file existing —
# --keep-going can silently drop sys-apps/kbd or media-fonts/terminus-font
# from a CI build (see MEMORY.md's w3m precedent) without failing the whole
# build, and this call must not care either way. ter-116n is 16px, normal
# weight, ISO-8859-1/Latin-1 (this disc's charset elsewhere — st's
# core-fonts "fixed", /etc/issue, etc.). setfont reads the .gz directly
# (media-fonts/terminus-font's own compressed install; sys-apps/kbd is
# built with USE=zlib specifically so this works, see package.use/static).
if command -v setfont >/dev/null 2>&1 && [ -f /usr/share/consolefonts/ter-116n.psf.gz ]; then
    setfont /usr/share/consolefonts/ter-116n.psf.gz 2>/dev/null || true
fi

# The mandoc whatis database (mandoc.db) is baked into the squashfs at BUILD
# time — see scripts/build-rootfs.sh, which runs makewhatis against the fully
# assembled rootfs right before mksquashfs. So apropos/whatis already work with
# zero boot cost and there is nothing to do here. This deliberately does NOT
# rebuild the db at boot: doing so OOM-killed makewhatis (~24MB) on the 64MB
# Gen1/BIOS config. `makewhatis` is still installed if the user adds pages.

# Run init scripts
echo ""
echo "  Starting services... Press Ctrl-C to cancel and drop to shell."
echo ""
trap 'echo ""; echo "  Startup cancelled. Dropping to shell..."; echo ""; exec /bin/sh' INT
for script in /etc/init.d/S*; do
    [ -x "$script" ] && "$script" start
done
trap - INT

echo "System initialization complete."
EOF
    chmod 755 "$ROOTFS_DIR/etc/init.d/rcS"

    # /etc/init.d/rcK - shutdown script
    cat > "$ROOTFS_DIR/etc/init.d/rcK" << 'EOF'
#!/bin/sh
# System shutdown script

echo "System shutting down..."

# Capture the target runlevel BEFORE unmounting — the `runlevel` command reads
# /run/utmp, which the unmount below removes. sysvinit exports RUNLEVEL to the
# l0/l6 wait actions; fall back to the runlevel command. 0 = halt/poweroff,
# 6 = reboot.
TARGET_RL="${RUNLEVEL:-$(runlevel 2>/dev/null | awk '{print $2}')}"

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

# Actually power off (ACPI S5) or reboot. Without this, sysvinit reaches the end
# of runlevel 0 and only halts the CPU — the machine (and QEMU under ACPI) never
# powers down, so shutdown hangs forever.
case "$TARGET_RL" in
    6) reboot -f ;;
    *) poweroff -f ;;
esac
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

    # monolith-net, monolith-router, monolith-console, /usr/bin/which, and the
    # guestbook.cgi fixture are installed by app-misc/monolith-base (Pillar 4;
    # see configs/overlay/app-misc/monolith-base) via the sysroot rsync in
    # install_sysroot() above — no hand-install needed here anymore.

    # /etc/init.d/S35netprobe - reach ISA NICs that can't announce themselves.
    # Runs AFTER rcS coldplug (which self-loads PCI/virtual NICs by modalias) and
    # BEFORE S40network (which DHCPs whatever interfaces exist). Only the SAFE,
    # self-identifying ISA path runs automatically; the blind io= sweep is opt-in
    # via `monolith-net probe`. See
    # configs/overlay/app-misc/monolith-base/files/monolith-net.
    cat > "$ROOTFS_DIR/etc/init.d/S35netprobe" << 'EOF'
#!/bin/sh
case "$1" in
    start) monolith-net autoprobe ;;
esac
exit 0
EOF
    chmod 755 "$ROOTFS_DIR/etc/init.d/S35netprobe"

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

    # /etc/init.d/S45monolith-time - THE CLOCK LANDMINE (Monolith UX Pass
    # Task 2). Runs after S40network (so "is an interface up" is answerable)
    # and before S50advisory (so a corrected clock helps advisory's own TLS
    # fetch). All the actual logic — deciding whether the clock is
    # demonstrably ignorant, and calling monolith-time if so — lives in
    # /usr/sbin/monolith-time-check (app-misc/monolith-base); this wrapper
    # only invokes it, mirroring S50advisory's split.
    cat > "$ROOTFS_DIR/etc/init.d/S45monolith-time" << 'EOF'
#!/bin/sh
# S45monolith-time - correct a demonstrably ignorant clock, quietly
case "$1" in
    start)
        /usr/sbin/monolith-time-check
        ;;
    stop|restart)
        ;;
    *)
        echo "Usage: $0 {start|stop|restart}"
        exit 1
        ;;
esac
exit 0
EOF
    chmod 755 "$ROOTFS_DIR/etc/init.d/S45monolith-time"

    # Dropbear SSH host key generation (runs before network)
    cat > "$ROOTFS_DIR/etc/init.d/S20keygen" << 'EOF'
#!/bin/sh
#
# S20keygen - Generate Dropbear SSH host key if missing
#

case "$1" in
    start)
        mkdir -p /etc/dropbear
        if [ ! -f /etc/dropbear/dropbear_ecdsa_host_key ]; then
            echo "Generating ECDSA host key..."
            dropbearkey -t ecdsa -f /etc/dropbear/dropbear_ecdsa_host_key > /dev/null 2>&1
        fi
        ;;
esac

exit 0
EOF
    chmod 755 "$ROOTFS_DIR/etc/init.d/S20keygen"

    # /etc/init.d/S30gpm - General Purpose Mouse daemon
    cat > "$ROOTFS_DIR/etc/init.d/S30gpm" << 'EOF'
#!/bin/sh
# S30gpm - Start gpm mouse daemon for console copy/paste.
# Probes PS/2+USB (/dev/input/mice) then serial COM1/COM2.
# Exits silently if no mouse device is found.

case "$1" in
    start)
        if [ -e /dev/input/mice ]; then
            gpm -m /dev/input/mice -t imps2
        elif [ -e /dev/ttyS0 ]; then
            gpm -m /dev/ttyS0 -t ms
        elif [ -e /dev/ttyS1 ]; then
            gpm -m /dev/ttyS1 -t ms
        fi
        ;;
    stop)
        gpm -k 2>/dev/null || true
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
    chmod 755 "$ROOTFS_DIR/etc/init.d/S30gpm"

    # /usr/sbin/monolith-advisory-check, /etc/profile.d/40-advisory.sh,
    # and /etc/bash/bashrc.d/99-monolith-square.bash are installed by
    # app-misc/monolith-base (Pillar 4; see
    # configs/overlay/app-misc/monolith-base) via the sysroot rsync in
    # install_sysroot() above.

    # /etc/init.d/S50advisory - runs after S40network to check for advisories
    cat > "$ROOTFS_DIR/etc/init.d/S50advisory" << 'EOF'
#!/bin/sh
# S50advisory - Check for security advisories after network is up
case "$1" in
    start)
        /usr/sbin/monolith-advisory-check
        ;;
    stop|restart)
        ;;
    *)
        echo "Usage: $0 {start|stop|restart}"
        exit 1
        ;;
esac
exit 0
EOF
    chmod 755 "$ROOTFS_DIR/etc/init.d/S50advisory"

    log_info "/etc configuration files created"
}

#
# Create the SquashFS image
#
create_squashfs() {
    log_info "Creating SquashFS image..."

    # Prefer dash for /bin/sh — lighter than bash, strictly POSIX
    if [ -x "$ROOTFS_DIR/bin/dash" ]; then
        rm -f "$ROOTFS_DIR/bin/sh"
        ln -s dash "$ROOTFS_DIR/bin/sh"
    elif [ -x "$ROOTFS_DIR/bin/bash" ]; then
        rm -f "$ROOTFS_DIR/bin/sh"
        ln -s bash "$ROOTFS_DIR/bin/sh"
    fi

    # mandoc falls back to 'more' when PAGER is unset; provide it as an alias for less
    if [ -x "$ROOTFS_DIR/usr/bin/less" ] && [ ! -e "$ROOTFS_DIR/usr/bin/more" ]; then
        ln -s less "$ROOTFS_DIR/usr/bin/more"
    fi

    # Calculate uncompressed size
    local size_kb=$(du -sk "$ROOTFS_DIR" | cut -f1)
    log_info "Uncompressed rootfs size: ${size_kb} KB"

    # Build the mandoc whatis database (mandoc.db) against the FINAL assembled
    # rootfs — after every package (incl. sys-apps/man-pages) is staged — so
    # apropos/whatis work out of the box with ZERO boot-time cost. makewhatis in
    # directory mode stores page paths RELATIVE to the manpath, so a db built
    # here at $ROOTFS_DIR/usr/share/man is valid at the live /usr/share/man. The
    # host makewhatis is used (the target one is an i486 binary; the db format is
    # arch-independent), and SOURCE_DATE_EPOCH later clamps the db and the pages
    # to the same mtime, satisfying mandoc's freshness check. The mandoc
    # pkg_postinst hook (configs/portage/bashrc) builds a db too, but that fires
    # before sys-apps/man-pages installs, so it is incomplete — this final pass
    # against the full tree supersedes it. Previously rcS rebuilt mandoc.db on
    # every boot, which OOM-killed makewhatis on the 64MB Gen1/BIOS config.
    if [ -d "$ROOTFS_DIR/usr/share/man" ] && [ -x /usr/sbin/makewhatis ]; then
        log_info "Baking mandoc whatis database (build-time)..."
        /usr/sbin/makewhatis "$ROOTFS_DIR/usr/share/man" \
            || log_warn "build-time makewhatis failed; apropos db may be incomplete"
    else
        log_warn "host makewhatis or man dir missing; whatis database not baked"
    fi

    # Create SquashFS with gzip compression (low memory for i486).
    # mksquashfs 4.5+ reads SOURCE_DATE_EPOCH from the environment automatically;
    # passing -all-time alongside it is an error on those versions.
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
# Audit for dynamically-linked binaries (informational — never fails the build)
#
run_static_audit() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local audit_script="${script_dir}/static-audit.sh"

    if [ -x "$audit_script" ]; then
        log_info "Running static-link audit..."
        # Runs against ROOTFS_DIR (already squashed into the image by this
        # point) and writes only to OUTPUT_DIR/reports — it cannot change
        # the SquashFS bytes or the attestation digest chain.
        "$audit_script" "$ROOTFS_DIR" || log_warn "static-audit.sh reported an issue (non-fatal)"
    else
        log_warn "static-audit.sh not found or not executable — skipping audit"
    fi
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
    run_static_audit

    log_info "========================================"
    log_info "  Root Filesystem Build Complete!"
    log_info "========================================"
    log_info "SquashFS: $SQUASHFS_IMAGE"
}

main "$@"
