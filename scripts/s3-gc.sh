#!/bin/sh
# S3 garbage collector for The Monolith build bucket.
# classify KEY CURRENT_EPOCH -> "KEEP" | "DELETE"
set -u
classify() {
    key="$1"; cur="$2"
    case "$key" in
        themonolith.iso|themonolith.squashfs|themonolith.vmlinuz|themonolith.initrd) echo KEEP; return;;
        themonolith-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-*) echo DELETE; return;; # <epoch>-<sha> validation
        themonolith-[0-9]*.[0-9]*.[0-9]*.*) echo KEEP; return;;                 # semver release
        packages/"$cur"/*) echo KEEP; return;;
        packages/*) echo DELETE; return;;
        builds/*) echo DELETE; return;;
        attestation/*) echo KEEP; return;;                                       # dashboard history
        *) echo KEEP; return;;                                                   # unknown -> keep (safe)
    esac
}

# --source-only detection: `sh`/dash's `.` (unlike bash) does not propagate
# arguments into the sourced file, so "${1:-}" alone is unreliable for
# detecting `. s3-gc.sh --source-only` under dash. $0 stays as the sourcing
# script's own path under both shells when sourced, so fall back to a
# basename check: if we're not being run as ourselves, treat it as sourced.
case "${0##*/}" in
    s3-gc.sh) sourced=0 ;;
    *) sourced=1 ;;
esac
if [ "${1:-}" = "--source-only" ] || [ "$sourced" -eq 1 ]; then
    return 0
fi
# Live mode: S3_BUCKET + KEEP_EPOCH required. --apply to delete; default dry-run.
BUCKET="${S3_BUCKET:?set S3_BUCKET}"; CUR="${KEEP_EPOCH:?set KEEP_EPOCH}"
APPLY=""; [ "${1:-}" = "--apply" ] && APPLY=1
kept=0; del=0
aws s3 ls "s3://$BUCKET" --recursive | while read -r _ _ _ key; do
    [ -z "$key" ] && continue
    if [ "$(classify "$key" "$CUR")" = DELETE ]; then
        del=$((del+1)); echo "DELETE s3://$BUCKET/$key"
        [ -n "$APPLY" ] && aws s3 rm "s3://$BUCKET/$key"
    fi
done
# Safety: refuse to run if the keep-list would match nothing (mis-set bucket/epoch).
