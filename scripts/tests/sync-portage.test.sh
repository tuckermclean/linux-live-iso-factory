#!/bin/sh
# Unit tests for scripts/sync-portage.sh's fetch/fallback/archive logic.
# Stubs `aws` and `wget` on PATH; asserts source order + archive behavior.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
fails=0
mk_stub() {  # $1=name  $2=body
    printf '#!/bin/sh\n%s\n' "$2" > "$BIN/$1"; chmod +x "$BIN/$1"
}
setup() {
    TMP=$(mktemp -d); BIN="$TMP/bin"; mkdir -p "$BIN"
    export PATH="$BIN:$PATH"
    export SYNC_MIRROR_DIR="$TMP/mirror"; mkdir -p "$SYNC_MIRROR_DIR/snapshots"
    export BUILD_EPOCH=20260811
    export SYNC_S3_PREFIX=portage-snapshots
    export CALLLOG="$TMP/calls"; : > "$CALLLOG"
    . "$HERE/../sync-portage.sh" --source-only
}
teardown() { rm -rf "$TMP"; unset S3_BUCKET; }

# 1. S3 has the files -> used; upstream NOT touched; no archive upload.
setup
export S3_BUCKET=bkt
mk_stub aws 'echo "aws $*" >> "$CALLLOG"; case "$*" in *" cp s3://"*) f="${*##* }"; echo data > "$f"; exit 0;; esac; exit 0'
mk_stub wget 'echo "wget $*" >> "$CALLLOG"; exit 99'   # if wget runs, that is a failure
fetch_snapshot >/dev/null 2>&1 && r=0 || r=1
[ "$r" -eq 0 ] && echo "  ok: S3-hit returns 0" || { echo "  FAIL: S3-hit rc=$r"; fails=$((fails+1)); }
grep -q 'wget' "$CALLLOG" && { echo "  FAIL: upstream fetched despite S3 hit"; fails=$((fails+1)); } || echo "  ok: upstream not touched on S3 hit"
teardown

# 2. S3 miss -> upstream fetch -> archived back to S3.
setup
export S3_BUCKET=bkt
mk_stub aws 'echo "aws $*" >> "$CALLLOG"; case "$*" in *" cp s3://"*/*" "*) exit 1;; *" cp "*" s3://"*) exit 0;; esac; exit 1'
mk_stub wget 'echo "wget $*" >> "$CALLLOG"; f=""; for a in "$@"; do case "$a" in /*) f="$a";; esac; done; echo data > "$f"; exit 0'
fetch_snapshot >/dev/null 2>&1 && r=0 || r=1
[ "$r" -eq 0 ] && echo "  ok: upstream fallback returns 0" || { echo "  FAIL: fallback rc=$r"; fails=$((fails+1)); }
grep -q 'aws .* cp .* s3://' "$CALLLOG" && echo "  ok: fetched snapshot archived to S3" || { echo "  FAIL: not archived"; fails=$((fails+1)); }
teardown

# 3. Neither S3 nor upstream has the .tar.xz -> hard error (non-zero).
setup
export S3_BUCKET=bkt
mk_stub aws 'exit 1'
mk_stub wget 'exit 8'   # 404
fetch_snapshot >/dev/null 2>&1 && r=0 || r=1
[ "$r" -ne 0 ] && echo "  ok: unavailable everywhere -> non-zero" || { echo "  FAIL: should have failed"; fails=$((fails+1)); }
teardown

# 4. No S3_BUCKET set -> upstream only, no aws calls.
setup
mk_stub aws 'echo "aws $*" >> "$CALLLOG"; exit 0'
mk_stub wget 'f=""; for a in "$@"; do case "$a" in /*) f="$a";; esac; done; echo data > "$f"; exit 0'
fetch_snapshot >/dev/null 2>&1 && r=0 || r=1
[ "$r" -eq 0 ] && echo "  ok: no-S3 upstream-only returns 0" || { echo "  FAIL: rc=$r"; fails=$((fails+1)); }
grep -q 'aws' "$CALLLOG" && { echo "  FAIL: aws called without S3_BUCKET"; fails=$((fails+1)); } || echo "  ok: aws not called without S3_BUCKET"
teardown

echo; [ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
