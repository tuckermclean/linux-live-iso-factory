#!/bin/bash
#
# update-build-pins.sh - Update Dockerfile build pins
#
# Two independent epoch pins (see docs/version-pinning.md "two-pin model"):
#   ARG BUILD_EPOCH      — runtime portage snapshot date. Cheap to bump: no
#                           image rebuild, drives ENV SOURCE_DATE_EPOCH.
#                           This is the routine, auto-mergeable flow
#                           (.github/workflows/pin-bump.yml).
#   ARG TOOLCHAIN_EPOCH  — builder image date (stage3 + baked crossdev tree).
#                           Rare/deliberate: requires `make build-image` and a
#                           crossdev.lock regen. Human-gated flow
#                           (.github/workflows/toolchain-bump.yml).
#
# Runs on the HOST (no Docker required, except crossdev.lock regeneration
# under `update-toolchain`, which queries the existing `monolith-builder`
# image if present and no-ops otherwise).
#
# Usage:
#   update-build-pins.sh check                     # Show current BUILD_EPOCH pin vs available latest
#   update-build-pins.sh update                     # Fetch latest and bump BUILD_EPOCH (+ SOURCE_DATE_EPOCH)
#   update-build-pins.sh update YYYYMMDD            # Force a specific target epoch instead
#                                                    # of "latest" (still verified against
#                                                    # distfiles.gentoo.org before applying)
#   update-build-pins.sh update-toolchain           # Fetch latest and bump TOOLCHAIN_EPOCH
#   update-build-pins.sh update-toolchain YYYYMMDD  # Force a specific target epoch instead

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKERFILE="${SCRIPT_DIR}/../Dockerfile"
CROSSDEV_LOCK="${SCRIPT_DIR}/../configs/portage/crossdev.lock"
CONFIGS_DIR="$(cd "${SCRIPT_DIR}/../configs" && pwd)"
BUILDER_IMAGE="monolith-builder"

# Docker Hub API endpoint for gentoo/stage3 tags
DOCKERHUB_TAGS_URL="https://hub.docker.com/v2/repositories/gentoo/stage3/tags?page_size=100&ordering=last_updated&name=amd64-openrc-"

usage() {
    echo "Usage: $0 <command> [YYYYMMDD]"
    echo ""
    echo "Commands:"
    echo "  check                        Show current BUILD_EPOCH pin vs available latest"
    echo "  update [YYYYMMDD]            Fetch latest (or use the given date) and bump BUILD_EPOCH"
    echo "                               (runtime snapshot pin — cheap, no image rebuild)"
    echo "  update-toolchain [YYYYMMDD]  Fetch latest (or use the given date) and bump TOOLCHAIN_EPOCH"
    echo "                               (builder image pin — rare, requires 'make build-image')"
    exit 1
}

