#!/bin/bash
#
# update-versions.sh - Manage package version pinning
#
# Commands:
#   check    - Show available updates vs pinned versions
#   update   - Query portageq and write new versions.lock
#   validate - Check versions.lock format
#
# Coverage note: this already tracks the kernel and BusyBox, not just
# userland. Both are ordinary entries in configs/portage/world
# (sys-kernel/monolith-kernel and sys-apps/busybox) and get a real
# category/package:version:slot line in versions.lock like every other
# world package — there is no separate "kernel/BusyBox version" mechanism
# to build. Host-only build tools (syslinux, grub, mtools, ...) are
# intentionally NOT covered here: they never enter the target sysroot, so
# they are pinned indirectly via the Dockerfile's BUILD_EPOCH instead (see
# the comment above the host-tools `emerge` block in the Dockerfile).

set -e

CONFIGS_DIR="${CONFIGS_DIR:-/configs}"
PORTAGE_DIR="${CONFIGS_DIR}/portage"
WORLD_FILE="${PORTAGE_DIR}/world"
VERSIONS_FILE="${PORTAGE_DIR}/versions.lock"

# Resolve versions against the CROSS TARGET's portage config (PORTAGE_CONFIGROOT
# = /usr/<target>), NOT the amd64 host. The target accepts ~x86 (see
# configs/portage/package.accept_keywords/i486), so a package that is ~amd64 but
# not yet keyworded ~x86 — e.g. binutils-2.46.1-r1 ("missing keyword") — is
# correctly excluded, matching what the cross-emerge actually installs. It also
# drops live 9999 ebuilds naturally (target uses ~x86, not **), except where the
# target config explicitly allows ** (e.g. sys-kernel/monolith-kernel).
CROSS_TARGET="${CROSS_TARGET:-i486-linux-musl}"
TARGET_ROOT="/usr/${CROSS_TARGET}"

usage() {
    echo "Usage: $0 <command>"
    echo ""
    echo "Commands:"
    echo "  check     Show available updates vs pinned versions"
    echo "  update    Query portageq and write new versions.lock"
    echo "  validate  Check versions.lock format"
    exit 1
}

# Temporarily fix accept_keywords so portageq excludes 9999 live ebuilds.
# The Dockerfile sets */* ** (double star = accept everything including live),
# but cross target uses ACCEPT_KEYWORDS="*" (single star = no live ebuilds).
CROSSDEV_KEYWORDS="/etc/portage/package.accept_keywords/crossdev-all"
setup_keywords() {
    if [ -f "${CROSSDEV_KEYWORDS}" ] && grep -qF '**' "${CROSSDEV_KEYWORDS}" 2>/dev/null; then
        ORIG_KEYWORDS=$(cat "${CROSSDEV_KEYWORDS}")
        echo '*/* ~*' > "${CROSSDEV_KEYWORDS}"
        trap 'echo "${ORIG_KEYWORDS}" > "${CROSSDEV_KEYWORDS}"' EXIT
    fi
}

# Get best available version for a package (resolved against the target config,
# falling back to the host root only if the target query yields nothing).
get_best_version() {
    local pkg="$1"
    local cpv
    cpv=$(PORTAGE_CONFIGROOT="${TARGET_ROOT}" portageq best_visible "${TARGET_ROOT}" "${pkg}" 2>/dev/null) \
        || cpv=$(portageq best_visible / "${pkg}" 2>/dev/null) || return
    # Strip category/name- prefix to get version
    echo "${cpv#"${pkg}-"}"
}

# Get slot for a package version (target config, host fallback).
get_slot() {
    local pkg="$1"
    local cpv slot
    cpv=$(PORTAGE_CONFIGROOT="${TARGET_ROOT}" portageq best_visible "${TARGET_ROOT}" "${pkg}" 2>/dev/null) \
        || cpv=$(portageq best_visible / "${pkg}" 2>/dev/null) || return
    slot=$(portageq metadata "${TARGET_ROOT}" ebuild "${cpv}" SLOT 2>/dev/null) \
        || slot=$(portageq metadata / ebuild "${cpv}" SLOT 2>/dev/null) || return
    # Strip subslot (e.g., 0/5.2 -> 0)
    echo "${slot%%/*}"
}

