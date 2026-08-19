#!/bin/sh
# Unit tests for /etc/bash/bashrc.d/50-persist-history.bash (Monolith UX
# Pass Task 3 — the history-reliability half, split out of
# /etc/profile.d/20-persist.sh; see 50-persist-history.bash's own header
# for why: bashrc.d runs AFTER the stock /etc/bash/bashrc, so PROMPT_COMMAND
# wiring placed here can't be silently clobbered by whatever the stock
# bashrc assigns).
#
# Sourced inside `bash -i -c '...'` (interactive flag forced, no real tty
# needed), same technique as monolith-persist-profile.test.sh.
# MONOLITH_PERSIST_DIR / MONOLITH_PERSIST_MOUNTS override the mountpoint
# and mount-table path checked (see the script's own header) so no real
# /overlay or /proc/mounts is touched.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../../configs/overlay/app-misc/monolith-base/files/50-persist-history.bash"
fails=0
has() { if printf '%s' "$2" | grep -qF -- "$1"; then echo "  ok: $3"; else echo "  FAIL: $3 (wanted '$1')"; echo "----"; printf '%s\n' "$2"; echo "----"; fails=$((fails+1)); fi; }

setup() {
    TMP=$(mktemp -d)
    MOUNTDIR="$TMP/overlay"; mkdir -p "$MOUNTDIR"
    MOUNTSFILE="$TMP/mounts"
}
teardown() { rm -rf "$TMP"; }

# Sources $SCRIPT inside an interactive bash (no real tty required) with
# MONOLITH_PERSIST_DIR/MONOLITH_PERSIST_MOUNTS pointed at the fixtures, then
# runs $1 (extra bash to print out whatever the test wants to assert on).
# stderr is discarded (bash -i without a tty logs harmless job-control
# warnings that would otherwise pollute every assertion).
# --norc below is LOAD-BEARING: without it, `bash -i` sources the caller's
# ~/.bashrc / /etc/bash.bashrc, and a runner whose default bashrc does
# `shopt -s histappend` (e.g. Ubuntu's) makes histappend already-set BEFORE
# the snippet runs — the test would then measure the runner's dotfiles, not
# our code (passes locally, fails in CI). --norc gives a clean, environment-
# independent baseline. Do not remove.
source_it() {
    MONOLITH_PERSIST_DIR="$MOUNTDIR" MONOLITH_PERSIST_MOUNTS="$MOUNTSFILE" \
        bash --norc -i -c ". '$SCRIPT'; $1" </dev/null 2>/dev/null
}

# Same, but as a NON-interactive bash -- proves the whole file is a no-op
# outside a login shell.
source_it_noninteractive() {
    MONOLITH_PERSIST_DIR="$MOUNTDIR" MONOLITH_PERSIST_MOUNTS="$MOUNTSFILE" \
        bash -c ". '$SCRIPT'; $1" </dev/null 2>/dev/null
}

# 1. tmpfs overlay -> no history-append wiring
setup
printf 'none %s tmpfs rw 0 0\n' "$MOUNTDIR" > "$MOUNTSFILE"
pc=$(source_it 'echo "PC=[$PROMPT_COMMAND]"')
has 'PC=[]' "$pc" "tmpfs leaves PROMPT_COMMAND untouched"
histappend_rc=$(source_it 'shopt -q histappend; echo $?' | tail -n1)
[ "$histappend_rc" = "1" ] && echo "  ok: tmpfs leaves histappend unset" || { echo "  FAIL: histappend rc=$histappend_rc (want 1/unset)"; fails=$((fails+1)); }
teardown

# 2. real persist partition -> histappend + history -a wired into PROMPT_COMMAND
setup
printf '/dev/fake1 %s ext4 rw 0 0\n' "$MOUNTDIR" > "$MOUNTSFILE"
pc=$(source_it 'echo "PC=[$PROMPT_COMMAND]"')
has 'history -a' "$pc" "real fs wires history -a into PROMPT_COMMAND"
histappend_rc=$(source_it 'shopt -q histappend; echo $?' | tail -n1)
[ "$histappend_rc" = "0" ] && echo "  ok: real fs enables histappend" || { echo "  FAIL: histappend rc=$histappend_rc (want 0/set)"; fails=$((fails+1)); }
teardown

# 3. sourcing twice does not duplicate the PROMPT_COMMAND wiring (idempotent
#    — bashrc.d is sourced once per shell startup in practice, but this
#    proves the guard works if it ever were sourced again).
setup
printf '/dev/fake1 %s ext4 rw 0 0\n' "$MOUNTDIR" > "$MOUNTSFILE"
pc=$(source_it ". '$SCRIPT'; echo \"PC=[\$PROMPT_COMMAND]\"")
count=$(printf '%s' "$pc" | grep -o 'history -a' | wc -l | tr -d ' ')
[ "$count" = "1" ] && echo "  ok: double-source does not duplicate history -a (count=1)" || { echo "  FAIL: history -a appears $count times (want 1)"; fails=$((fails+1)); }
teardown

# 4. real persist partition, but an existing PROMPT_COMMAND (as the stock
#    bashrc might have already set) is PRESERVED, not clobbered -- this is
#    the whole reason the file moved to bashrc.d.
setup
printf '/dev/fake1 %s ext4 rw 0 0\n' "$MOUNTDIR" > "$MOUNTSFILE"
pc=$(source_it 'PROMPT_COMMAND="some_stock_bashrc_thing"; . '"'$SCRIPT'"'; echo "PC=[$PROMPT_COMMAND]"')
has 'some_stock_bashrc_thing' "$pc" "pre-existing PROMPT_COMMAND is preserved, not overwritten"
has 'history -a' "$pc" "history -a is still added alongside the pre-existing PROMPT_COMMAND"
teardown

# 5. non-interactive shell -> completely silent, no PROMPT_COMMAND wiring
setup
printf '/dev/fake1 %s ext4 rw 0 0\n' "$MOUNTDIR" > "$MOUNTSFILE"
out=$(source_it_noninteractive 'true')
[ -z "$out" ] && echo "  ok: non-interactive sourcing prints nothing" || { echo "  FAIL: non-interactive printed: $out"; fails=$((fails+1)); }
pc=$(source_it_noninteractive 'echo "PC=[$PROMPT_COMMAND]"')
has 'PC=[]' "$pc" "non-interactive leaves PROMPT_COMMAND untouched"
teardown

# 6. missing mount-table file -> no wiring, does not abort the shell
setup
rm -f "$MOUNTSFILE"
out=$(source_it 'echo "SURVIVED=$?"')
has 'SURVIVED=0' "$out" "sourcing with a missing mount table does not abort the shell"
pc=$(source_it 'echo "PC=[$PROMPT_COMMAND]"')
has 'PC=[]' "$pc" "missing mount table leaves PROMPT_COMMAND untouched"
teardown

echo; [ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
