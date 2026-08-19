#!/bin/sh
# Unit tests for monolith. Points MONOLITH_SHARE at the in-tree
# files/topics/ directory so no installed rootfs is required.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
BASE="$HERE/../../configs/overlay/app-misc/monolith-base/files"
SCRIPT="$BASE/monolith"
TOPICS_DIR="$BASE/topics"
fails=0
check() { # desc, expected_substr, actual
    if printf '%s' "$3" | grep -qF "$2"; then echo "  ok: $1"
    else echo "  FAIL: $1 (wanted '$2')"; echo "----"; printf '%s\n' "$3"; echo "----"; fails=$((fails+1)); fi
}

export MONOLITH_SHARE="$TOPICS_DIR"

# 1. `monolith` (no args) exits 0
out=$(sh "$SCRIPT" 2>&1); rc=$?
[ "$rc" -eq 0 ] && echo "  ok: bare invocation exits 0" || { echo "  FAIL: bare invocation exit=$rc"; fails=$((fails+1)); }

# 2. `monolith help` exits 0, matches bare invocation, and is under 25 lines
help_out=$(sh "$SCRIPT" help 2>&1); rc=$?
[ "$rc" -eq 0 ] && echo "  ok: help exits 0" || { echo "  FAIL: help exit=$rc"; fails=$((fails+1)); }
[ "$out" = "$help_out" ] && echo "  ok: bare invocation matches 'help'" || { echo "  FAIL: bare invocation != help output"; fails=$((fails+1)); }
nlines=$(printf '%s\n' "$help_out" | wc -l)
if [ "$nlines" -lt 25 ]; then echo "  ok: help is under 25 lines ($nlines)"
else echo "  FAIL: help is $nlines lines (want <25)"; fails=$((fails+1)); fi

# 3. every topic named in the help output's "topics:" line has a matching
#    <topic>.txt file that actually exists.
topics_line=$(printf '%s\n' "$help_out" | grep '^topics:')
check "help advertises a topics line" "topics:" "$topics_line"
topics=$(printf '%s\n' "$topics_line" | sed 's/^topics: *//')
for t in $topics; do
    if [ -f "$TOPICS_DIR/$t.txt" ]; then echo "  ok: topic file exists for '$t'"
    else echo "  FAIL: no $TOPICS_DIR/$t.txt for advertised topic '$t'"; fails=$((fails+1)); fi
done

# 4. `monolith help <topic>` cats the topic file through cat when $PAGER unset
out=$(sh "$SCRIPT" help network 2>&1); rc=$?
[ "$rc" -eq 0 ] && echo "  ok: help network exits 0" || { echo "  FAIL: help network exit=$rc"; fails=$((fails+1)); }
check "help network shows monolith-router" "monolith-router" "$out"

# 5. `monolith tools` lists monolith-router
out=$(sh "$SCRIPT" tools 2>&1); rc=$?
[ "$rc" -eq 0 ] && echo "  ok: tools exits 0" || { echo "  FAIL: tools exit=$rc"; fails=$((fails+1)); }
check "tools lists monolith-router" "monolith-router" "$out"

# 6. unknown topic fails cleanly: nonzero exit, no traceback/garbage, mentions
#    the bad topic name.
out=$(sh "$SCRIPT" help bogus-topic 2>&1); rc=$?
[ "$rc" -ne 0 ] && echo "  ok: unknown topic exits nonzero" || { echo "  FAIL: unknown topic exit=$rc"; fails=$((fails+1)); }
check "unknown topic names itself in the error" "bogus-topic" "$out"

# 7. unknown top-level command fails cleanly too.
out=$(sh "$SCRIPT" bogus-command 2>&1); rc=$?
[ "$rc" -ne 0 ] && echo "  ok: unknown command exits nonzero" || { echo "  FAIL: unknown command exit=$rc"; fails=$((fails+1)); }

# 8. `monolith tools` fails cleanly (nonzero, no traceback) if the share dir
#    has no tools.txt — proves the "missing inventory" path is handled, not
#    just the happy path.
out=$(MONOLITH_SHARE="$HERE" sh "$SCRIPT" tools 2>&1); rc=$?
[ "$rc" -ne 0 ] && echo "  ok: missing tools.txt exits nonzero" || { echo "  FAIL: missing tools.txt exit=$rc"; fails=$((fails+1)); }

echo; [ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