# Read world file
read_world() {
    if [ ! -f "${WORLD_FILE}" ]; then
        echo "ERROR: World file not found: ${WORLD_FILE}"
        exit 1
    fi
    grep -v '^#' "${WORLD_FILE}" | grep -v '^$'
}

# Command: check
cmd_check() {
    setup_keywords

    echo "==> Checking package versions"
    echo ""
    printf "%-35s %-15s %-15s\n" "Package" "Pinned" "Available"
    printf "%-35s %-15s %-15s\n" "-------" "------" "---------"

    while read -r pkg; do
        [ -z "${pkg}" ] && continue

        # Get pinned version
        PINNED=""
        if [ -f "${VERSIONS_FILE}" ]; then
            PINNED=$(grep "^${pkg}:" "${VERSIONS_FILE}" 2>/dev/null | cut -d: -f2 | head -1)
        fi
        [ -z "${PINNED}" ] && PINNED="(unpinned)"

        # Get available version
        AVAILABLE=$(get_best_version "${pkg}") || true
        [ -z "${AVAILABLE}" ] && AVAILABLE="(not found)"

        # Mark if update available
        if [ "${PINNED}" != "(unpinned)" ] && [ "${PINNED}" != "${AVAILABLE}" ]; then
            MARKER="*"
        else
            MARKER=""
        fi

        printf "%-35s %-15s %-15s %s\n" "${pkg}" "${PINNED}" "${AVAILABLE}" "${MARKER}"

    done < <(read_world)

    echo ""
    echo "* = update available"
}

# Command: update
cmd_update() {
    setup_keywords

    echo "==> Updating versions.lock"

    # Create new versions file
    TMPFILE=$(mktemp)

    cat > "${TMPFILE}" << 'EOF'
# Pinned package versions for reproducible builds
#
# Format: category/package:version:slot
# Generated by: update-versions.sh update
#
EOF
    echo "# Updated: $(date -Iseconds)" >> "${TMPFILE}"
    echo "" >> "${TMPFILE}"

    while read -r pkg; do
        [ -z "${pkg}" ] && continue

        VERSION=$(get_best_version "${pkg}") || true
        SLOT=$(get_slot "${pkg}") || true

        if [ -n "${VERSION}" ]; then
            echo "${pkg}:${VERSION}:${SLOT:-0}" >> "${TMPFILE}"
            echo "  ${pkg}:${VERSION}:${SLOT:-0}"
        else
            echo "  WARNING: ${pkg} not found in portage tree"
        fi

    done < <(read_world)

    # Replace old versions file
    mv "${TMPFILE}" "${VERSIONS_FILE}"

    echo ""
    echo "==> Wrote ${VERSIONS_FILE}"
}

# Command: validate
cmd_validate() {
    if [ ! -f "${VERSIONS_FILE}" ]; then
        echo "ERROR: Versions file not found: ${VERSIONS_FILE}"
        exit 1
    fi

    echo "==> Validating versions.lock format"

    ERRORS=0
    LINE_NUM=0

    while IFS= read -r line; do
        ((LINE_NUM++))

        # Skip comments and blank lines
        [[ "${line}" =~ ^# ]] && continue
        [[ -z "${line}" ]] && continue

        # Validate format: category/package:version:slot
        if ! [[ "${line}" =~ ^[a-z0-9-]+/[a-z0-9_+-]+:[0-9a-zA-Z._-]+:[0-9]+$ ]]; then
            echo "  Line ${LINE_NUM}: Invalid format: ${line}"
            ((ERRORS++))
        fi

    done < "${VERSIONS_FILE}"

    if [ ${ERRORS} -eq 0 ]; then
        echo "  OK: Format is valid"
        exit 0
    else
        echo ""
        echo "  ERRORS: ${ERRORS} invalid lines"
        exit 1
    fi
}

# Main
case "${1:-}" in
    check)
        cmd_check
        ;;
    update)
        cmd_update
        ;;
    validate)
        cmd_validate
        ;;
    *)
        usage
        ;;
esac
