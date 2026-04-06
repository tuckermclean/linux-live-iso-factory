#!/bin/bash
#
# build-packages.sh - Cross-compile packages from the world file
#
# Continues on failure, logging errors for later review.
# Supports --resume to skip already-built packages.

set -o pipefail

CROSS_TARGET="${CROSS_TARGET:-i486-linux-musl}"
CONFIGS_DIR="${CONFIGS_DIR:-/configs}"
PORTAGE_DIR="${CONFIGS_DIR}/portage"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"

# Parallelism settings (can be overridden via environment)
# Exported so Portage can use ${JOBS} in make.conf MAKEOPTS
export JOBS="${JOBS:-$(nproc)}"
export LOAD_AVG="${LOAD_AVG:-$(nproc)}"

WORLD_FILE="${PORTAGE_DIR}/world"
VERSIONS_FILE="${PORTAGE_DIR}/versions.lock"
LOGS_DIR="${OUTPUT_DIR}/logs"
BINPKG_DIR="${OUTPUT_DIR}/packages"
FAILED_FILE="${OUTPUT_DIR}/.failed-packages"
BUILT_FILE="${OUTPUT_DIR}/.built-packages"

# Parse arguments
RESUME=0
VERBOSE=0
while [[ $# -gt 0 ]]; do
    case $1 in
        --resume)
            RESUME=1
            shift
            ;;
        --verbose|-v)
            VERBOSE=1
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--resume] [--verbose]"
            exit 1
            ;;
    esac
done

# Create directories
mkdir -p "${LOGS_DIR}" "${BINPKG_DIR}"

