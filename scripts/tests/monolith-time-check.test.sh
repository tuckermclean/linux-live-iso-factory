#!/bin/sh
# Unit tests for monolith-time-check — the boot-time GATE that decides
# whether monolith-time is allowed to run (S45monolith-time calls this).
# Stubs `date +%s` (controls what "now" the ignorance check sees) and
# `monolith-time` (a fake logging its own invocation + exit code), and
# points the script at fake sysfs/flag/cmdline paths — no root, no real
# clock, no network required.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../../configs/overlay/app-misc/monolith-base/files/monolith-time-check"
fails=0
check() { # desc, expected_substr, actual
    if printf '%s' "$3" | grep -qF -- "$2"; then echo "  ok: $1"
    else echo "  FAIL: $1 (wanted '$2')"; echo "----"; printf '%s\n' "$3"; echo "----"; fails=$((fails+1)); fi
}
assert_file() { # desc, path
    [ -f "$2" ] && echo "  ok: $1" || { echo "  FAIL: $1 (missing: $2)"; fails=$((fails+1)); }
}
assert_no_file() { # desc, path
    [ -f "$2" ] && { echo "  FAIL: $1 (unexpectedly present: $2)"; fails=$((fails+1)); } || echo "  ok: $1"
}

setup() {
    TMP=$(mktemp -d); BIN="$TMP/bin"; mkdir -p "$BIN"
    SYS="$TMP/sys"; mkdir -p "$SYS"
    FLAG="$TMP/flag"
    CMDLINE="$TMP/cmdline"; : > "$CMDLINE"
    MT_LOG="$TMP/monolith-time.log"; : > "$MT_LOG"

    # stub date: only `date +%s` is used by this script; answer with FAKE_NOW.
    cat > "$BIN/date" <<STUB
#!/bin/sh
if [ "\${1:-}" = "+%s" ]; then echo "\${FAKE_NOW:-1755000000}"; exit 0; fi
exit 0
STUB
    chmod +x "$BIN/date"

    # stub monolith-time: logs its invocation + env MONOLITH_TIME_URL it saw,
    # exits MT_EXIT (default success). Never touches curl/date/hwclock.
    cat > "$BIN/monolith-time" <<STUB
#!/bin/sh
echo "called url=\${MONOLITH_TIME_URL:-} args=\$*" >> "$MT_LOG"
exit "\${MT_EXIT:-0}"
STUB
    chmod +x "$BIN/monolith-time"

    export PATH="$BIN:$PATH"
    export MONOLITH_TIME_SYSCLASS="$SYS"
    export MONOLITH_TIME_FLAG="$FLAG"
    export MONOLITH_TIME_CMDLINE="$CMDLINE"
}
teardown() {
    rm -rf "$TMP"
    unset FAKE_NOW MT_EXIT MONOLITH_TIME_URL
    unset MONOLITH_TIME_SYSCLASS MONOLITH_TIME_FLAG MONOLITH_TIME_CMDLINE
}
iface_up() { mkdir -p "$SYS/eth0"; echo up > "$SYS/eth0/operstate"; }

# 1. Clock has an opinion (2026-ish, "now"): silent — no flag, monolith-time
#    never called — regardless of interface state.
setup; iface_up
out=$(FAKE_NOW=1786000000 sh "$SCRIPT" 2>&1); rc=$?
assert_no_file "no flag when the clock has an opinion" "$FLAG"
[ -s "$MT_LOG" ] && { echo "  FAIL: monolith-time called despite a clock with an opinion"; fails=$((fails+1)); } || echo "  ok: monolith-time never called"
[ "$rc" -eq 0 ] && echo "  ok: exit 0" || { echo "  FAIL: exit=$rc"; fails=$((fails+1)); }
teardown

