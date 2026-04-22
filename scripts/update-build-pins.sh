#!/bin/bash
#
# update-build-pins.sh - Update Dockerfile build pins
#
# Manages the build epoch that pins all build inputs to a single date:
#   ARG BUILD_EPOCH  — stage3 base image date + portage snapshot date (always equal)
#   ENV SOURCE_DATE_EPOCH — Unix epoch derived from BUILD_EPOCH
#
# Runs on the HOST (no Docker required).
#
# Usage:
#   update-build-pins.sh check    # Show current pins vs available latest
#   update-build-pins.sh update   # Fetch latest and update Dockerfile

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKERFILE="${SCRIPT_DIR}/../Dockerfile"
CROSSDEV_LOCK="${SCRIPT_DIR}/../configs/portage/crossdev.lock"
BUILDER_IMAGE="monolith-builder"

# Docker Hub API endpoint for gentoo/stage3 tags
DOCKERHUB_TAGS_URL="https://hub.docker.com/v2/repositories/gentoo/stage3/tags?page_size=100&ordering=last_updated&name=amd64-openrc-"

usage() {
    echo "Usage: $0 <command>"
    echo ""
    echo "Commands:"
    echo "  check     Show current pins vs available latest"
    echo "  update    Fetch latest and update Dockerfile"
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

# Read current BUILD_EPOCH from Dockerfile
get_current_epoch() {
    grep '^ARG BUILD_EPOCH=' "${DOCKERFILE}" | cut -d= -f2
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
    printf "  %-25s %-28s %-28s" "BUILD_EPOCH" "${current_epoch}" "${latest_date}"
    [[ "${current_epoch}" != "${latest_date}" ]] && echo " *" || echo ""
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
    docker run --rm "${BUILDER_IMAGE}" \
        portageq best_visible / "${atom}" 2>/dev/null \
        | sed "s|${strip_prefix}||"
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

# Command: update
cmd_update() {
    echo "==> Updating Dockerfile build pins"

    local current_epoch latest_date new_source_epoch
    current_epoch=$(get_current_epoch)

    echo "  Fetching latest stage3 amd64-openrc tag from Docker Hub..."
    latest_date=$(fetch_latest_stage3_date)

    if [[ -z "${latest_date}" ]]; then
        echo "ERROR: Could not fetch latest stage3 date — network issue?" >&2
        exit 1
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
    fi

    new_source_epoch=$(date_to_epoch "${latest_date}")
    local current_source_epoch
    current_source_epoch=$(get_current_source_epoch)

    if [[ "${current_source_epoch}" == "${new_source_epoch}" ]]; then
        echo "  SOURCE_DATE_EPOCH already up to date: ${current_source_epoch}"
    else
        echo "  Updating SOURCE_DATE_EPOCH: ${current_source_epoch} → ${new_source_epoch}"
        sed -i "s/^ENV SOURCE_DATE_EPOCH=.*/ENV SOURCE_DATE_EPOCH=${new_source_epoch}/" "${DOCKERFILE}"
    fi

    echo ""
    update_crossdev_lock
    echo ""
    echo "==> Done. Run 'make build-image' to rebuild the factory with the new base."
}

# Main
case "${1:-}" in
    check)  cmd_check ;;
    update) cmd_update ;;
    *)      usage ;;
esac
