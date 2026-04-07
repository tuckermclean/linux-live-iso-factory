#!/bin/bash
#
# extract-packages.sh - Install pre-built packages into the live sysroot
#
# Installs binary packages (built by build-packages.sh) into the cross-compilation
# sysroot using emerge --usepkgonly. pkg_preinst and pkg_postinst hooks run normally.
# Binaries are already stripped (FEATURES=strip ran during build-packages.sh).
# The resulting sysroot is copied to output/sysroot/ for rootfs assembly.

set -o pipefail

CROSS_TARGET="${CROSS_TARGET:-i486-linux-musl}"
CONFIGS_DIR="${CONFIGS_DIR:-/configs}"
PORTAGE_DIR="${CONFIGS_DIR}/portage"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"

export JOBS="${JOBS:-$(nproc)}"
export LOAD_AVG="${LOAD_AVG:-$(nproc)}"

WORLD_FILE="${PORTAGE_DIR}/world"
VERSIONS_FILE="${PORTAGE_DIR}/versions.lock"
SYSROOT_DIR="${OUTPUT_DIR}/sysroot"
BINPKG_DIR="${OUTPUT_DIR}/packages"

# Sync runtime-mounted configs into the sysroot's portage directory.
# Same sync as build-packages.sh — required so emerge --usepkgonly sees the
# same USE flags, masks, and bashrc hooks as the build step did.
SYSROOT_PORTAGE="/usr/${CROSS_TARGET}/etc/portage"
if [ -d "${PORTAGE_DIR}" ] && [ -d "${SYSROOT_PORTAGE}" ]; then
    echo "==> Syncing portage configs to ${SYSROOT_PORTAGE}"
    cp "${PORTAGE_DIR}/make.conf" "${SYSROOT_PORTAGE}/make.conf" 2>/dev/null || true
    cp "${PORTAGE_DIR}/bashrc" "${SYSROOT_PORTAGE}/bashrc" 2>/dev/null || true
    for dir in package.use package.accept_keywords package.mask package.env env savedconfig; do
        if [ -d "${PORTAGE_DIR}/${dir}" ]; then
            mkdir -p "${SYSROOT_PORTAGE}/${dir}"
            cp -r "${PORTAGE_DIR}/${dir}"/* "${SYSROOT_PORTAGE}/${dir}/" 2>/dev/null || true
        fi
    done
    mkdir -p "${SYSROOT_PORTAGE}/repos.conf"
    printf '[monolith]\nlocation = /configs/overlay\npriority = 20\nmasters = gentoo\nauto-sync = no\n' \
        > "${SYSROOT_PORTAGE}/repos.conf/monolith.conf"
fi

# Ensure groups required by game package preinst/postinst phases exist on the host.
grep -q "^games:"    /etc/group || echo "games:x:35:"    >> /etc/group
grep -q "^gamestat:" /etc/group || echo "gamestat:x:36:" >> /etc/group

# Regenerate binpkg index so emerge can find all packages in PKGDIR.
echo "==> Regenerating binpkg index"
PKGDIR="${BINPKG_DIR}" emaint binhost --fix

# Read packages + version pins from world file (same logic as build-packages.sh)
if [ ! -f "${WORLD_FILE}" ]; then
    echo "ERROR: World file not found: ${WORLD_FILE}"
    exit 1
fi

get_pinned_version() {
    local pkg="$1"
    if [ -f "${VERSIONS_FILE}" ]; then
        grep "^${pkg}:" "${VERSIONS_FILE}" 2>/dev/null | cut -d: -f2 | head -1
    fi
}

mapfile -t PACKAGES < <(grep -v '^#' "${WORLD_FILE}" | grep -v '^$')

ATOMS=()
for pkg in "${PACKAGES[@]}"; do
    VERSION=$(get_pinned_version "${pkg}")
    if [ -n "${VERSION}" ]; then
        ATOMS+=("=${pkg}-${VERSION}")
    else
        ATOMS+=("${pkg}")
    fi
done

echo "==> Installing ${#ATOMS[@]} packages from binpkgs into /usr/${CROSS_TARGET}"

EMERGE_CMD="${CROSS_TARGET}-emerge"
unset BUILD_DIR

${EMERGE_CMD} \
    --jobs=${JOBS} \
    --load-average=${LOAD_AVG} \
    --keep-going \
    --usepkgonly \
    --verbose \
    "${ATOMS[@]}"

echo ""
echo "==> Populating ${SYSROOT_DIR} from live sysroot"
rm -rf "${SYSROOT_DIR}"
mkdir -p "${SYSROOT_DIR}"
# Exclude crossdev build infrastructure — these are toolchain inputs, not runtime content.
# Keep this list in sync with build-packages.sh.
rsync -a \
    --exclude='/usr/include/' \
    --exclude='/usr/i486-linux-musl/' \
    --exclude='/usr/bin/i486-linux-musl-*' \
    --exclude='/etc/portage/' \
    --exclude='/usr/lib/pkgconfig/' \
    --exclude='/usr/lib/libc.a' \
    --exclude='/usr/lib/libm.a' \
    --exclude='/usr/lib/libpthread.a' \
    --exclude='/usr/lib/libdl.a' \
    --exclude='/usr/lib/librt.a' \
    --exclude='/usr/lib/libresolv.a' \
    --exclude='/usr/lib/libutil.a' \
    --exclude='/usr/lib/libxnet.a' \
    --exclude='/usr/lib/libcrypt.a' \
    --exclude='/usr/lib/crt1.o' \
    --exclude='/usr/lib/Scrt1.o' \
    --exclude='/usr/lib/rcrt1.o' \
    --exclude='/usr/lib/crti.o' \
    --exclude='/usr/lib/crtn.o' \
    --exclude='/lib/libssp_nonshared.a' \
    "/usr/${CROSS_TARGET}/" "${SYSROOT_DIR}/"

# Fix the musl dynamic linker. The crossdev sysroot installs it as a symlink
# pointing to an absolute crossdev path (/usr/i486-linux-musl/usr/lib/libc.so)
# which is dangling on the live system. Replace with the actual binary.
echo "==> Installing musl dynamic linker..."
MUSL_LIBC="/usr/${CROSS_TARGET}/usr/lib/libc.so"
if [ -f "${MUSL_LIBC}" ]; then
    rm -f "${SYSROOT_DIR}/lib/ld-musl-i386.so.1"
    cp "${MUSL_LIBC}" "${SYSROOT_DIR}/lib/ld-musl-i386.so.1"
else
    echo "WARNING: musl libc not found at ${MUSL_LIBC}"
    echo "  Dynamically-linked binaries will fail to execute at runtime!"
fi

# Decompress bzip2-compressed man pages.
# Gentoo installs man pages as .bz2; mandoc is built without libbz2 support.
echo "==> Decompressing bzip2 man pages..."
find "${SYSROOT_DIR}/usr/share/man" -name "*.bz2" -print0 2>/dev/null | \
    xargs -0 -r bunzip2 2>/dev/null || true

TOTAL_SIZE=$(du -sh "${SYSROOT_DIR}" | cut -f1)
TOTAL_FILES=$(find "${SYSROOT_DIR}" -type f | wc -l)
echo ""
echo "==> Install complete"
echo "    Sysroot: ${SYSROOT_DIR}"
echo "    Total size: ${TOTAL_SIZE}"
echo "    Total files: ${TOTAL_FILES}"