# 2. Clock at the Unix epoch + an interface up + monolith-time succeeds:
#    monolith-time is called, no flag written (it now has an opinion).
setup; iface_up
out=$(FAKE_NOW=100 sh "$SCRIPT" 2>&1); rc=$?
check "monolith-time invoked" "called" "$(cat "$MT_LOG")"
assert_no_file "no flag after a successful correction" "$FLAG"
[ "$rc" -eq 0 ] && echo "  ok: exit 0" || { echo "  FAIL: exit=$rc"; fails=$((fails+1)); }
teardown

# 3. Clock at the epoch + an interface up + monolith-time FAILS (offline):
#    flag written so the login hint can fire.
setup; iface_up
out=$(FAKE_NOW=100 MT_EXIT=1 sh "$SCRIPT" 2>&1); rc=$?
check "monolith-time invoked" "called" "$(cat "$MT_LOG")"
assert_file "flag written after a failed correction" "$FLAG"
[ "$rc" -eq 0 ] && echo "  ok: exit 0 (never fails the boot)" || { echo "  FAIL: exit=$rc"; fails=$((fails+1)); }
teardown

# 4. Clock at the epoch, NO interface up at all: flag written immediately,
#    monolith-time never called (never a boot-time network wait).
setup
out=$(FAKE_NOW=0 sh "$SCRIPT" 2>&1); rc=$?
assert_file "flag written with no interface" "$FLAG"
[ -s "$MT_LOG" ] && { echo "  FAIL: monolith-time called despite no interface"; fails=$((fails+1)); } || echo "  ok: monolith-time never called (no interface)"
teardown

# 5. A correct 1996 clock: silent, even WITHOUT an interface (no NIC at all
#    is not "ignorance" by itself — a 1996 clock is never touched).
setup
out=$(FAKE_NOW=834840000 sh "$SCRIPT" 2>&1); rc=$?  # 1996-06-15T12:00:00Z
assert_no_file "no flag for a correct 1996 clock, no interface" "$FLAG"
[ -s "$MT_LOG" ] && { echo "  FAIL: monolith-time called for a correct 1996 clock"; fails=$((fails+1)); } || echo "  ok: monolith-time never called"
teardown

# 6. The 1980-01-01 BIOS/CMOS reset sentinel is also ignorance.
setup; iface_up
out=$(FAKE_NOW=315532800 sh "$SCRIPT" 2>&1); rc=$?  # 1980-01-01T00:00:00Z
check "monolith-time invoked for the 1980 sentinel" "called" "$(cat "$MT_LOG")"
teardown

# 7. The 2000-01-01 post-Y2K reset sentinel is also ignorance.
setup; iface_up
out=$(FAKE_NOW=946684800 sh "$SCRIPT" 2>&1); rc=$?  # 2000-01-01T00:00:00Z
check "monolith-time invoked for the 2000 sentinel" "called" "$(cat "$MT_LOG")"
teardown

# 8. Just outside the 1980 sentinel's slack window (+3 days): treated as an
#    opinion, not ignorance.
setup; iface_up
out=$(FAKE_NOW=$((315532800 + 3 * 86400)) sh "$SCRIPT" 2>&1); rc=$?
assert_no_file "no flag just outside the 1980 sentinel window" "$FLAG"
[ -s "$MT_LOG" ] && { echo "  FAIL: monolith-time called just outside the sentinel window"; fails=$((fails+1)); } || echo "  ok: monolith-time never called"
teardown

# 9. Kernel cmdline override (monolith_time_url=...) reaches monolith-time
#    via MONOLITH_TIME_URL when the clock is ignorant and an interface is up.
setup; iface_up
echo "console=ttyS0 monolith_time_url=http://10.0.2.2:8000/probe.txt toram" > "$CMDLINE"
out=$(FAKE_NOW=100 sh "$SCRIPT" 2>&1); rc=$?
check "cmdline URL override reaches monolith-time" "url=http://10.0.2.2:8000/probe.txt" "$(cat "$MT_LOG")"
teardown

echo; [ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
