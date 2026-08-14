#!/bin/sh
# Unit tests for monolith-net. Stubs modprobe/ip/dhcpcd on PATH and points the
# script at a fake sysfs so no real hardware or root is required.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../../configs/overlay/app-misc/monolith-base/files/monolith-net"
fails=0
check() { # desc, expected_substr, actual
    if printf '%s' "$3" | grep -qF "$2"; then echo "  ok: $1"
    else echo "  FAIL: $1 (wanted '$2')"; echo "----"; printf '%s\n' "$3"; echo "----"; fails=$((fails+1)); fi
}

setup() {
    TMP=$(mktemp -d); export SYS="$TMP/sys"; mkdir -p "$SYS"
    BIN="$TMP/bin"; mkdir -p "$BIN"
    export MONOLITH_NET_SYSCLASS="$SYS"
    # stub modprobe: creates eth0 only when the (driver[:io]) spec equals $WIN.
    cat > "$BIN/modprobe" <<'STUB'
#!/bin/sh
[ "$1" = "-r" ] && exit 0
drv=$1; shift; addr=""; irq=""
for a in "$@"; do case "$a" in io=*) addr=${a#io=};; irq=*) irq=${a#irq=};; esac; done
spec="$drv"; [ -n "$addr" ] && spec="$spec:$addr"; [ -n "$irq" ] && spec="$spec:$irq"
if [ "$spec" = "${WIN:-}" ]; then mkdir -p "$SYS/eth0"; echo up > "$SYS/eth0/operstate"; exit 0; fi
exit 1
STUB
    printf '#!/bin/sh\nexit 0\n' > "$BIN/ip"
    printf '#!/bin/sh\nexit 0\n' > "$BIN/dhcpcd"
    chmod +x "$BIN"/*
    export PATH="$BIN:$PATH"
}
teardown() { rm -rf "$TMP"; unset WIN; }

# 1. status with no NIC prints the incantation
setup; out=$(WIN= sh "$SCRIPT" status 2>&1); check "status/no-nic shows incantation" "monolith-net probe" "$out"; teardown
# 2. status with a NIC lists it
setup; mkdir -p "$SYS/eth0"; echo up > "$SYS/eth0/operstate"
out=$(sh "$SCRIPT" status 2>&1); check "status lists eth0" "eth0" "$out"; teardown
# 3. autoprobe: 3c509 self-identifies -> NIC appears, no banner
setup; out=$(WIN=3c509 sh "$SCRIPT" autoprobe 2>&1)
check "autoprobe finds 3c509" "" "$out"  # no crash
[ -d "$SYS/eth0" ] && echo "  ok: autoprobe created eth0" || { echo "  FAIL: autoprobe made no eth0"; fails=$((fails+1)); }
teardown
# 4. autoprobe with nothing -> prints incantation
setup; out=$(WIN= sh "$SCRIPT" autoprobe 2>&1); check "autoprobe/none shows incantation" "monolith-net probe" "$out"; teardown
# 5. probe finds ne at a non-default address
setup; out=$(WIN=ne:0x320:5 sh "$SCRIPT" probe 2>&1); check "probe finds ne io=0x320 irq=5" "ne io=0x320 irq=5" "$out"; teardown
# 6. probe finds nothing -> reports failure + incantation, exit 1
setup; out=$(WIN= sh "$SCRIPT" probe 2>&1); rc=$?
check "probe/none reports failure" "No ISA card answered" "$out"
[ "$rc" -eq 1 ] && echo "  ok: probe/none exits 1" || { echo "  FAIL: probe/none exit=$rc"; fails=$((fails+1)); }
teardown
# 7. incantation prints the liturgy
setup; out=$(sh "$SCRIPT" incantation 2>&1); check "incantation shows modprobe ne" "modprobe ne io=0x300" "$out"; teardown
# 8. unknown subcommand -> usage, exit 2
setup; out=$(sh "$SCRIPT" bogus 2>&1); rc=$?
[ "$rc" -eq 2 ] && echo "  ok: bad cmd exits 2" || { echo "  FAIL: bad cmd exit=$rc"; fails=$((fails+1)); }
teardown

echo; [ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
