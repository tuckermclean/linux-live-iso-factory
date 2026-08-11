#!/bin/sh
set -u
. "$(dirname "$0")/../s3-gc.sh" --source-only
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
[ "$fails" -eq 0 ] && echo ALL PASS || { echo "$fails FAILED"; exit 1; }
