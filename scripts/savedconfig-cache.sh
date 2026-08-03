#!/bin/bash
#
# savedconfig-cache.sh — stop savedconfig-governed binpkgs from going stale.
#
# Portage's binary-package reuse keys on version + USE + CHOST — it does NOT
# hash savedconfig contents. So editing a savedconfig-governed package's config
# (e.g. busybox's applet set) WITHOUT bumping its version silently reuses the old
# binary, and the config change never takes effect. Packages that carry a real
# version/revision bump (e.g. the kernel via -rN) are immune and need not appear
# here.
#
# This tracks a SHA-256 of each savedconfig in a marker object stored next to the
# package's binpkgs in S3:
#
#   check  — run BEFORE restoring the binpkg cache. For each tracked package,
#            if the committed savedconfig's hash != the stored marker, delete the
#            package's binpkg dir from S3 so the build recompiles it from source.
#   mark   — run AFTER building + saving binpkgs. Record the current hashes so the
#            next build sees a match and reuses the (now-current) binpkg.
#
# Usage: savedconfig-cache.sh <check|mark> <bucket> <build_epoch>
#
# Idempotent and best-effort: any S3 hiccup degrades to "rebuild it" (check) or a
# warning (mark), never a hard failure of the build.

set -uo pipefail

MODE="${1:?usage: savedconfig-cache.sh <check|mark> <bucket> <build_epoch>}"
BUCKET="${2:?missing bucket}"
EPOCH="${3:?missing build_epoch}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Tracked packages: "category/package:relative-path-to-savedconfig"
# Add a line here whenever a new savedconfig-governed, non-revbumped package is
# introduced. (The kernel is intentionally absent — it uses a -rN revbump.)
TRACKED=(
    "sys-apps/busybox:configs/portage/savedconfig/sys-apps/busybox"
)

config_hash() {
    sha256sum "$1" | cut -c1-64
}

for entry in "${TRACKED[@]}"; do
    atom="${entry%%:*}"
    cfg="${REPO_ROOT}/${entry##*:}"
    if [ ! -f "$cfg" ]; then
        echo "savedconfig-cache: ${entry##*:} not found — skipping ${atom}"
        continue
    fi
    want="$(config_hash "$cfg")"
    pkg_prefix="s3://${BUCKET}/packages/${EPOCH}/${atom}"
    marker="${pkg_prefix}/.savedconfig.sha256"

    case "$MODE" in
        check)
            have="$(aws s3 cp "$marker" - 2>/dev/null || true)"
            have="$(printf '%s' "$have" | tr -d '[:space:]')"
            if [ "$want" != "$have" ]; then
                echo "savedconfig-cache: ${atom} savedconfig changed (${have:-<none>} -> ${want}) — purging binpkg so it rebuilds from source"
                aws s3 rm --recursive "${pkg_prefix}/" || \
                    echo "savedconfig-cache: WARNING: purge failed for ${atom} (build will still rebuild if the cache is absent)" >&2
            else
                echo "savedconfig-cache: ${atom} savedconfig unchanged — keeping cached binpkg"
            fi
            ;;
        mark)
            if printf '%s\n' "$want" | aws s3 cp - "$marker" >/dev/null 2>&1; then
                echo "savedconfig-cache: recorded ${atom} savedconfig hash ${want}"
            else
                echo "savedconfig-cache: WARNING: could not write marker for ${atom}" >&2
            fi
            ;;
        *)
            echo "savedconfig-cache: unknown mode '${MODE}' (expected check|mark)" >&2
            exit 2
            ;;
    esac
done
