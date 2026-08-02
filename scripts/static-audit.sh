#!/bin/bash
#
# static-audit.sh - Report dynamically-linked binaries in the built rootfs
#
# The Monolith aims for a fully static userland (configs/portage/env/static.conf
# + package.use/static force USE=static and -static LDFLAGS across the world
# file). Some upstream ebuilds silently ignore that (their IUSE has no
# "static" flag, or they always link a helper .so), so this script is the
# verification step: walk every executable in the built rootfs and report
# which ones actually came out dynamically linked.
#
# This is informational, not a build gate — it does not modify the rootfs
# or fail the build by default, so it cannot perturb the SquashFS bytes or
# the attestation digest chain. Run it after build-rootfs.sh (or point it at
# any extracted sysroot) to get a report; pass --strict to make it exit
# non-zero when dynamic binaries are found (useful as a CI check once the
# known-offenders list below is empty).
#
# Usage:
#   static-audit.sh [--strict] [TARGET_DIR]
#
#   TARGET_DIR defaults to ${ROOTFS_DIR:-/rootfs-build}, falling back to
#   ${OUTPUT_DIR:-/output}/sysroot if that doesn't exist. Pass an explicit
#   path to audit anything else (e.g. a local extraction for manual review).

set -uo pipefail

STRICT=0
TARGET_DIR=""

for arg in "$@"; do
    case "$arg" in
        --strict) STRICT=1 ;;
        -h|--help)
            echo "Usage: $0 [--strict] [TARGET_DIR]"
            exit 0
            ;;
        *) TARGET_DIR="$arg" ;;
    esac
done

if [ -z "$TARGET_DIR" ]; then
    if [ -d "${ROOTFS_DIR:-/rootfs-build}" ]; then
        TARGET_DIR="${ROOTFS_DIR:-/rootfs-build}"
    else
        TARGET_DIR="${OUTPUT_DIR:-/output}/sysroot"
    fi
fi

OUTPUT_DIR="${OUTPUT_DIR:-/output}"
REPORT_DIR="${OUTPUT_DIR}/reports"
REPORT_FILE="${REPORT_DIR}/static-audit.txt"

if [ ! -d "$TARGET_DIR" ]; then
    echo "ERROR: target directory not found: $TARGET_DIR" >&2
    echo "  Run build-rootfs.sh (or extract-packages.sh) first, or pass an" >&2
    echo "  explicit path to an extracted rootfs/sysroot." >&2
    exit 1
fi

command -v file >/dev/null 2>&1 || {
    echo "ERROR: 'file' not found on PATH (needed to inspect ELF binaries)" >&2
    exit 1
}

mkdir -p "$REPORT_DIR"

echo "==> Static-link audit of ${TARGET_DIR}"

{
    echo "# Static-link audit"
    echo "# Target: ${TARGET_DIR}"
    echo "# Date:   $(date -Iseconds 2>/dev/null || date)"
    echo "#"
    echo "# Every dynamically-linked executable found below defeats the point of"
    echo "# USE=static + -static LDFLAGS (see configs/portage/env/static.conf and"
    echo "# configs/portage/package.use/static): each exec() pays for dynamic"
    echo "# linker lookups/relocations, which matters on i486 booting off CD-ROM."
    echo "#"
    echo "# Known offenders as of the 2026-08-02 audit (documented, not yet fixed):"
    echo "#   sys-apps/util-linux (mount, agetty, mountpoint, ...) - upstream ebuild"
    echo "#     has no 'static' USE flag for the client utilities; BusyBox provides"
    echo "#     static mount/mountpoint as a substitute, but not a full agetty."
    echo "# Any other package appearing below is new information — cross-reference"
    echo "# its path against configs/portage/package.use/static and consider"
    echo "# overriding LDFLAGS for it via configs/portage/package.env."
    echo
} > "$REPORT_FILE"

DYNAMIC_COUNT=0
SCANNED_COUNT=0

while IFS= read -r -d '' f; do
    SCANNED_COUNT=$((SCANNED_COUNT + 1))
    finfo=$(file -b "$f" 2>/dev/null) || continue

    # Only care about ELF executables/shared objects, not scripts.
    case "$finfo" in
        ELF*) : ;;
        *) continue ;;
    esac

    if printf '%s' "$finfo" | grep -q "dynamically linked"; then
        DYNAMIC_COUNT=$((DYNAMIC_COUNT + 1))
        rel="${f#"${TARGET_DIR}"/}"
        printf '%-55s %s\n' "$rel" "$finfo" >> "$REPORT_FILE"
    fi
done < <(find "$TARGET_DIR" -type f -perm -u+x -print0 2>/dev/null)

{
    echo
    echo "Scanned:               ${SCANNED_COUNT} executable files"
    echo "Dynamically linked:    ${DYNAMIC_COUNT}"
} >> "$REPORT_FILE"

echo "==> Scanned ${SCANNED_COUNT} executables, found ${DYNAMIC_COUNT} dynamically linked"
echo "==> Report: ${REPORT_FILE}"

if [ "$DYNAMIC_COUNT" -gt 0 ] && [ "$STRICT" -eq 1 ]; then
    echo "==> --strict: failing due to ${DYNAMIC_COUNT} dynamically-linked binaries" >&2
    exit 1
fi

exit 0