# Sync runtime-mounted configs into the sysroot's portage directory.
# The crossdev emerge wrapper reads from /usr/${CROSS_TARGET}/etc/portage/
# (via PORTAGE_CONFIGROOT), but the runtime -v mount only updates
# /configs/portage/. Without this sync, config changes made after
# 'make build-image' (or mounted at runtime) would be invisible to emerge.
SYSROOT_PORTAGE="/usr/${CROSS_TARGET}/etc/portage"
if [ -d "${PORTAGE_DIR}" ] && [ -d "${SYSROOT_PORTAGE}" ]; then
    echo "==> Syncing configs from ${PORTAGE_DIR} to ${SYSROOT_PORTAGE}"
    cp "${PORTAGE_DIR}/make.conf" "${SYSROOT_PORTAGE}/make.conf" 2>/dev/null || true
    cp "${PORTAGE_DIR}/bashrc" "${SYSROOT_PORTAGE}/bashrc" 2>/dev/null || true
    for dir in package.use package.accept_keywords package.mask package.env env savedconfig; do
        if [ -d "${PORTAGE_DIR}/${dir}" ]; then
            mkdir -p "${SYSROOT_PORTAGE}/${dir}"
            cp -r "${PORTAGE_DIR}/${dir}"/* "${SYSROOT_PORTAGE}/${dir}/" 2>/dev/null || true
        fi
    done
    # Register the monolith overlay in the sysroot repos.conf so cross-emerge
    # can find ebuilds from /configs/overlay (bind-mounted at runtime).
    mkdir -p "${SYSROOT_PORTAGE}/repos.conf"
    printf '[monolith]\nlocation = /configs/overlay\npriority = 20\nmasters = gentoo\nauto-sync = no\n' \
        > "${SYSROOT_PORTAGE}/repos.conf/monolith.conf"
fi

# Ensure groups required by game package preinst phases exist on the BUILD HOST.
# The nethack ebuild calls fowners root:gamestat, which runs chown on the host
# during preinst — it needs the group in the host /etc/group, not the sysroot.
grep -q "^games:"    /etc/group || echo "games:x:35:"    >> /etc/group
grep -q "^gamestat:" /etc/group || echo "gamestat:x:36:" >> /etc/group

# Regenerate binpkg index so it matches whatever .gpkg.tar files actually
# exist on disk. Prevents "non-existent binary" errors after partial cleanup.
echo "==> Regenerating binpkg index"
PKGDIR="${BINPKG_DIR}" emaint binhost --fix

# Initialize tracking files
if [ $RESUME -eq 0 ]; then
    > "${FAILED_FILE}"
    > "${BUILT_FILE}"
fi

echo "==> Building packages for ${CROSS_TARGET}"
echo "    World file: ${WORLD_FILE}"
echo "    Logs: ${LOGS_DIR}"
echo "    Parallel jobs: ${JOBS}"
echo "    Load average limit: ${LOAD_AVG}"
echo "    Resume mode: $([ $RESUME -eq 1 ] && echo 'yes' || echo 'no')"
echo ""

# Verify toolchain exists
if ! command -v "${CROSS_TARGET}-gcc" &>/dev/null; then
    echo "ERROR: Toolchain not found. Rebuild the image with 'make build-image'."
    exit 1
fi

# Read packages from world file
if [ ! -f "${WORLD_FILE}" ]; then
    echo "ERROR: World file not found: ${WORLD_FILE}"
    exit 1
fi

# Parse world file, skip comments and blank lines
mapfile -t PACKAGES < <(grep -v '^#' "${WORLD_FILE}" | grep -v '^$')

if [ ${#PACKAGES[@]} -eq 0 ]; then
    echo "WARNING: No packages in world file"
    exit 0
fi

echo "==> Found ${#PACKAGES[@]} packages to build"

# Function to get pinned version for a package
get_pinned_version() {
    local pkg="$1"
    if [ -f "${VERSIONS_FILE}" ]; then
        # Format: category/package:version:slot
        grep "^${pkg}:" "${VERSIONS_FILE}" 2>/dev/null | cut -d: -f2 | head -1
    fi
}

# Function to check if package was already built
is_built() {
    local pkg="$1"
    if [ $RESUME -eq 1 ] && [ -f "${BUILT_FILE}" ]; then
        grep -q "^${pkg}$" "${BUILT_FILE}" 2>/dev/null
        return $?
    fi
    return 1
}

# Build atoms list, respecting version pins and resume mode
ATOMS=()
SKIP_COUNT=0

for pkg in "${PACKAGES[@]}"; do
    # Skip if already built in resume mode
    if is_built "${pkg}"; then
        echo "[SKIP] ${pkg} (already built)"
        ((SKIP_COUNT++))
        continue
    fi

    # Get pinned version if available
    VERSION=$(get_pinned_version "${pkg}")
    if [ -n "${VERSION}" ]; then
        ATOMS+=("=${pkg}-${VERSION}")
        echo "[QUEUE] ${pkg} (pinned: ${VERSION})"
    else
        ATOMS+=("${pkg}")
        echo "[QUEUE] ${pkg} (latest)"
    fi
done

# Exit early if nothing to build
if [ ${#ATOMS[@]} -eq 0 ]; then
    echo ""
    echo "==> Nothing to build (all packages skipped)"
    exit 0
fi

echo ""
echo "==> Building ${#ATOMS[@]} packages with ${JOBS} parallel jobs"

# Uses the cross-emerge wrapper created by crossdev
EMERGE_CMD="${CROSS_TARGET}-emerge"

# Combined log for the parallel build
LOGFILE="${LOGS_DIR}/emerge-parallel.log"

if [ $VERBOSE -eq 1 ]; then
    echo "  Running: ${EMERGE_CMD} --jobs=${JOBS} --load-average=${LOAD_AVG} --keep-going --buildpkg --usepkg ${ATOMS[*]}"
fi

# Build all packages in one emerge call with parallel jobs
# --jobs: build N packages in parallel (Portage handles dependency ordering)
# --load-average: cap system load to prevent oversubscription
# --keep-going: continue building other packages when one fails
# Unset BUILD_DIR: Portage's multilib-minimal.eclass uses it internally to
# construct per-ABI build paths. If set (e.g. from Dockerfile ENV), it creates
# invalid paths like /build-abi_x86_64.amd64 that the sandbox blocks.
unset BUILD_DIR
if ${EMERGE_CMD} \
    --jobs=${JOBS} \
    --load-average=${LOAD_AVG} \
    --keep-going \
    --buildpkg \
    --usepkg \
    --verbose \
    "${ATOMS[@]}" \
    2>&1 | tee "${LOGFILE}"; then

    # All packages succeeded
    SUCCESS_COUNT=${#ATOMS[@]}
    FAIL_COUNT=0
    for pkg in "${PACKAGES[@]}"; do
        if ! is_built "${pkg}"; then
            echo "${pkg}" >> "${BUILT_FILE}"
        fi
    done
else
    # Some packages may have failed; parse the log to determine which
    # Portage logs failures with "emerge: there are remaining packages"
    # and lists failed packages. We'll mark all as potentially failed
    # and let the user check the log.
    echo ""
    echo "==> Some packages failed to build"

    # Save individual build logs for failed packages before they disappear
    # with the ephemeral container. Portage stores them at:
    #   /var/tmp/portage/category/name-version/temp/build.log
    echo "==> Saving failed package build logs to ${LOGS_DIR}/"
    for build_log in /var/tmp/portage/*/*/temp/build.log; do
        [ -f "${build_log}" ] || continue
        # Extract category/name-version from path
        pkg_ver=$(echo "${build_log}" | sed 's|/var/tmp/portage/\(.*\)/temp/build.log|\1|')
        pkg_slug=$(echo "${pkg_ver}" | tr '/' '_')
        cp "${build_log}" "${LOGS_DIR}/${pkg_slug}.build.log" 2>/dev/null && \
            chmod 644 "${LOGS_DIR}/${pkg_slug}.build.log" 2>/dev/null || true
    done

    # Count successes and failures from emerge output
    # Portage shows ">>> Emerging (N of M)" for each package
    SUCCESS_COUNT=0
    FAIL_COUNT=0

    # Check each package for a successful binpkg
    for pkg in "${PACKAGES[@]}"; do
        if is_built "${pkg}"; then
            continue
        fi

        # Check if package has a binpkg (indicates success)
        # GPKG format: PKGDIR/CATEGORY/PKGNAME/PKGNAME-VERSION-BUILDID.gpkg.tar
        PKG_NAME=$(basename "${pkg}")
        if compgen -G "${BINPKG_DIR}/${pkg%/*}/${PKG_NAME}/${PKG_NAME}-*.gpkg.tar" >/dev/null 2>&1; then
            echo "${pkg}" >> "${BUILT_FILE}"
            ((SUCCESS_COUNT++))
        else
            echo "${pkg}" >> "${FAILED_FILE}"
            ((FAIL_COUNT++))
        fi
    done
