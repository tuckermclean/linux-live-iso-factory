#!/bin/bash
#
# extract-packages.sh - Extract binary packages to sysroot
#
# Finds all .gpkg.tar (or .tbz2) files in the packages directory
# and extracts their contents to the output sysroot.

set -e

CROSS_TARGET="${CROSS_TARGET:-i486-linux-musl}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
BINPKG_DIR="${OUTPUT_DIR}/packages"
SYSROOT_DIR="${OUTPUT_DIR}/sysroot"

echo "==> Extracting binary packages to sysroot"
echo "    Packages: ${BINPKG_DIR}"
echo "    Sysroot: ${SYSROOT_DIR}"

# Create fresh sysroot
rm -rf "${SYSROOT_DIR}"
mkdir -p "${SYSROOT_DIR}"

# Create standard directories
mkdir -p "${SYSROOT_DIR}"/{bin,sbin,usr/bin,usr/sbin,lib,usr/lib,etc}

# Find all binary packages
# Support both GPKG (.gpkg.tar) and legacy TBZ2 (.tbz2) formats
GPKG_FILES=$(find "${BINPKG_DIR}" -name "*.gpkg.tar" -type f 2>/dev/null || true)
TBZ2_FILES=$(find "${BINPKG_DIR}" -name "*.tbz2" -type f 2>/dev/null || true)

TOTAL_GPKG=$(echo "${GPKG_FILES}" | grep -c . 2>/dev/null || true)
TOTAL_TBZ2=$(echo "${TBZ2_FILES}" | grep -c . 2>/dev/null || true)
TOTAL_GPKG=${TOTAL_GPKG:-0}
TOTAL_TBZ2=${TOTAL_TBZ2:-0}

echo "==> Found ${TOTAL_GPKG} GPKG packages, ${TOTAL_TBZ2} TBZ2 packages"

if [ "${TOTAL_GPKG}" -eq 0 ] && [ "${TOTAL_TBZ2}" -eq 0 ]; then
    echo "WARNING: No binary packages found in ${BINPKG_DIR}"
    exit 0
fi

# Temporary extraction directory
TMPDIR=$(mktemp -d)
trap "rm -rf ${TMPDIR}" EXIT

# Extract GPKG format packages
# GPKG structure: outer tar containing image.tar.xz (the actual files)
for pkg in ${GPKG_FILES}; do
    [ -z "${pkg}" ] && continue

    PKG_NAME=$(basename "${pkg}" .gpkg.tar)
    echo "  Extracting: ${PKG_NAME}"

    # Extract outer tar
    tar -xf "${pkg}" -C "${TMPDIR}"

    # Find and extract the image tarball
    IMAGE_TAR=$(find "${TMPDIR}" -name "image.tar*" -type f | head -1)
    if [ -n "${IMAGE_TAR}" ]; then
        tar -xf "${IMAGE_TAR}" -C "${SYSROOT_DIR}"
    else
        echo "    WARNING: No image.tar found in ${PKG_NAME}"
    fi

    # Clean up temp files
    rm -rf "${TMPDIR}"/*
done

# Extract TBZ2 format packages (legacy format)
for pkg in ${TBZ2_FILES}; do
    [ -z "${pkg}" ] && continue

    PKG_NAME=$(basename "${pkg}" .tbz2)
    echo "  Extracting: ${PKG_NAME}"

    # TBZ2 is a tar.bz2 containing the files directly
    tar -xjf "${pkg}" -C "${SYSROOT_DIR}"
done

echo "==> Post-processing sysroot..."

# Strip binaries to reduce size
echo "  Stripping binaries..."
find "${SYSROOT_DIR}" -type f -executable \( -name "*" ! -name "*.sh" \) -print0 2>/dev/null | \
    xargs -0 -r strip --strip-all 2>/dev/null || true

find "${SYSROOT_DIR}" -name "*.a" -print0 2>/dev/null | \
    xargs -0 -r strip --strip-debug 2>/dev/null || true

# Remove documentation (we specified nodoc but just in case)
echo "  Removing documentation..."
rm -rf "${SYSROOT_DIR}"/usr/share/{doc,man,info,gtk-doc} 2>/dev/null || true
rm -rf "${SYSROOT_DIR}"/usr/share/locale 2>/dev/null || true

# Remove development files (not needed for runtime)
echo "  Removing development files..."
rm -rf "${SYSROOT_DIR}"/usr/include 2>/dev/null || true
rm -rf "${SYSROOT_DIR}"/usr/lib/pkgconfig 2>/dev/null || true
find "${SYSROOT_DIR}" -name "*.la" -delete 2>/dev/null || true

# Flatten usr/bin and usr/sbin to bin and sbin for minimal rootfs
echo "  Flattening directory structure..."
if [ -d "${SYSROOT_DIR}/usr/bin" ]; then
    cp -a "${SYSROOT_DIR}/usr/bin"/* "${SYSROOT_DIR}/bin/" 2>/dev/null || true
fi
if [ -d "${SYSROOT_DIR}/usr/sbin" ]; then
    cp -a "${SYSROOT_DIR}/usr/sbin"/* "${SYSROOT_DIR}/sbin/" 2>/dev/null || true
fi

# Show results
echo ""
echo "==> Sysroot contents:"
find "${SYSROOT_DIR}" -type f -executable -name "*" 2>/dev/null | head -20

TOTAL_SIZE=$(du -sh "${SYSROOT_DIR}" | cut -f1)
TOTAL_FILES=$(find "${SYSROOT_DIR}" -type f | wc -l)
echo ""
echo "==> Extraction complete"
echo "    Total size: ${TOTAL_SIZE}"
echo "    Total files: ${TOTAL_FILES}"
echo "    Ready for integration with main rootfs"
