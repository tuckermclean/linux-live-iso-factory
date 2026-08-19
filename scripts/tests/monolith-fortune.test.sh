#!/bin/sh
# Unit tests for /etc/profile.d/zz-fortune.sh (Monolith UX Pass Task 5).
#
# The file is meant to be SOURCED by an interactive login bash, not
# executed -- these tests source it inside `bash -i -c '...'` (interactive
# flag forced, no real tty needed), same technique as
# monolith-persist-profile.test.sh. MONOLITH_FORTUNE_FLAG overrides the
# once-per-boot flag path (see the script's own header) so no real /run is
# touched. `fortune` is stubbed on PATH for a deterministic cookie.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../../configs/overlay/app-misc/monolith-base/files/zz-fortune.sh"
fails=0
has() { if printf '%s' "$2" | grep -qF -- "$1"; then echo "  ok: $3"; else echo "  FAIL: $3 (wanted '$1')"; echo "----"; printf '%s\n' "$2"; echo "----"; fails=$((fails+1)); fi; }
has_not() { if printf '%s' "$2" | grep -qF -- "$1"; then echo "  FAIL: $3 (did NOT want '$1')"; echo "----"; printf '%s\n' "$2"; echo "----"; fails=$((fails+1)); else echo "  ok: $3"; fi; }

setup() {
    TMP=$(mktemp -d)
    BIN="$TMP/bin"; mkdir -p "$BIN"
    FLAG="$TMP/run/monolith-fortune-shown"; mkdir -p "$TMP/run"
    # fortune stub -> a fixed, recognizable cookie.
    cat > "$BIN/fortune" <<'STUB'
#!/bin/sh
echo "a fixed stubbed cookie"
STUB
    chmod +x "$BIN/fortune"
}
teardown() { rm -rf "$TMP"; }

# Sources $SCRIPT inside an interactive bash (no real tty required) with
# MONOLITH_FORTUNE_FLAG pointed at the fixture path, PATH prepended with the
# fortune stub, then runs $1 (extra bash to print whatever the test wants to
# assert on). stderr is discarded (bash -i without a tty logs harmless
# job-control warnings that would otherwise pollute every assertion).
source_it() {
    PATH="$BIN:$PATH" MONOLITH_FORTUNE_FLAG="$FLAG" \
        bash -i -c ". '$SCRIPT'; $1" </dev/null 2>/dev/null
}

# Same, but as a NON-interactive bash -- proves the whole file is a no-op
# outside a login shell (matches 40-advisory.sh/20-persist.sh's
# `case "$-" in *i*)` convention).
source_it_noninteractive() {
    PATH="$BIN:$PATH" MONOLITH_FORTUNE_FLAG="$FLAG" \
        bash -c ". '$SCRIPT'; $1" </dev/null 2>/dev/null
}

# 1. no flag yet, fortune present -> prints a cookie, creates the flag
setup
out=$(source_it 'true')
has 'a fixed stubbed cookie' "$out" "first login of the boot prints a cookie"
[ -e "$FLAG" ] && echo "  ok: flag file created after showing the fortune" || { echo "  FAIL: flag file not created"; fails=$((fails+1)); }
teardown

# 2. flag already present (a second shell, same boot) -> silent, no
#    second cookie
setup
: > "$FLAG"
out=$(source_it 'true')
[ -z "$out" ] && echo "  ok: second login of the same boot is silent" || { echo "  FAIL: second login printed: $out"; fails=$((fails+1)); }
teardown

# 3. fortune missing from PATH (dropped by --keep-going) -> silent, no
#    crash, and the flag is NOT created (nothing to remember)
setup
rm -f "$BIN/fortune"
out=$(source_it 'echo "SURVIVED=$?"')
has 'SURVIVED=0' "$out" "missing fortune does not abort the shell"
has_not 'a fixed stubbed cookie' "$out" "missing fortune prints no cookie"
[ -e "$FLAG" ] && { echo "  FAIL: flag file created even though fortune is missing"; fails=$((fails+1)); } || echo "  ok: no flag file written when fortune is missing"
teardown

# 4. non-interactive shell -> completely silent, no flag written
setup
out=$(source_it_noninteractive 'true')
[ -z "$out" ] && echo "  ok: non-interactive sourcing prints nothing" || { echo "  FAIL: non-interactive printed: $out"; fails=$((fails+1)); }
[ -e "$FLAG" ] && { echo "  FAIL: flag file created by a non-interactive source"; fails=$((fails+1)); } || echo "  ok: non-interactive sourcing never writes the flag"
teardown

echo; [ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
