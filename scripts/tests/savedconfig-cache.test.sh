#!/bin/sh
# Unit tests for savedconfig-cache.sh's local (GHCR-store-era) check/mark
# modes. Drives it as a subprocess against an isolated tmp PKGDIR — no S3, no
# network, no root. Uses the real TRACKED savedconfig file (sys-apps/busybox)
# so the hash under test matches what the script itself would compute; this
# test only fabricates the PKGDIR side (a fake gpkg + marker), never the repo
# file.
set -u
HERE="$(dirname "$0")"
SCRIPT="$HERE/../savedconfig-cache.sh"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
CFG="$REPO_ROOT/configs/portage/savedconfig/sys-apps/busybox"
ATOM_DIR="sys-apps/busybox"
fails=0

if [ ! -f "$CFG" ]; then
    echo "SKIP: $CFG not found (savedconfig-cache.sh's TRACKED list changed?) — nothing to test against"
    exit 0
fi
WANT="$(sha256sum "$CFG" | cut -c1-64)"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
PKGDIR="$TMPDIR/packages"
FAKE_GPKG="$PKGDIR/$ATOM_DIR/busybox-1.36.1-1.gpkg.tar"
MARKER="$PKGDIR/$ATOM_DIR/.savedconfig.sha256"

fresh_pkg() {
    rm -rf "$PKGDIR"
    mkdir -p "$PKGDIR/$ATOM_DIR"
    : > "$FAKE_GPKG"
}

# --- check with no marker at all is a mismatch -> purges the atom dir ---
fresh_pkg
bash "$SCRIPT" check "$PKGDIR" >/dev/null 2>&1
if [ -e "$FAKE_GPKG" ]; then
    echo "FAIL: check with no marker should purge the gpkg (missing marker == mismatch)"
    fails=$((fails + 1))
fi

# --- mark records the current savedconfig hash next to the gpkgs ---
fresh_pkg
bash "$SCRIPT" mark "$PKGDIR" >/dev/null 2>&1
GOT="$(cat "$MARKER" 2>/dev/null | tr -d '[:space:]')"
if [ "$GOT" != "$WANT" ]; then
    echo "FAIL: mark did not record the expected hash (got '${GOT}', want '${WANT}')"
    fails=$((fails + 1))
fi

# --- check with a matching marker keeps the cached gpkg (and the marker) ---
bash "$SCRIPT" check "$PKGDIR" >/dev/null 2>&1
if [ ! -e "$FAKE_GPKG" ]; then
    echo "FAIL: check purged a gpkg whose marker hash matched"
    fails=$((fails + 1))
fi
if [ ! -e "$MARKER" ]; then
    echo "FAIL: marker should survive a matching check (not just the gpkg)"
    fails=$((fails + 1))
fi

# --- check with a stale marker (savedconfig changed) purges the whole atom dir ---
printf '%s\n' "0000000000000000000000000000000000000000000000000000000000000000" > "$MARKER"
bash "$SCRIPT" check "$PKGDIR" >/dev/null 2>&1
if [ -e "$FAKE_GPKG" ] || [ -e "$MARKER" ] || [ -e "$PKGDIR/$ATOM_DIR" ]; then
    echo "FAIL: check with a stale marker should rm -rf the whole atom dir (gpkg + marker)"
    fails=$((fails + 1))
fi

# --- an unknown mode exits non-zero (2) rather than silently doing nothing ---
fresh_pkg
bash "$SCRIPT" bogus "$PKGDIR" >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 2 ]; then
    echo "FAIL: unknown mode should exit 2, got $rc"
    fails=$((fails + 1))
fi

[ "$fails" -eq 0 ] && echo ALL PASS || { echo "$fails FAILED"; exit 1; }