fi

echo ""
echo "==> Build complete"
echo "    Success: ${SUCCESS_COUNT}"
echo "    Failed: ${FAIL_COUNT}"
echo "    Skipped: ${SKIP_COUNT}"

if [ ${FAIL_COUNT} -gt 0 ]; then
    echo ""
    echo "==> Failed packages:"
    cat "${FAILED_FILE}"
    echo ""
    echo "    Check logs in: ${LOGS_DIR}/"
fi

# Create binpkgs for any installed sysroot packages that emerge skipped because
# they were already present (e.g. acct-user/* installed by crossdev setup).
# quickpkg tarballs installed files without recompiling — fast and idempotent.
echo "==> Creating binpkgs for pre-installed sysroot packages"
ROOT="/usr/${CROSS_TARGET}" PKGDIR="${BINPKG_DIR}" quickpkg --include-config=y "*/*" 2>/dev/null || true
PKGDIR="${BINPKG_DIR}" emaint binhost --fix

# Copy kernel image to OUTPUT_DIR so it escapes the container.
# monolith-kernel installs vmlinuz-${PV} + vmlinuz symlink to /boot in the sysroot.
KERNEL_STAGED="/usr/${CROSS_TARGET}/boot/vmlinuz"
if [ -f "${KERNEL_STAGED}" ] || [ -L "${KERNEL_STAGED}" ]; then
    echo "==> Copying kernel image to ${OUTPUT_DIR}/vmlinuz"
    cp -L "${KERNEL_STAGED}" "${OUTPUT_DIR}/vmlinuz"
else
    echo "WARNING: Kernel image not found at ${KERNEL_STAGED} — vmlinuz will not be saved"
fi

# Export the live sysroot to output/sysroot/ while packages are already installed.
# This avoids a second emerge --usepkgonly pass in extract-packages.sh.
SYSROOT_DIR="${OUTPUT_DIR}/sysroot"
echo "==> Populating ${SYSROOT_DIR} from live sysroot"
rm -rf "${SYSROOT_DIR}"
mkdir -p "${SYSROOT_DIR}"
rsync -a "/usr/${CROSS_TARGET}/" "${SYSROOT_DIR}/"

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
echo "==> Sysroot: ${TOTAL_SIZE} across ${TOTAL_FILES} files → ${SYSROOT_DIR}"

# Exit with error if any packages failed
[ ${FAIL_COUNT} -eq 0 ]