# Fetch the latest amd64-openrc stage3 date tag from Docker Hub
fetch_latest_stage3_date() {
    local url="${DOCKERHUB_TAGS_URL}"
    local latest_date=""

    while [[ -n "${url}" ]]; do
        local response
        response=$(curl -fsSL "${url}") || {
            echo "ERROR: Failed to fetch Docker Hub tags" >&2
            return 1
        }

        local page_latest
        page_latest=$(python3 -c "
import json, sys, re
data = json.load(sys.stdin)
pattern = re.compile(r'^amd64-openrc-(\d{8})$')
dates = []
for tag in data.get('results', []):
    m = pattern.match(tag['name'])
    if m:
        dates.append(m.group(1))
dates.sort(reverse=True)
print(dates[0] if dates else '')
" <<< "${response}")

        if [[ -n "${page_latest}" ]]; then
            if [[ -z "${latest_date}" ]] || [[ "${page_latest}" > "${latest_date}" ]]; then
                latest_date="${page_latest}"
            fi
            break
        fi

        url=$(python3 -c "
import json, sys
data = json.load(sys.stdin)
print(data.get('next') or '')
" <<< "${response}")
    done

    echo "${latest_date}"
}

# Convert YYYYMMDD date to Unix epoch (midnight UTC)
date_to_epoch() {
    local datestr="$1"
    local formatted="${datestr:0:4}-${datestr:4:2}-${datestr:6:2}T00:00:00Z"
    date -d "${formatted}" +%s 2>/dev/null || \
    python3 -c "
from datetime import datetime, timezone
dt = datetime.strptime('${datestr}', '%Y%m%d').replace(tzinfo=timezone.utc)
print(int(dt.timestamp()))
"
}

# Read current value of a given ARG pin (e.g. BUILD_EPOCH, TOOLCHAIN_EPOCH) from Dockerfile
get_current_pin() {
    local name="$1"
    grep "^ARG ${name}=" "${DOCKERFILE}" | cut -d= -f2
}

# Read current BUILD_EPOCH from Dockerfile
get_current_epoch() {
    get_current_pin BUILD_EPOCH
}

# Read current SOURCE_DATE_EPOCH from Dockerfile
get_current_source_epoch() {
    grep '^ENV SOURCE_DATE_EPOCH=' "${DOCKERFILE}" | cut -d= -f2
}

# Verify a portage snapshot and its GPG signature exist on distfiles for the given date
verify_portage_snapshot() {
    local datestr="$1"
    local base="https://distfiles.gentoo.org/snapshots/gentoo-${datestr}.tar.xz"
    curl -fsSL --head "${base}" >/dev/null 2>&1 && \
    curl -fsSL --head "${base}.gpgsig" >/dev/null 2>&1
}

# Command: check
cmd_check() {
    echo "==> Checking build pins"
    echo ""

    local current_epoch current_source_epoch latest_date latest_epoch
    current_epoch=$(get_current_epoch)
    current_source_epoch=$(get_current_source_epoch)

    echo "  Fetching latest stage3 amd64-openrc tag from Docker Hub..."
    latest_date=$(fetch_latest_stage3_date)

    if [[ -z "${latest_date}" ]]; then
        echo "  WARNING: Could not fetch latest stage3 date (network issue?)"
        latest_date="(unavailable)"
        latest_epoch="(unavailable)"
    else
        latest_epoch=$(date_to_epoch "${latest_date}")
    fi

    printf "\n  %-25s %-28s %-28s\n" "Pin" "Current" "Latest"
    printf "  %-25s %-28s %-28s\n" "---" "-------" "------"
    if [[ "${latest_date}" != "(unavailable)" ]] && [[ "${current_epoch}" != "${latest_date}" ]]; then
        if verify_portage_snapshot "${latest_date}"; then
            printf "  %-25s %-28s %-28s *\n" "BUILD_EPOCH" "${current_epoch}" "${latest_date}"
        else
            printf "  %-25s %-28s %-28s (stage3 ahead; portage snapshot for %s not yet published)\n" \
                "BUILD_EPOCH" "${current_epoch}" "${latest_date}" "${latest_date}"
        fi
    else
        printf "  %-25s %-28s %-28s\n" "BUILD_EPOCH" "${current_epoch}" "${latest_date}"
    fi
    printf "  %-25s %-28s %-28s\n" "SOURCE_DATE_EPOCH" "${current_source_epoch}" "${latest_epoch:-derived}"
    echo ""
    echo "  * = update available"
    echo ""
    echo "  Run '$0 update' to apply updates."
}

# Query the best available (visible) version of a package from the builder image's
# portage tree. Works whether or not the package is installed on the builder system.
query_portage_version() {
    local atom="$1"
    local strip_prefix="$2"
    if ! docker image inspect "${BUILDER_IMAGE}" >/dev/null 2>&1; then
        return 0
    fi
    # Two things this docker run must get right:
    #  1. Mount /configs — the builder image's repos.conf points the 'monolith'
    #     overlay at /configs/overlay, so without it portageq aborts with
    #     "nonexistent directory: '/configs/overlay'" (empty output, non-zero).
    #  2. Constrain keywords to '*/* ~*' — the builder image ships '*/* **',
    #     which accepts LIVE 9999 ebuilds, so an unconstrained best_visible pins
    #     e.g. sys-devel/gcc-15.3.9999 (a non-reproducible live ebuild). '~*'
    #     keeps testing across arches but drops live ebuilds (they need '**').
    #     Mirrors update-versions.sh's setup_keywords().
    # Trailing '|| true' keeps a transient/partial query failure from aborting
    # the whole bump under 'set -euo pipefail' — update_crossdev_lock() falls
    # back to the current pins when this returns empty (see its empty guard).
    docker run --rm -v "${CONFIGS_DIR}:/configs" "${BUILDER_IMAGE}" sh -euc '
        kw=/etc/portage/package.accept_keywords/crossdev-all
        if [ -f "$kw" ] && grep -qF "**" "$kw"; then echo "*/* ~*" > "$kw"; fi
        portageq best_visible / "$1"
    ' _ "${atom}" 2>/dev/null | sed "s|${strip_prefix}||" || true
}

# Update crossdev.lock with best versions from the current builder image.
# NOTE: the builder's portage tree reflects the previous BUILD_EPOCH (one epoch behind
# the newly-set one). Versions advance on the next update-build-pins cycle.
update_crossdev_lock() {
    if ! docker image inspect "${BUILDER_IMAGE}" >/dev/null 2>&1; then
        echo "  WARNING: ${BUILDER_IMAGE} image not found — skipping crossdev.lock update"
        return 0
    fi

    echo "  Querying builder image for crossdev package versions..."

    local musl_ver gcc_ver
    musl_ver=$(query_portage_version "sys-libs/musl" "sys-libs/musl-")
    local gcc_major
    gcc_major=$(grep '^sys-devel/gcc:' "${CROSSDEV_LOCK}" 2>/dev/null | cut -d: -f3 || echo "15")
    gcc_ver=$(query_portage_version "=sys-devel/gcc-${gcc_major}*" "sys-devel/gcc-")

    if [[ -z "${musl_ver}" && -z "${gcc_ver}" ]]; then
        echo "  WARNING: Could not query portage versions — crossdev.lock unchanged"
        return 0
    fi

    local current_musl current_gcc
    current_musl=$(grep '^sys-libs/musl:' "${CROSSDEV_LOCK}" | cut -d: -f2 || true)
    current_gcc=$(grep '^sys-devel/gcc:' "${CROSSDEV_LOCK}" | cut -d: -f2 || true)

    local changed=0
    [[ -n "${musl_ver}" && "${musl_ver}" != "${current_musl}" ]] && changed=1
    [[ -n "${gcc_ver}"  && "${gcc_ver}"  != "${current_gcc}"  ]] && changed=1

    if [[ "${changed}" -eq 0 ]]; then
        echo "  crossdev.lock already up to date"
        return 0
    fi

    musl_ver="${musl_ver:-${current_musl}}"
    gcc_ver="${gcc_ver:-${current_gcc}}"
    local gcc_slot="${gcc_ver%%.*}"

    cat > "${CROSSDEV_LOCK}" << EOF
# crossdev.lock — Cross-toolchain version pins
#
# Updated by: make update-build-pins
# Applied by: make build-image (passed to crossdev --libc / --gcc)
#
# linux-headers derived from kernel pin in versions.lock (major.minor).
# binutils read from versions.lock (world package, kept in sync automatically).
#
# Format: category/package:version:slot  (same as versions.lock)

sys-libs/musl:${musl_ver}:0
sys-devel/gcc:${gcc_ver}:${gcc_slot}
EOF

    [[ -n "${musl_ver}" && "${musl_ver}" != "${current_musl}" ]] && \
        echo "  sys-libs/musl: ${current_musl} → ${musl_ver}"
    [[ -n "${gcc_ver}"  && "${gcc_ver}"  != "${current_gcc}"  ]] && \
        echo "  sys-devel/gcc: ${current_gcc} → ${gcc_ver}"
}

# Command: update [YYYYMMDD]
# With no argument, fetches and uses the latest available stage3 date.
# With an explicit YYYYMMDD argument, forces that date as the target epoch
# instead (e.g. for a manually-triggered "force target epoch" bump). The
# forced date is still subject to the same portage-snapshot verification
# below — an unverified date is never applied.
cmd_update() {
    echo "==> Updating Dockerfile build pins"

    local forced_date="${1:-}"
    local current_epoch latest_date new_source_epoch
    current_epoch=$(get_current_epoch)

    if [[ -n "${forced_date}" ]]; then
        if ! [[ "${forced_date}" =~ ^[0-9]{8}$ ]]; then
            echo "ERROR: forced target epoch must be YYYYMMDD, got: ${forced_date}" >&2
            exit 1
        fi
        echo "  Using forced target epoch: ${forced_date}"
        latest_date="${forced_date}"
    else
        echo "  Fetching latest stage3 amd64-openrc tag from Docker Hub..."
        latest_date=$(fetch_latest_stage3_date)

        if [[ -z "${latest_date}" ]]; then
            echo "ERROR: Could not fetch latest stage3 date — network issue?" >&2
            exit 1
        fi
    fi

    # Verify the portage snapshot exists for this date before committing to it
    echo "  Verifying portage snapshot exists for ${latest_date}..."
    if ! verify_portage_snapshot "${latest_date}"; then
        echo "ERROR: No portage snapshot found for ${latest_date} — cannot update BUILD_EPOCH" >&2
        echo "       The stage3 image exists but the matching portage snapshot does not yet." >&2
        exit 1
    fi

    if [[ "${current_epoch}" == "${latest_date}" ]]; then
        echo "  BUILD_EPOCH already up to date: ${current_epoch}"
    else
        echo "  Updating BUILD_EPOCH: ${current_epoch} → ${latest_date}"
        sed -i "s/^ARG BUILD_EPOCH=.*/ARG BUILD_EPOCH=${latest_date}/" "${DOCKERFILE}"
        # Fail closed: never proceed if the sed silently didn't apply
        # (e.g. the ARG line's format drifted).
        local applied_epoch
        applied_epoch=$(get_current_pin BUILD_EPOCH)
        if [[ "${applied_epoch}" != "${latest_date}" ]]; then
            echo "ERROR: BUILD_EPOCH sed did not apply — Dockerfile shows '${applied_epoch}', expected '${latest_date}'" >&2
            exit 1
        fi
    fi

    new_source_epoch=$(date_to_epoch "${latest_date}")
    local current_source_epoch
    current_source_epoch=$(get_current_source_epoch)

    if [[ "${current_source_epoch}" == "${new_source_epoch}" ]]; then
        echo "  SOURCE_DATE_EPOCH already up to date: ${current_source_epoch}"
    else
        echo "  Updating SOURCE_DATE_EPOCH: ${current_source_epoch} → ${new_source_epoch}"
        sed -i "s/^ENV SOURCE_DATE_EPOCH=.*/ENV SOURCE_DATE_EPOCH=${new_source_epoch}/" "${DOCKERFILE}"
        local applied_source_epoch
        applied_source_epoch=$(get_current_source_epoch)
        if [[ "${applied_source_epoch}" != "${new_source_epoch}" ]]; then
            echo "ERROR: SOURCE_DATE_EPOCH sed did not apply — Dockerfile shows '${applied_source_epoch}', expected '${new_source_epoch}'" >&2
            exit 1
        fi
    fi

    echo ""
    echo "==> Done. This is the cheap runtime-snapshot pin — no image rebuild needed."
    echo "    Run 'make sync-portage update-versions' to regenerate versions.lock against it."
}

# Command: update-toolchain [YYYYMMDD]
# Bumps TOOLCHAIN_EPOCH — the builder-image pin (stage3 base + baked crossdev
# toolchain tree), NOT BUILD_EPOCH (the runtime snapshot pin, see cmd_update).
# This is the rare, human-gated flow (.github/workflows/toolchain-bump.yml):
# after this runs, the image must be rebuilt (`make build-image`) and
# configs/portage/crossdev.lock regenerated. This does NOT touch
# SOURCE_DATE_EPOCH — that's derived from BUILD_EPOCH, the runtime snapshot,
# which a toolchain-only bump does not change.
cmd_update_toolchain() {
    echo "==> Updating Dockerfile toolchain pin (TOOLCHAIN_EPOCH)"

    local forced_date="${1:-}"
    local current_epoch latest_date
    current_epoch=$(get_current_pin TOOLCHAIN_EPOCH)

    if [[ -n "${forced_date}" ]]; then
        if ! [[ "${forced_date}" =~ ^[0-9]{8}$ ]]; then
            echo "ERROR: forced target epoch must be YYYYMMDD, got: ${forced_date}" >&2
            exit 1
        fi
        echo "  Using forced target epoch: ${forced_date}"
        latest_date="${forced_date}"
    else
        echo "  Fetching latest stage3 amd64-openrc tag from Docker Hub..."
        latest_date=$(fetch_latest_stage3_date)

        if [[ -z "${latest_date}" ]]; then
            echo "ERROR: Could not fetch latest stage3 date — network issue?" >&2
            exit 1
        fi
    fi

    # Fail-closed guard, mirroring cmd_update: verify a matching portage
    # snapshot exists too. TOOLCHAIN_EPOCH's own tree is baked from stage3
    # rather than this snapshot, but both epochs are seeded from the same
    # date family today, and this keeps the same verified-before-applied
    # discipline for the toolchain path.
    echo "  Verifying portage snapshot exists for ${latest_date}..."
    if ! verify_portage_snapshot "${latest_date}"; then
        echo "ERROR: No portage snapshot found for ${latest_date} — cannot update TOOLCHAIN_EPOCH" >&2
        exit 1
    fi

    if [[ "${current_epoch}" == "${latest_date}" ]]; then
        echo "  TOOLCHAIN_EPOCH already up to date: ${current_epoch}"
    else
        echo "  Updating TOOLCHAIN_EPOCH: ${current_epoch} → ${latest_date}"
        sed -i "s/^ARG TOOLCHAIN_EPOCH=.*/ARG TOOLCHAIN_EPOCH=${latest_date}/" "${DOCKERFILE}"
        # Fail closed: assert the sed actually applied before continuing.
        local applied_epoch
        applied_epoch=$(get_current_pin TOOLCHAIN_EPOCH)
        if [[ "${applied_epoch}" != "${latest_date}" ]]; then
            echo "ERROR: TOOLCHAIN_EPOCH sed did not apply — Dockerfile shows '${applied_epoch}', expected '${latest_date}'" >&2
            exit 1
        fi
    fi

    echo ""
    update_crossdev_lock
    echo ""
    echo "==> Done. Run 'make build-image' to rebuild the toolchain image with the new base."
}

# Main
case "${1:-}" in
    check)             cmd_check ;;
    update)            cmd_update "${2:-}" ;;
    update-toolchain)  cmd_update_toolchain "${2:-}" ;;
    *)                 usage ;;
esac
