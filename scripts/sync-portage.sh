#!/bin/sh
# Resilient, DETERMINISTIC self-hosted portage-snapshot sync. Fetches the pinned
# BUILD_EPOCH snapshot from OUR S3 first (immune to Gentoo mirror pruning),
# upstream as fallback (archiving upstream -> S3 for next time), then feeds it to
# emerge-webrsync served over a throwaway LOCAL HTTP server with NO upstream in
# GENTOO_MIRRORS — so the tree is pinned to exactly our snapshot every build.
#
# WHY NOT the old `GENTOO_MIRRORS="file://<mirror> <upstream>"`: emerge-webrsync's
# fetcher cannot read file:// URLs (it prints "Unsupported scheme" on every
# gentoo-DATE.tar.xz.md5sum) and SILENTLY falls back to https://distfiles.gentoo.org
# — whose "gentoo-DATE" snapshot DRIFTS as Gentoo re-rolls it. That made the tree
# non-deterministic between builds, which invalidated 100% of the binary-package
# cache (binpkgs built against tree-A are rejected once the tree drifts to tree-B),
# turned every build fully cold, and exposed each build to whatever broke upstream
# that hour (e.g. a dev-cpp/eigen-9999 patch pulled in via a source-built package's
# BDEPEND). Serving the PINNED tarball over http:// (which the fetcher CAN read)
# with upstream removed restores determinism: a bad/missing pin now fails LOUD.
set -u

: "${SYNC_MIRROR_DIR:=/var/monolith-portage-mirror}"
: "${SYNC_UPSTREAM:=https://distfiles.gentoo.org/snapshots}"
: "${SYNC_S3_PREFIX:=portage-snapshots}"
: "${SYNC_HTTP_PORT:=8899}"

# _fetch_one FILE REQUIRED: ensure $SYNC_MIRROR_DIR/snapshots/FILE exists — from
# our S3 first, then upstream (archiving upstream->S3 so the next build survives
# Gentoo pruning). REQUIRED=1 -> a total miss is fatal (return 1). REQUIRED=0 ->
# best-effort (return 0, drop the empty dst). Idempotent.
_fetch_one() {
    _f="$1"; _required="$2"
    _dst="$SYNC_MIRROR_DIR/snapshots/$_f"
    [ -s "$_dst" ] && return 0
    if [ -n "${S3_BUCKET:-}" ] && aws s3 cp "s3://$S3_BUCKET/$SYNC_S3_PREFIX/$_f" "$_dst" >/dev/null 2>&1; then
        echo "  sync-portage: $_f <- s3://$S3_BUCKET/$SYNC_S3_PREFIX/"
        return 0
    fi
    if wget -q -O "$_dst" "$SYNC_UPSTREAM/$_f"; then
        echo "  sync-portage: $_f <- upstream ($SYNC_UPSTREAM)"
        # Archive back to our S3 so the next build survives upstream pruning. The
        # local fetch already succeeded, so a failed archive must NOT fail the
        # build — but it must be LOUD (a silent miss means the pruning-resilience
        # net was never laid for this epoch, discovered only much later).
        if [ -n "${S3_BUCKET:-}" ]; then
            if aws s3 cp "$_dst" "s3://$S3_BUCKET/$SYNC_S3_PREFIX/$_f" >/dev/null 2>&1; then
                echo "  sync-portage: archived $_f -> s3://$S3_BUCKET/$SYNC_S3_PREFIX/"
            else
                echo "::warning::sync-portage: FAILED to archive $_f to s3://$S3_BUCKET/$SYNC_S3_PREFIX/ — pruning-resilience safety net NOT laid for epoch ${BUILD_EPOCH:-?}" >&2
            fi
        fi
        return 0
    fi
    rm -f "$_dst"
    if [ "$_required" = 1 ]; then
        echo "sync-portage: FATAL — $_f not in our S3 nor upstream; epoch ${BUILD_EPOCH:-?} is unrecoverable" >&2
        return 1
    fi
    echo "  sync-portage: $_f absent everywhere (optional — the GPG .gpgsig is authoritative)"
    return 0
}

# fetch_snapshot: ensure the pinned snapshot (required), its detached GPG sig
# (required — this is the real verification), and the legacy .md5sum (optional)
# are in the local mirror. Returns non-zero only if a REQUIRED file is missing
# everywhere. Idempotent.
fetch_snapshot() {
    _epoch="${BUILD_EPOCH:?BUILD_EPOCH must be set}"
    mkdir -p "$SYNC_MIRROR_DIR/snapshots"
    _snap="gentoo-${_epoch}.tar.xz"
    _fetch_one "$_snap"         1 || return 1
    _fetch_one "$_snap.gpgsig"  1 || return 1
    _fetch_one "$_snap.md5sum"  0 || true
    return 0
}

# webrsync_local: serve the pinned mirror over http on 127.0.0.1 and run
# emerge-webrsync against ONLY that (no upstream). emerge-webrsync still does the
# GPG verify + extraction it always did — we only fix the transport (http, which
# its fetcher CAN read, vs file:// which it CANNOT) and remove the upstream drift.
# Runs INSIDE the builder container (needs emerge-webrsync + python3 + wget).
webrsync_local() {
    _epoch="${BUILD_EPOCH:?BUILD_EPOCH must be set}"
    _port="$SYNC_HTTP_PORT"
    ( cd "$SYNC_MIRROR_DIR" && exec python3 -m http.server "$_port" --bind 127.0.0.1 ) >/dev/null 2>&1 &
    _srv=$!
    # shellcheck disable=SC2064
    trap "kill $_srv 2>/dev/null || true" EXIT INT TERM
    # Wait (up to ~10s) until the server is actually serving the pinned snapshot.
    _i=0
    while ! wget -q -O /dev/null "http://127.0.0.1:$_port/snapshots/gentoo-${_epoch}.tar.xz.gpgsig" 2>/dev/null; do
        _i=$((_i + 1))
        if [ "$_i" -ge 100 ]; then
            echo "sync-portage: FATAL — local http mirror never served the pinned snapshot on 127.0.0.1:$_port" >&2
            return 1
        fi
        sleep 0.1
    done
    echo "==> emerge-webrsync --revert=$_epoch (pinned local mirror over http://127.0.0.1:$_port, NO upstream)"
    GENTOO_MIRRORS="http://127.0.0.1:$_port" emerge-webrsync --revert="$_epoch"
}

# --source-only detection: `sh`/dash's `.` (unlike bash) does not propagate
# arguments into the sourced file, so "${1:-}" alone is unreliable for detecting
# `. sync-portage.sh --source-only` under dash. $0 stays as the sourcing script's
# own path under both shells when sourced, so fall back to a basename check: if
# we're not being run as ourselves, treat it as sourced.
case "${0##*/}" in
    sync-portage.sh) sourced=0 ;;
    *) sourced=1 ;;
esac
if [ "${1:-}" = "--source-only" ] || [ "$sourced" -eq 1 ]; then
    return 0
fi

case "${1:-}" in
    fetch-only)
        # Populate the mirror and exit (host-side; uses aws + wget). The Makefile
        # calls this on the host, then `webrsync-local` inside the container.
        fetch_snapshot
        exit $?
        ;;
    webrsync-local)
        # In-container: serve the already-populated mirror over http + webrsync.
        webrsync_local
        exit $?
        ;;
    *)
        # Live mode: fetch (host tools) then serve+webrsync. Needs emerge-webrsync
        # + python3, so this whole-in-one path only works inside the builder image.
        fetch_snapshot || exit 1
        webrsync_local
        exit $?
        ;;
esac
