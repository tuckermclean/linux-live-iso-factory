#!/bin/bash
#
# build-initrd.sh - Create initramfs for The Monolith
#
# This script creates a minimal initramfs (initial RAM filesystem) that:
# - Provides early userspace with BusyBox
# - Mounts essential filesystems (/proc, /sys, /dev)
# - Parses root= kernel parameter
# - Pivots to the real root filesystem
#
# The initramfs is compressed with XZ for minimal size (important for
# floppy-era machines and slow CD-ROM drives).

set -eo pipefail

# Configuration
INITRD_DIR="${INITRD_DIR:-/initrd}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
ROOTFS_SKELETON="/rootfs"

# Input files — busybox is cross-compiled by portage into the sysroot
SYSROOT="/usr/${CROSS_TARGET:-i486-linux-musl}"
BUSYBOX_BIN="${OUTPUT_DIR}/sysroot/bin/busybox"

# Output file
INITRD_IMAGE="${OUTPUT_DIR}/themonolith-${BUILD_VERSION}.initrd"

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
    log_error "Run 'make build-packages' first"
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

# Install the module loader: kmod, NOT busybox.
#
# Gentoo's busybox drops the modutils applets (modprobe/insmod/...) in favor of
# sys-apps/kmod regardless of savedconfig, so the initramfs busybox has no
# modprobe. kmod is the canonical loader anyway: it reads the exact
# modules.dep/modules.alias that depmod (also kmod) writes, and resolves
# modaliases + dependencies natively. It MUST be statically linked — the
# initramfs has no shared libraries or dynamic loader — so verify that here
# and fail the build loudly rather than dropping to a rescue shell at boot.
# A static ELF has no PT_INTERP (program interpreter) segment. readelf reads the
# ELF header arch-independently, so it checks the i486 kmod correctly on the
# x86_64 build host; fall back to `file`, and if neither exists, proceed (a
# dynamic kmod would then fail at boot, which the serial log would show).
is_static_elf() {
    if command -v readelf >/dev/null 2>&1; then
        ! readelf -l "$1" 2>/dev/null | grep -q 'INTERP'
    elif command -v file >/dev/null 2>&1; then
        file "$1" | grep -q 'statically linked'
    else
        log_warn "no readelf/file to verify kmod is static; trusting the build"
        return 0
    fi
}
KMOD_BIN="${OUTPUT_DIR}/sysroot/bin/kmod"
[ -x "$KMOD_BIN" ] || KMOD_BIN="${OUTPUT_DIR}/sysroot/usr/bin/kmod"
if [ -x "$KMOD_BIN" ]; then
    if is_static_elf "$KMOD_BIN"; then
        log_info "Installing kmod module loader (static)..."
        cp "$KMOD_BIN" "${INITRD_DIR}/bin/kmod"
        chmod +x "${INITRD_DIR}/bin/kmod"
        # kmod dispatches on argv[0]; symlink the tools init/rescue may use.
        for tool in modprobe depmod insmod rmmod lsmod modinfo; do
            ln -sf kmod "${INITRD_DIR}/bin/${tool}"
        done
        ls -l "${INITRD_DIR}/bin/kmod" "${INITRD_DIR}/bin/modprobe"
    else
        log_error "kmod at $KMOD_BIN is dynamically linked — it cannot run in the"
        log_error "initramfs (no ld-musl / shared libs there). ELF details:"
        readelf -l "$KMOD_BIN" 2>/dev/null | grep -A1 'INTERP' || file "$KMOD_BIN" || true
        exit 1
    fi
else
    log_error "kmod not found in sysroot (looked in bin/ and usr/bin/)."
    log_error "The initramfs cannot load Tier-1 boot-media drivers without it."
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

# ── Tier-1 boot-media drivers ───────────────────────────────────────────────
# Copy the loadable storage drivers (plus their dependency closure) that let the
# initramfs reach the boot device on hardware where the controller isn't Tier-0
# built-in. See configs/initrd-modules.txt and docs/kernel-tiers.md. rootfs/init
# coldplugs them by modalias before searching for rootfs.squashfs.
MODULE_MANIFEST="${CONFIGS_DIR:-/configs}/initrd-modules.txt"
MODULES_SRC_BASE="${OUTPUT_DIR}/sysroot/lib/modules"
if [ -f "$MODULE_MANIFEST" ] && [ -d "$MODULES_SRC_BASE" ]; then
    KVER=$(ls -1 "$MODULES_SRC_BASE" | head -1)
    MODSRC="${MODULES_SRC_BASE}/${KVER}"
    MODDEST="${INITRD_DIR}/lib/modules/${KVER}"
    log_info "Installing Tier-1 boot-media modules (kernel ${KVER})..."
    mkdir -p "$MODDEST"
    # depmod needs the builtin lists so it knows deps like usbcore/libata/scsi_mod
    # are compiled in (Tier 0) and must not be flagged as missing modules.
    for f in modules.builtin modules.builtin.modinfo modules.order; do
        [ -f "${MODSRC}/${f}" ] && cp "${MODSRC}/${f}" "${MODDEST}/${f}"
    done
    # Resolve each manifest module to its full dependency closure from
    # modules.dep and copy every .ko, preserving the relative path layout.
    python3 - "$MODULE_MANIFEST" "$MODSRC" "$MODDEST" <<'PYEOF'
import os, shutil, sys
manifest, src, dest = sys.argv[1], sys.argv[2], sys.argv[3]

