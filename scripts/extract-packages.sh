#!/bin/bash
#
# extract-packages.sh - Copy live sysroot to output sysroot
#
# Uses the live sysroot saved by build-packages.sh rather than extracting
# binary packages directly. The live sysroot is the ground truth: it contains
# everything installed by emerge including files created by pkg_postinst (which
# are not present in binary packages).

set -e

CROSS_TARGET="${CROSS_TARGET:-i486-linux-musl}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
LIVE_SYSROOT_DIR="${OUTPUT_DIR}/live-sysroot"
SYSROOT_DIR="${OUTPUT_DIR}/sysroot"

echo "==> Copying live sysroot to ${SYSROOT_DIR}"
echo "    Source: ${LIVE_SYSROOT_DIR}"

if [ ! -d "${LIVE_SYSROOT_DIR}" ] || [ -z "$(ls -A "${LIVE_SYSROOT_DIR}" 2>/dev/null)" ]; then
    echo "ERROR: Live sysroot not found at ${LIVE_SYSROOT_DIR}"
    echo "Run 'make build-packages' first."
    exit 1
fi

# Create fresh sysroot
rm -rf "${SYSROOT_DIR}"
mkdir -p "${SYSROOT_DIR}"

rsync -a "${LIVE_SYSROOT_DIR}/" "${SYSROOT_DIR}/"

echo "==> Post-processing sysroot..."

# Strip binaries to reduce squashfs size
echo "  Stripping binaries..."
find "${SYSROOT_DIR}" -type f -executable \( -name "*" ! -name "*.sh" \) -print0 2>/dev/null | \
    xargs -0 -r strip --strip-all 2>/dev/null || true

find "${SYSROOT_DIR}" -name "*.a" -print0 2>/dev/null | \
    xargs -0 -r strip --strip-debug 2>/dev/null || true

# Fix the musl dynamic linker. The crossdev sysroot installs it as a symlink
# pointing to an absolute crossdev path (/usr/i486-linux-musl/usr/lib/libc.so)
# which is valid in the build container but dangling on the live system.
# Replace it with the actual binary so it resolves correctly at runtime.
# NOTE: several packages ignore USE=static and build as dynamic PIE binaries.
# This is a known gap - see RELEASE-READINESS.md. Proper static builds are a
# future project; for now we ship the musl linker so the system boots.
echo "  Installing musl dynamic linker..."
MUSL_LIBC="/usr/${CROSS_TARGET}/usr/lib/libc.so"
if [ -f "${MUSL_LIBC}" ]; then
    rm -f "${SYSROOT_DIR}/lib/ld-musl-i386.so.1"
    cp "${MUSL_LIBC}" "${SYSROOT_DIR}/lib/ld-musl-i386.so.1"
else
    echo "  WARNING: musl libc not found at ${MUSL_LIBC}"
    echo "  Dynamically-linked binaries will fail to execute at runtime!"
fi

# Decompress bzip2-compressed man pages.
# Gentoo installs man pages as .bz2; mandoc is built without libbz2 support
# and outputs raw bzip2 bytes instead of decompressing them.
echo "  Decompressing bzip2 man pages..."
find "${SYSROOT_DIR}/usr/share/man" -name "*.bz2" -print0 2>/dev/null | \
    xargs -0 -r bunzip2 2>/dev/null || true


TOTAL_SIZE=$(du -sh "${SYSROOT_DIR}" | cut -f1)
TOTAL_FILES=$(find "${SYSROOT_DIR}" -type f | wc -l)
echo ""
echo "==> Extraction complete"
echo "    Total size: ${TOTAL_SIZE}"
echo "    Total files: ${TOTAL_FILES}"
echo "    Ready for integration with main rootfs"
