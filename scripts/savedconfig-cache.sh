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
# This tracks a SHA-256 of each savedconfig in a marker file stored next to the
# package's binpkgs in the LOCAL binpkg store (PKGDIR, see scripts/binpkg-store.sh):
#
#   check  — run AFTER `binpkg-store.sh pull` unpacks the epoch's binpkgs into
#            PKGDIR, BEFORE the build. For each tracked package, if the committed
#            savedconfig's hash != the marker recorded alongside its gpkgs, delete
#            the package's gpkg dir so the build recompiles it from source.
#   mark   — run AFTER building, BEFORE `binpkg-store.sh prune`/`pack`/`push`.
#            Records the current hashes so the marker travels inside the packed
#            artifact and the NEXT build's `check` (after its own pull) sees a
#            match and reuses the (now-current) binpkg.
#
# The marker lives at "<PKGDIR>/<category>/<package>/.savedconfig.sha256" — same
# CATEGORY/PN directory `binpkg-store.sh`'s gpkg layout uses. It is not a
# "*.gpkg.tar" file, so `binpkg-store.sh prune`'s `find -name '*.gpkg.tar'`
# listing never touches it, and `pack` (a plain tar of PKGDIR) carries it along.
#
# Ported from an S3-marker design (one `aws s3 cp`/`aws s3 rm` per tracked
# package) to this local-filesystem form when the binpkg store itself moved
# from S3 to a single GHCR OCI artifact per epoch — see
# docs/superpowers/plans/2026-08-18-ci-efficiency-round2.md. There is no longer
# an S3 packages/ tree to prune ahead of a sync, so `check`/`mark` now act
# directly on the freshly-unpacked (check) / about-to-be-packed (mark) local
# PKGDIR instead.
#
# Usage: savedconfig-cache.sh <check|mark> [pkgdir]
#   pkgdir defaults to $PKGDIR, then <repo>/output/packages (same default and
#   env var binpkg-store.sh uses, so both scripts agree on the store location
#   without the caller having to repeat it).
#
# Idempotent and best-effort: a missing marker or a filesystem hiccup degrades
# to "rebuild it" (check) or a warning (mark), never a hard failure of the build.

set -uo pipefail

MODE="${1:?usage: savedconfig-cache.sh <check|mark> [pkgdir]}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PKGDIR="${2:-${PKGDIR:-${REPO_ROOT}/output/packages}}"

# Tracked packages: "category/package:relative-path-to-savedconfig"
# Add a line here whenever a new savedconfig-governed, non-revbumped package is
# introduced. (The kernel is intentionally absent — it uses a -rN revbump.)
TRACKED=(
    "sys-apps/busybox:configs/portage/savedconfig/sys-apps/busybox"
)

config_hash() {
    sha256sum "$1" | cut -c1-64
}

mkdir -p "$PKGDIR"

for entry in "${TRACKED[@]}"; do
    atom="${entry%%:*}"
    cfg="${REPO_ROOT}/${entry##*:}"
    if [ ! -f "$cfg" ]; then
        echo "savedconfig-cache: ${entry##*:} not found — skipping ${atom}"
        continue
    fi
    want="$(config_hash "$cfg")"
    pkg_dir="${PKGDIR}/${atom}"
    marker="${pkg_dir}/.savedconfig.sha256"

    case "$MODE" in
        check)
            have="$(cat "$marker" 2>/dev/null || true)"
            have="$(printf '%s' "$have" | tr -d '[:space:]')"
            if [ "$want" != "$have" ]; then
                echo "savedconfig-cache: ${atom} savedconfig changed (${have:-<none>} -> ${want}) — purging local binpkg so it rebuilds from source"
                rm -rf -- "$pkg_dir" || \
                    echo "savedconfig-cache: WARNING: purge failed for ${atom} (build will still rebuild if the cache is absent)" >&2
            else
                echo "savedconfig-cache: ${atom} savedconfig unchanged — keeping cached binpkg"
            fi
            ;;
        mark)
            if mkdir -p "$pkg_dir" && printf '%s\n' "$want" > "$marker" 2>/dev/null; then
                echo "savedconfig-cache: recorded ${atom} savedconfig hash ${want} (${marker})"
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
