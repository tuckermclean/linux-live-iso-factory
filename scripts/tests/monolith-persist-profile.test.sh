#!/bin/sh
# Unit tests for /etc/profile.d/20-persist.sh (Monolith UX Pass Task 3).
#
# Login STATUS line only -- the history-reliability half was split out to
# /etc/bash/bashrc.d/50-persist-history.bash (see that file's header, and
# scripts/tests/monolith-persist-bashrc.test.sh) so a profile.d snippet's
# PROMPT_COMMAND wiring can't be silently clobbered by Gentoo's stock
# /etc/bash/bashrc, which /etc/profile sources AFTER profile.d/*.sh.
#
# The file is meant to be SOURCED by an interactive login bash, not
# executed — so these tests source it inside `bash -i -c '...'` (interactive
# flag forced, no real tty needed) and assert on stdout + (as a negative
# check) that this file leaves PROMPT_COMMAND/histappend alone, proving the
# split is clean. MONOLITH_PERSIST_DIR / MONOLITH_PERSIST_MOUNTS override
# the mountpoint and mount-table path checked (see the script's own header)
# so no real /overlay or /proc/mounts is touched. `df` is stubbed on PATH
# for a deterministic free-space figure.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../../configs/overlay/app-misc/monolith-base/files/20-persist.sh"
fails=0
has() { if printf '%s' "$2" | grep -qF -- "$1"; then echo "  ok: $3"; else echo "  FAIL: $3 (wanted '$1')"; echo "----"; printf '%s\n' "$2"; echo "----"; fails=$((fails+1)); fi; }
has_not() { if printf '%s' "$2" | grep -qF -- "$1"; then echo "  FAIL: $3 (did NOT want '$1')"; echo "----"; printf '%s\n' "$2"; echo "----"; fails=$((fails+1)); else echo "  ok: $3"; fi; }

setup() {
    TMP=$(mktemp -d)
    BIN="$TMP/bin"; mkdir -p "$BIN"
    MOUNTDIR="$TMP/overlay"; mkdir -p "$MOUNTDIR"
    MOUNTSFILE="$TMP/mounts"
    # df -m <dir> -> a fixed, parseable "80 MB available" line.
    cat > "$BIN/df" <<'STUB'
#!/bin/sh
echo "Filesystem     1M-blocks  Used Available Use% Mounted on"
echo "fakedev              100    20        80  20% $2"
STUB
    chmod +x "$BIN/df"
}
teardown() { rm -rf "$TMP"; }

# Sources $SCRIPT inside an interactive bash (no real tty required) with
# MONOLITH_PERSIST_DIR/MONOLITH_PERSIST_MOUNTS pointed at the fixtures, then
# runs $1 (extra bash to print out whatever the test wants to assert on).
# stderr is discarded (bash -i without a tty logs harmless job-control
# warnings that would otherwise pollute every assertion).
source_it() {
    PATH="$BIN:$PATH" MONOLITH_PERSIST_DIR="$MOUNTDIR" MONOLITH_PERSIST_MOUNTS="$MOUNTSFILE" \
        bash -i -c ". '$SCRIPT'; $1" </dev/null 2>/dev/null
}

# Same, but as a NON-interactive bash -- proves the whole file is a no-op
# outside a login shell (matches monolith-advisory.sh/10-dropbear-hint.sh's
# `case "$-" in *i*)` convention).
source_it_noninteractive() {
    PATH="$BIN:$PATH" MONOLITH_PERSIST_DIR="$MOUNTDIR" MONOLITH_PERSIST_MOUNTS="$MOUNTSFILE" \
        bash -c ". '$SCRIPT'; $1" </dev/null 2>/dev/null
}

# 1. tmpfs overlay -> quiet "none" status
setup
printf 'none %s tmpfs rw 0 0\n' "$MOUNTDIR" > "$MOUNTSFILE"
out=$(source_it 'true')
has 'persist: none (see monolith help persist)' "$out" "tmpfs shows the quiet 'none' status"
has_not 'persist: mounted' "$out" "tmpfs never claims mounted"
teardown

# 2. real persist partition -> "mounted (N MB free)"
setup
printf '/dev/fake1 %s ext4 rw 0 0\n' "$MOUNTDIR" > "$MOUNTSFILE"
out=$(source_it 'true')
has 'persist: mounted (80 MB free)' "$out" "real fs shows mounted + free MB (df stub)"
has_not 'persist: none' "$out" "real fs never claims none"
teardown

# 3. this file NEVER touches PROMPT_COMMAND/histappend, even on a real
#    persist mount -- proves the history-reliability split is clean (that
#    logic now lives only in 50-persist-history.bash).
setup
printf '/dev/fake1 %s ext4 rw 0 0\n' "$MOUNTDIR" > "$MOUNTSFILE"
pc=$(source_it 'echo "PC=[$PROMPT_COMMAND]"')
has 'PC=[]' "$pc" "20-persist.sh never sets PROMPT_COMMAND, even when persist is real"
histappend_rc=$(source_it 'shopt -q histappend; echo $?' | tail -n1)
[ "$histappend_rc" = "1" ] && echo "  ok: 20-persist.sh never enables histappend" || { echo "  FAIL: histappend rc=$histappend_rc (want 1/unset)"; fails=$((fails+1)); }
teardown

# 4. non-interactive shell -> completely silent
setup
printf '/dev/fake1 %s ext4 rw 0 0\n' "$MOUNTDIR" > "$MOUNTSFILE"
out=$(source_it_noninteractive 'true')
[ -z "$out" ] && echo "  ok: non-interactive sourcing prints nothing" || { echo "  FAIL: non-interactive printed: $out"; fails=$((fails+1)); }
teardown

# 5. missing mount-table file -> falls back to the quiet 'none' status, does
#    not crash the shell (profile.d files must never abort profile loading)
setup
rm -f "$MOUNTSFILE"
out=$(source_it 'echo "SURVIVED=$?"')
has 'persist: none (see monolith help persist)' "$out" "missing mount table falls back to 'none'"
has 'SURVIVED=0' "$out" "sourcing with a missing mount table does not abort the shell"
teardown

echo; [ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
