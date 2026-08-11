#!/bin/sh
set -u
HERE="$(dirname "$0")"
. "$HERE/../s3-gc.sh" --source-only
fails=0
keep() { classify "$1" "$2" | grep -q KEEP   || { echo "FAIL keep: $1"; fails=$((fails+1)); }; }
del()  { classify "$1" "$2" | grep -q DELETE || { echo "FAIL del:  $1"; fails=$((fails+1)); }; }
CUR=20260803
keep "themonolith.iso" "$CUR"                          # latest pointer
keep "themonolith-0.0.1.iso" "$CUR"                     # semver release
keep "packages/20260803/foo.gpkg.tar" "$CUR"           # current epoch
del  "themonolith-20260803-abc12.iso" "$CUR"           # validation artifact
del  "packages/20260727/foo.gpkg.tar" "$CUR"           # old epoch
del  "builds/20260727-abc12/logs/x.log" "$CUR"         # old build logs
keep "themonolith-20260803-1.2.3.iso" "$CUR"           # ambiguous (epoch-sha AND semver-ish) must be KEPT, not deleted

# --- live-mode exit-status tests (stub `aws` so nothing real is called) ---

# dry-run must exit 0 even when the last classified key is a DELETE candidate
TMPBIN=$(mktemp -d)
printf '#!/bin/sh\n[ "$1" = s3 ] && [ "$2" = ls ] && { echo "d t 1 themonolith.iso"; echo "d t 1 themonolith-20260727-abc.iso"; exit 0; }\nexit 0\n' > "$TMPBIN/aws"; chmod +x "$TMPBIN/aws"
PATH="$TMPBIN:$PATH" S3_BUCKET=x KEEP_EPOCH=20260803 sh "$HERE/../s3-gc.sh" >/dev/null 2>&1
[ $? -eq 0 ] && echo "  ok: dry-run exits 0 with DELETE-last" || { echo "  FAIL: dry-run exit nonzero"; fails=$((fails+1)); }
rm -rf "$TMPBIN"

# abort guard: keep-list matching nothing must exit 1 (mis-set bucket/epoch)
TMPBIN=$(mktemp -d)
printf '#!/bin/sh\n[ "$1" = s3 ] && [ "$2" = ls ] && { echo "d t 1 packages/19990101/foo.gpkg.tar"; echo "d t 1 builds/19990101-deadbe/logs/x.log"; exit 0; }\nexit 0\n' > "$TMPBIN/aws"; chmod +x "$TMPBIN/aws"
PATH="$TMPBIN:$PATH" S3_BUCKET=x KEEP_EPOCH=20260803 sh "$HERE/../s3-gc.sh" >/dev/null 2>&1
[ $? -eq 1 ] && echo "  ok: abort guard exits 1 with all-DELETE listing" || { echo "  FAIL: abort guard did not exit 1"; fails=$((fails+1)); }
rm -rf "$TMPBIN"

[ "$fails" -eq 0 ] && echo ALL PASS || { echo "$fails FAILED"; exit 1; }
