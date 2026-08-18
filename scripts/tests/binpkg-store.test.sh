#!/bin/sh
# Unit tests for binpkg-store.sh's pure prune predicate.
# Drives it as a subprocess (it's a bash script; this test is POSIX sh, per
# repo convention) via its `prune-predicate` subcommand: stdin is a
# newline-delimited listing of PKGDIR-relative gpkg paths, stdout is the
# subset that would be DELETED. No filesystem mutation, no network, no root.
set -u
HERE="$(dirname "$0")"
SCRIPT="$HERE/../binpkg-store.sh"
fails=0

# run_predicate LISTING [LOCKFILE] — sets $OUT to the newline-delimited
# DELETE list for LISTING (and, if given, pins from LOCKFILE).
run_predicate() {
    if [ -n "${2:-}" ]; then
        OUT="$(printf '%s\n' "$1" | bash "$SCRIPT" prune-predicate "$2")"
    else
        OUT="$(printf '%s\n' "$1" | bash "$SCRIPT" prune-predicate)"
    fi
}

# check DESC EXPECT(KEEP|DELETE) PATH — checks PATH's presence in $OUT.
check() {
    desc="$1"; expect="$2"; path="$3"
    if printf '%s\n' "$OUT" | grep -qxF "$path"; then
        got=DELETE
    else
        got=KEEP
    fi
    if [ "$got" != "$expect" ]; then
        echo "FAIL: $desc -- expected '$path' to be $expect, got $got"
        fails=$((fails + 1))
    fi
}

# --- multiple PVRs of the same CAT/PN: only the newest survives ---
LISTING1="net-dns/dnsmasq/dnsmasq-2.88-5.gpkg.tar
net-dns/dnsmasq/dnsmasq-2.90-6.gpkg.tar"
run_predicate "$LISTING1"
check "older PVR pruned"     DELETE "net-dns/dnsmasq/dnsmasq-2.88-5.gpkg.tar"
check "newest PVR kept"      KEEP   "net-dns/dnsmasq/dnsmasq-2.90-6.gpkg.tar"

# --- a -rN revision beats its base version ---
LISTING2="net-dns/dnsmasq/dnsmasq-2.90-6.gpkg.tar
net-dns/dnsmasq/dnsmasq-2.90-r1-7.gpkg.tar"
run_predicate "$LISTING2"
check "base version pruned when -r1 exists" DELETE "net-dns/dnsmasq/dnsmasq-2.90-6.gpkg.tar"
check "-r1 revision kept as newest"         KEEP   "net-dns/dnsmasq/dnsmasq-2.90-r1-7.gpkg.tar"

# --- Gentoo suffix ordering: _p beats plain, plain beats _rc ---
LISTING3A="sys-libs/foo/foo-1.0-2.gpkg.tar
sys-libs/foo/foo-1.0_p20260805-1.gpkg.tar"
run_predicate "$LISTING3A"
check "plain 1.0 pruned when _p20260805 exists" DELETE "sys-libs/foo/foo-1.0-2.gpkg.tar"
check "_p20260805 kept as newest"               KEEP   "sys-libs/foo/foo-1.0_p20260805-1.gpkg.tar"

LISTING3B="sys-libs/bar/bar-1.0_rc1-2.gpkg.tar
sys-libs/bar/bar-1.0-1.gpkg.tar"
run_predicate "$LISTING3B"
check "_rc1 pruned when plain 1.0 exists" DELETE "sys-libs/bar/bar-1.0_rc1-2.gpkg.tar"
check "plain 1.0 kept as newest"          KEEP   "sys-libs/bar/bar-1.0-1.gpkg.tar"

# --- a versions.lock pin that is NOT the newest PVR is never deleted ---
LOCKFILE="$(mktemp)"
printf '# fixture pin\napp-misc/foo:1.0:0\n' > "$LOCKFILE"
LISTING4="app-misc/foo/foo-1.0-1.gpkg.tar
app-misc/foo/foo-2.0-2.gpkg.tar"
run_predicate "$LISTING4" "$LOCKFILE"
check "pinned 1.0 survives even though 2.0 is newer" KEEP "app-misc/foo/foo-1.0-1.gpkg.tar"
check "newest 2.0 also survives"                     KEEP "app-misc/foo/foo-2.0-2.gpkg.tar"
rm -f "$LOCKFILE"

# --- multiple distinct packages don't interfere with each other's pruning ---
LISTING5="net-dns/dnsmasq/dnsmasq-2.88-5.gpkg.tar
net-dns/dnsmasq/dnsmasq-2.90-6.gpkg.tar
app-arch/tar/tar-1.34-1.gpkg.tar
app-arch/tar/tar-1.35-r1-2.gpkg.tar"
run_predicate "$LISTING5"
check "dnsmasq 2.88 still pruned in a mixed listing" DELETE "net-dns/dnsmasq/dnsmasq-2.88-5.gpkg.tar"
check "dnsmasq 2.90 still kept in a mixed listing"   KEEP   "net-dns/dnsmasq/dnsmasq-2.90-6.gpkg.tar"
check "unrelated group: tar 1.34 pruned"             DELETE "app-arch/tar/tar-1.34-1.gpkg.tar"
check "unrelated group: tar 1.35-r1 kept"            KEEP   "app-arch/tar/tar-1.35-r1-2.gpkg.tar"

# --- an unparseable line is skipped (warning on stderr), not fatal ---
LISTING6="not-a-valid-path
net-dns/dnsmasq/dnsmasq-2.90-6.gpkg.tar"
OUT="$(printf '%s\n' "$LISTING6" | bash "$SCRIPT" prune-predicate 2>/dev/null)"
check "malformed entry never appears in the delete list" KEEP "not-a-valid-path"
check "valid sibling entry still processed normally"      KEEP "net-dns/dnsmasq/dnsmasq-2.90-6.gpkg.tar"

[ "$fails" -eq 0 ] && echo ALL PASS || { echo "$fails FAILED"; exit 1; }