# Parse modules.dep: "relpath/mod.ko: dep1.ko dep2.ko ..."  (deps are relpaths).
deps, bybase = {}, {}
with open(os.path.join(src, "modules.dep")) as f:
    for line in f:
        line = line.strip()
        if not line or ":" not in line:
            continue
        target, _, rest = line.partition(":")
        target = target.strip()
        deps[target] = rest.split()
        base = os.path.basename(target)
        base = base[:-3] if base.endswith(".ko") else base
        bybase[base.replace("-", "_")] = target

wanted = []
with open(manifest) as f:
    for ln in f:
        ln = ln.strip()
        if ln and not ln.startswith("#"):
            wanted.append(ln.replace("-", "_"))

closure, missing = set(), []
def add(rel):
    if rel in closure:
        return
    closure.add(rel)
    for d in deps.get(rel, []):
        add(d)

for name in wanted:
    rel = bybase.get(name)
    if rel is None:
        missing.append(name)
    else:
        add(rel)

copied = 0
for rel in sorted(closure):
    s, d = os.path.join(src, rel), os.path.join(dest, rel)
    if not os.path.exists(s):
        missing.append(rel); continue
    os.makedirs(os.path.dirname(d), exist_ok=True)
    shutil.copy2(s, d)
    copied += 1

print(f"  copied {copied} module(s) ({len(wanted)} requested + dependency closure)")
if missing:
    # Not fatal — a driver may have been dropped by olddefconfig or is built-in.
    # Log loudly so a silent coverage gap is impossible.
    print("  WARNING: requested but not bundled (not built as a module — check kernel.config):")
    for m in sorted(set(missing)):
        print(f"    - {m}")
PYEOF
    # Regenerate modules.dep/alias/etc rooted at the initramfs so busybox modprobe
    # and rootfs/init's modalias coldplug resolve against exactly what we bundled.
    depmod -b "${INITRD_DIR}" "${KVER}"
    # Diagnostic: rootfs/init's modalias coldplug loads present controllers by
    # resolving each device's modalias against modules.alias. If this shows few
    # or zero `pci:` aliases, coldplug can't work and every machine falls back to
    # force-loading the whole manifest (still boots, but not RAM-optimal).
    if [ -f "${MODDEST}/modules.alias" ]; then
        log_info "modules.alias: $(wc -l < "${MODDEST}/modules.alias") lines, $(grep -c '^alias pci:' "${MODDEST}/modules.alias" 2>/dev/null || echo 0) pci: aliases"
    else
        log_warn "modules.alias NOT generated by depmod — coldplug will match nothing"
    fi
    # Ship the manifest so rootfs/init can also load it explicitly as a fallback.
    cp "$MODULE_MANIFEST" "${INITRD_DIR}/etc/initrd-modules"
    MOD_COUNT=$(find "$MODDEST" -name '*.ko' 2>/dev/null | wc -l)
    log_info "Bundled ${MOD_COUNT} kernel module(s) into the initramfs"
else
    log_warn "No module manifest or module tree found — initramfs will carry no storage drivers"
    log_warn "  manifest: $MODULE_MANIFEST   modules: $MODULES_SRC_BASE"
fi

# Show initrd contents for debugging. `|| true` because `set -o pipefail` +
# `head` closing the pipe early makes `find` exit 141 (SIGPIPE) once the tree is
# large enough to overflow the pipe buffer — now that the initrd carries the
# Tier-1 module set, it is. A debug listing must never abort the build.
log_info "Initramfs contents:"
find "${INITRD_DIR}" -type f -o -type l | head -50 || true
echo "..."

# Calculate uncompressed size
UNCOMPRESSED_SIZE=$(du -sk "${INITRD_DIR}" | cut -f1)
log_info "Uncompressed initramfs size: ${UNCOMPRESSED_SIZE} KB"

# Create the cpio archive and compress with GZIP, not XZ (kernel has
# CONFIG_RD_GZIP=y). This is a deliberate RAM trade for low-memory machines:
# `xz -6` needs an ~8 MB decompression dictionary that the kernel must allocate
# during early boot — on a 16 MB Pentium that can be the difference between
# booting and OOMing — whereas gzip's decompression window is 32 KB. The payload
# is only ~3 MB, so xz's better ratio saves a few hundred KB of disc (irrelevant
# on a CD/USB) at the cost of ~8 MB of peak boot RAM (decisive). Disc space is
# cheap; a Pentium's RAM is not.
# Reproducibility:
#   1. Normalize all file timestamps to SOURCE_DATE_EPOCH before archiving so
#      the cpio entries don't embed the live build time.
#   2. Sort the find output so the archive member order is deterministic
#      (find visits directories in filesystem order, which varies by run).
#   3. `gzip -n` omits the mtime/filename from the gzip header (also for repro).
# Symlinks are excluded from touch because touch -h support varies and the
# kernel initramfs extracts them correctly regardless of their mtime.
log_info "Creating compressed initramfs image..."
cd "${INITRD_DIR}"
find . -not -type l -exec touch -d "@${SOURCE_DATE_EPOCH:-0}" {} +
find . -print0 | LC_ALL=C sort -z | cpio --null -o -H newc | gzip -9 -n > "${INITRD_IMAGE}"

# Show final size
COMPRESSED_SIZE=$(stat -c%s "${INITRD_IMAGE}")
COMPRESSED_SIZE_KB=$((COMPRESSED_SIZE / 1024))
log_info "Compressed initramfs size: ${COMPRESSED_SIZE_KB} KB"
log_info "Compression ratio: $(echo "scale=1; ${UNCOMPRESSED_SIZE} / ${COMPRESSED_SIZE_KB}" | bc)x"

log_info "Initramfs created at ${INITRD_IMAGE}"
