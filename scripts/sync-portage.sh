#!/bin/sh
# Resilient self-hosted portage-snapshot sync. Populates the local mirror dir
# with the pinned BUILD_EPOCH snapshot from OUR S3 first (immune to Gentoo
# mirror pruning), upstream as fallback (archiving upstream -> S3 for next
# time), then hands it to emerge-webrsync which does GPG verify + extraction.
set -u

: "${SYNC_MIRROR_DIR:=/var/monolith-portage-mirror}"
: "${SYNC_UPSTREAM:=https://distfiles.gentoo.org/snapshots}"
: "${SYNC_S3_PREFIX:=portage-snapshots}"

# fetch_snapshot: ensure gentoo-$BUILD_EPOCH.tar.xz + .gpgsig are in the local
# mirror. Returns 0 on success, non-zero if a required file is unavailable
# everywhere. Idempotent.
fetch_snapshot() {
    _epoch="${BUILD_EPOCH:?BUILD_EPOCH must be set}"
    _snapdir="$SYNC_MIRROR_DIR/snapshots"
    mkdir -p "$_snapdir"
    _snap="gentoo-${_epoch}.tar.xz"
    # .gpgsig is required (GPG verify); .md5sum is optional on modern mirrors.
    for _f in "$_snap" "$_snap.gpgsig"; do
        _dst="$_snapdir/$_f"
        [ -s "$_dst" ] && continue
        # 1) our S3 mirror first
        if [ -n "${S3_BUCKET:-}" ] && aws s3 cp "s3://$S3_BUCKET/$SYNC_S3_PREFIX/$_f" "$_dst" >/dev/null 2>&1; then
            echo "  sync-portage: $_f <- s3://$S3_BUCKET/$SYNC_S3_PREFIX/"
            continue
        fi
        # 2) upstream, then archive to S3
        if wget -q -O "$_dst" "$SYNC_UPSTREAM/$_f"; then
            echo "  sync-portage: $_f <- upstream ($SYNC_UPSTREAM)"
            # Archive back to our S3 so the next build survives upstream pruning.
            # The local fetch already succeeded, so a failed archive must NOT fail
            # the build — but it must be LOUD: a silent miss here means the
            # pruning-resilience safety net was never laid for this epoch, and we
            # only discover it much later when upstream has pruned and our S3 also
            # lacks it. Surface it as a CI ::warning:: instead of swallowing it.
            if [ -n "${S3_BUCKET:-}" ]; then
                if aws s3 cp "$_dst" "s3://$S3_BUCKET/$SYNC_S3_PREFIX/$_f" >/dev/null 2>&1; then
                    echo "  sync-portage: archived $_f -> s3://$S3_BUCKET/$SYNC_S3_PREFIX/"
                else
                    echo "::warning::sync-portage: FAILED to archive $_f to s3://$S3_BUCKET/$SYNC_S3_PREFIX/ — pruning-resilience safety net NOT laid for epoch $_epoch" >&2
                fi
            fi
            continue
        fi
        rm -f "$_dst"
        echo "sync-portage: FATAL — $_f not in our S3 nor upstream; epoch $_epoch is unrecoverable" >&2
        return 1
    done
    return 0
}

# --source-only detection: `sh`/dash's `.` (unlike bash) does not propagate
# arguments into the sourced file, so "${1:-}" alone is unreliable for
# detecting `. sync-portage.sh --source-only` under dash. $0 stays as the
# sourcing script's own path under both shells when sourced, so fall back to
# a basename check: if we're not being run as ourselves, treat it as sourced.
case "${0##*/}" in
    sync-portage.sh) sourced=0 ;;
    *) sourced=1 ;;
esac
if [ "${1:-}" = "--source-only" ] || [ "$sourced" -eq 1 ]; then
    return 0
fi

# fetch-only mode: populate the mirror and exit, without invoking
# emerge-webrsync. Used by the Makefile's host-side snapshot-prep step.
if [ "${1:-}" = "fetch-only" ]; then
    fetch_snapshot
    exit $?
fi

# Live mode: fetch, then emerge-webrsync from the local mirror (upstream fallback).
fetch_snapshot || exit 1
echo "==> emerge-webrsync --revert=$BUILD_EPOCH (mirror: self-hosted, fallback: upstream)"
GENTOO_MIRRORS="file://$SYNC_MIRROR_DIR ${SYNC_UPSTREAM%/snapshots}" emerge-webrsync --revert="$BUILD_EPOCH"
