#!/bin/sh
set -u
HERE="$(dirname "$0")"
. "$HERE/../ghcr-gc.sh" --source-only
fails=0
keep() { classify "$1" "$2" | grep -q KEEP   || { echo "FAIL keep: $1"; fails=$((fails+1)); }; }
del()  { classify "$1" "$2" | grep -q DELETE || { echo "FAIL del:  $1"; fails=$((fails+1)); }; }
CUR=20260803
keep "$CUR" "$CUR"                 # current epoch
del  "20260727" "$CUR"             # old 8-digit epoch
keep "latest" "$CUR"               # non-epoch tag
keep "v1.2.3" "$CUR"               # non-epoch tag (semver-ish)
keep "202608031" "$CUR"            # 9 digits, not exactly 8 -> ambiguous, KEEP-first
keep "2026080" "$CUR"              # 7 digits, not exactly 8 -> ambiguous, KEEP-first

# --- live-mode exit-status tests (stub `gh` so nothing real is called) ---

# normal dry-run: one current tag (KEEP) + one old-epoch-only version (DELETE) -> exit 0
TMPBIN=$(mktemp -d)
cat > "$TMPBIN/gh" <<'STUB'
#!/bin/sh
case "$*" in
    *"--method DELETE"*) exit 0 ;;
    *"/versions"*) printf '1\t20260803\n2\t20260727\n'; exit 0 ;;
esac
exit 0
STUB
chmod +x "$TMPBIN/gh"
PATH="$TMPBIN:$PATH" KEEP_EPOCH=20260803 GITHUB_REPOSITORY_OWNER=Owner sh "$HERE/../ghcr-gc.sh" >/dev/null 2>&1
[ $? -eq 0 ] && echo "  ok: dry-run exits 0 with mixed KEEP/DELETE" || { echo "  FAIL: dry-run exit nonzero"; fails=$((fails+1)); }
rm -rf "$TMPBIN"

# abort guard: keep-list matching nothing must exit 1 (mis-set epoch/owner)
TMPBIN=$(mktemp -d)
cat > "$TMPBIN/gh" <<'STUB'
#!/bin/sh
case "$*" in
    *"--method DELETE"*) exit 0 ;;
    *"/versions"*) printf '1\t20260727\n2\t20260101\n'; exit 0 ;;
esac
exit 0
STUB
chmod +x "$TMPBIN/gh"
PATH="$TMPBIN:$PATH" KEEP_EPOCH=20260803 GITHUB_REPOSITORY_OWNER=Owner sh "$HERE/../ghcr-gc.sh" >/dev/null 2>&1
[ $? -eq 1 ] && echo "  ok: abort guard exits 1 with all-DELETE listing" || { echo "  FAIL: abort guard did not exit 1"; fails=$((fails+1)); }
rm -rf "$TMPBIN"

# 404 on the package listing (never pushed yet) must exit 0, not hard-fail
TMPBIN=$(mktemp -d)
cat > "$TMPBIN/gh" <<'STUB'
#!/bin/sh
case "$*" in
    *"/versions"*) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
esac
exit 0
STUB
chmod +x "$TMPBIN/gh"
PATH="$TMPBIN:$PATH" KEEP_EPOCH=20260803 GITHUB_REPOSITORY_OWNER=Owner sh "$HERE/../ghcr-gc.sh" >/dev/null 2>&1
[ $? -eq 0 ] && echo "  ok: 404 package listing exits 0 (not pushed yet)" || { echo "  FAIL: 404 listing did not exit 0"; fails=$((fails+1)); }
rm -rf "$TMPBIN"

# tag-aggregation: a version with one DELETE-shaped tag and one KEEP (non-epoch)
# tag must be kept in full (KEEP-first at the version level), never printed as DELETE
TMPBIN=$(mktemp -d)
cat > "$TMPBIN/gh" <<'STUB'
#!/bin/sh
case "$*" in
    *"--method DELETE"*) exit 0 ;;
    *"/versions"*) printf '5\t20260727,latest\n'; exit 0 ;;
esac
exit 0
STUB
chmod +x "$TMPBIN/gh"
OUT=$(PATH="$TMPBIN:$PATH" KEEP_EPOCH=20260803 GITHUB_REPOSITORY_OWNER=Owner sh "$HERE/../ghcr-gc.sh" 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && ! printf '%s' "$OUT" | grep -q DELETE; then
    echo "  ok: mixed-tag version (one KEEP tag) is kept, not deleted"
else
    echo "  FAIL: mixed-tag version should be kept (rc=$rc out=$OUT)"; fails=$((fails+1))
fi
rm -rf "$TMPBIN"

[ "$fails" -eq 0 ] && echo ALL PASS || { echo "$fails FAILED"; exit 1; }
