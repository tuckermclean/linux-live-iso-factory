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

# 5. The legacy .md5sum is OPTIONAL (the GPG .gpgsig is authoritative): required
#    .tar.xz + .gpgsig come from upstream, the .md5sum 404s -> fetch still succeeds
#    and no empty stub file is left behind.
setup
export S3_BUCKET=bkt
mk_stub aws 'exit 1'   # nothing in S3
# wget: serve .tar.xz and .gpgsig, 404 the .md5sum.
mk_stub wget 'f=""; url=""; for a in "$@"; do case "$a" in /*) f="$a";; http://*|https://*) url="$a";; esac; done; case "$url" in *.md5sum) exit 8;; *) echo data > "$f"; exit 0;; esac'
fetch_snapshot >/dev/null 2>&1 && r=0 || r=1
[ "$r" -eq 0 ] && echo "  ok: optional .md5sum absent -> fetch still succeeds" || { echo "  FAIL: md5sum-absent rc=$r"; fails=$((fails+1)); }
[ ! -e "$SYNC_MIRROR_DIR/snapshots/gentoo-20260811.tar.xz.md5sum" ] && echo "  ok: empty .md5sum dropped (not left as a 0-byte stub)" || { echo "  FAIL: stray .md5sum kept"; fails=$((fails+1)); }
teardown

# 6. THE FIX (root cause of the 0% binpkg-cache hit): webrsync_local must run
#    emerge-webrsync against the PINNED localhost mirror over http, with NO
#    upstream in GENTOO_MIRRORS. The old file://+upstream form silently fell back
#    to distfiles.gentoo.org (whose snapshot drifts), invalidating the whole
#    binpkg cache and cold-building every time. This asserts the drift is gone.
setup
mk_stub python3 'exit 0'                              # the http.server (stubbed; wget below fakes readiness)
mk_stub wget 'exit 0'                                 # readiness probe passes immediately
mk_stub emerge-webrsync 'echo "GENTOO_MIRRORS=[$GENTOO_MIRRORS] emerge-webrsync $*" >> "$CALLLOG"; exit 0'
webrsync_local >/dev/null 2>&1 && r=0 || r=1
trap - EXIT INT TERM 2>/dev/null || true             # clear the server-cleanup trap webrsync_local set in our shell
[ "$r" -eq 0 ] && echo "  ok: webrsync_local returns 0" || { echo "  FAIL: webrsync_local rc=$r"; fails=$((fails+1)); }
grep -q 'GENTOO_MIRRORS=\[http://127.0.0.1:8899\]' "$CALLLOG" && echo "  ok: emerge-webrsync uses the pinned localhost http mirror" || { echo "  FAIL: not pinned to localhost:"; cat "$CALLLOG"; fails=$((fails+1)); }
grep -q 'distfiles.gentoo.org' "$CALLLOG" && { echo "  FAIL: upstream present in GENTOO_MIRRORS -> tree can drift"; fails=$((fails+1)); } || echo "  ok: NO upstream in GENTOO_MIRRORS (deterministic, no drift)"
grep -q 'revert=20260811' "$CALLLOG" && echo "  ok: reverts to the pinned BUILD_EPOCH" || { echo "  FAIL: no --revert=<epoch>"; fails=$((fails+1)); }
teardown

echo; [ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
