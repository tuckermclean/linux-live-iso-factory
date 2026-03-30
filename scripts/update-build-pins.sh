#!/bin/bash
#
# update-build-pins.sh - Update Dockerfile build pins
#
# Manages the two version pins that live outside portage:
#   1. ARG STAGE3_DATE  — Gentoo stage3 amd64-openrc base image date tag
#   2. ENV SOURCE_DATE_EPOCH — Unix epoch derived from STAGE3_DATE
#
# Runs on the HOST (no Docker required).
#
# Usage:
#   update-build-pins.sh check    # Show current pins vs available latest
#   update-build-pins.sh update   # Fetch latest and update Dockerfile

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKERFILE="${SCRIPT_DIR}/../Dockerfile"

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

# Fetch the latest amd64-multilib stage3 date tag from Docker Hub
fetch_latest_stage3_date() {
    local url="${DOCKERHUB_TAGS_URL}"
    local latest_date=""

    # Paginate through results to find the most recent amd64-multilib-YYYYMMDDTHHMMSSZ tag
    while [[ -n "${url}" ]]; do
        local response
        response=$(curl -fsSL "${url}") || {
            echo "ERROR: Failed to fetch Docker Hub tags" >&2
            return 1
        }

        # Extract tags matching amd64-openrc-YYYYMMDD pattern
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
            # We got a result from this page; check next page only if no result yet
            break
        fi

        # Move to next page
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
    # Format: 20260323 → 2026-03-23T00:00:00Z
    local formatted="${datestr:0:4}-${datestr:4:2}-${datestr:6:2}T00:00:00Z"
    date -d "${formatted}" +%s 2>/dev/null || \
    python3 -c "
from datetime import datetime, timezone
dt = datetime.strptime('${datestr}', '%Y%m%d').replace(tzinfo=timezone.utc)
print(int(dt.timestamp()))
"
}

# Read current value of ARG STAGE3_DATE from Dockerfile
get_current_stage3_date() {
    grep '^ARG STAGE3_DATE=' "${DOCKERFILE}" | cut -d= -f2
}

# Read current value of ARG PORTAGE_DATE from Dockerfile
get_current_portage_date() {
    grep '^ARG PORTAGE_DATE=' "${DOCKERFILE}" | cut -d= -f2
}

# Read current SOURCE_DATE_EPOCH from Dockerfile
get_current_epoch() {
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

    local current_stage3 current_portage current_epoch latest_date latest_epoch
    current_stage3=$(get_current_stage3_date)
    current_portage=$(get_current_portage_date)
    current_epoch=$(get_current_epoch)

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
    printf "  %-25s %-28s %-28s" "STAGE3_DATE" "${current_stage3}" "${latest_date}"
    [[ "${current_stage3}" != "${latest_date}" ]] && echo " *" || echo ""
    printf "  %-25s %-28s %-28s" "PORTAGE_DATE" "${current_portage}" "${latest_date}"
    [[ "${current_portage}" != "${latest_date}" ]] && echo " *" || echo ""
    printf "  %-25s %-28s %-28s\n" "SOURCE_DATE_EPOCH" "${current_epoch}" "${latest_epoch:-derived}"
    echo ""
    echo "  * = update available"
    echo ""
    echo "  Run '$0 update' to apply updates."
}

# Command: update
cmd_update() {
    echo "==> Updating Dockerfile build pins"

    local current_stage3 current_portage latest_date new_epoch
    current_stage3=$(get_current_stage3_date)
    current_portage=$(get_current_portage_date)

    echo "  Fetching latest stage3 amd64-openrc tag from Docker Hub..."
    latest_date=$(fetch_latest_stage3_date)

    if [[ -z "${latest_date}" ]]; then
        echo "ERROR: Could not fetch latest stage3 date — network issue?" >&2
        exit 1
    fi

    if [[ "${current_stage3}" == "${latest_date}" ]]; then
        echo "  STAGE3_DATE already up to date: ${current_stage3}"
    else
        echo "  Updating STAGE3_DATE: ${current_stage3} → ${latest_date}"
        sed -i "s/^ARG STAGE3_DATE=.*/ARG STAGE3_DATE=${latest_date}/" "${DOCKERFILE}"
    fi

    # Verify the portage snapshot exists for this date before pinning it
    echo "  Verifying portage snapshot exists for ${latest_date}..."
    if verify_portage_snapshot "${latest_date}"; then
        if [[ "${current_portage}" == "${latest_date}" ]]; then
            echo "  PORTAGE_DATE already up to date: ${current_portage}"
        else
            echo "  Updating PORTAGE_DATE: ${current_portage} → ${latest_date}"
            sed -i "s/^ARG PORTAGE_DATE=.*/ARG PORTAGE_DATE=${latest_date}/" "${DOCKERFILE}"
        fi
    else
        echo "  WARNING: No portage snapshot found for ${latest_date} — PORTAGE_DATE unchanged (${current_portage})"
    fi

    new_epoch=$(date_to_epoch "${latest_date}")
    local current_epoch
    current_epoch=$(get_current_epoch)

    if [[ "${current_epoch}" == "${new_epoch}" ]]; then
        echo "  SOURCE_DATE_EPOCH already up to date: ${current_epoch}"
    else
        echo "  Updating SOURCE_DATE_EPOCH: ${current_epoch} → ${new_epoch}"
        sed -i "s/^ENV SOURCE_DATE_EPOCH=.*/ENV SOURCE_DATE_EPOCH=${new_epoch}/" "${DOCKERFILE}"
    fi

    echo ""
    echo "==> Done. Run 'make build-image' to rebuild the factory with the new base."
}

# Main
case "${1:-}" in
    check)  cmd_check ;;
    update) cmd_update ;;
    *)      usage ;;
esac
