#!/bin/sh
# Unit tests for monolith-time. Stubs curl (fake response headers) and
# date/hwclock (so nothing real is ever set) on PATH — no root, no network,
# no clock changes required to run this.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../../configs/overlay/app-misc/monolith-base/files/monolith-time"
fails=0
check() { # desc, expected_substr, actual
    if printf '%s' "$3" | grep -qF -- "$2"; then echo "  ok: $1"
    else echo "  FAIL: $1 (wanted '$2')"; echo "----"; printf '%s\n' "$3"; echo "----"; fails=$((fails+1)); fi
}
check_not() { # desc, unwanted_substr, actual
    if printf '%s' "$3" | grep -qF -- "$2"; then
        echo "  FAIL: $1 (did not want '$2')"; echo "----"; printf '%s\n' "$3"; echo "----"; fails=$((fails+1))
    else echo "  ok: $1"
    fi
}

setup() {
    TMP=$(mktemp -d); BIN="$TMP/bin"; mkdir -p "$BIN"
    DATE_LOG="$TMP/date.log"; HWCLOCK_LOG="$TMP/hwclock.log"; CURL_LOG="$TMP/curl.log"
    : > "$DATE_LOG"; : > "$HWCLOCK_LOG"; : > "$CURL_LOG"

    # stub curl: behavior selected by $CURL_MODE, logs its args (the URL).
    cat > "$BIN/curl" <<STUB
#!/bin/sh
echo "\$@" >> "$CURL_LOG"
case "\${CURL_MODE:-ok}" in
    ok)
        printf 'HTTP/1.1 200 OK\r\n'
        printf 'Date: Thu, 13 Aug 2026 20:15:03 GMT\r\n'
        printf 'Content-Type: text/html\r\n\r\n'
        ;;
    lowercase)
        printf 'HTTP/1.1 200 OK\r\n'
        printf 'date: Thu, 13 Aug 2026 20:15:03 GMT\r\n\r\n'
        ;;
    nodate)
        printf 'HTTP/1.1 200 OK\r\n'
        printf 'Content-Type: text/html\r\n\r\n'
        ;;
    fail)
        exit 7
        ;;
esac
STUB
    chmod +x "$BIN/curl"

    # stub date: only cares about `-s STRING`; logs it, never touches the
    # real clock. Any other invocation (shouldn't happen from this script)
    # just succeeds so a stray call can't hang the test.
    cat > "$BIN/date" <<STUB
#!/bin/sh
if [ "\${1:-}" = "-s" ]; then
    shift
    echo "\$@" >> "$DATE_LOG"
    exit "\${DATE_EXIT:-0}"
fi
exit 0
STUB
    chmod +x "$BIN/date"

    # stub hwclock: logs invocation, never touches real hardware.
    cat > "$BIN/hwclock" <<STUB
#!/bin/sh
echo "\$@" >> "$HWCLOCK_LOG"
exit "\${HWCLOCK_EXIT:-0}"
STUB
    chmod +x "$BIN/hwclock"

    export PATH="$BIN:$PATH"
}
teardown() { rm -rf "$TMP"; unset CURL_MODE DATE_EXIT HWCLOCK_EXIT MONOLITH_TIME_URL; }

# 1. Happy path: curl returns a Date header -> date -s gets the right string,
#    hwclock -w is called, exit 0.
setup
out=$(sh "$SCRIPT" http://example.test/ 2>&1); rc=$?
check "reports the corrected date" "clock set to Thu, 13 Aug 2026 20:15:03 GMT" "$out"
check "date -s invoked with the HTTP date" "Thu, 13 Aug 2026 20:15:03 GMT" "$(cat "$DATE_LOG")"
check "hwclock -w invoked" "-w" "$(cat "$HWCLOCK_LOG")"
[ "$rc" -eq 0 ] && echo "  ok: exit 0" || { echo "  FAIL: exit=$rc"; fails=$((fails+1)); }
teardown

# 2. Case-insensitive header name ("date:" not "Date:") still parses.
setup
out=$(CURL_MODE=lowercase sh "$SCRIPT" http://example.test/ 2>&1); rc=$?
check "lowercase 'date:' header still parses" "clock set to Thu, 13 Aug 2026 20:15:03 GMT" "$out"
[ "$rc" -eq 0 ] && echo "  ok: exit 0" || { echo "  FAIL: exit=$rc"; fails=$((fails+1)); }
teardown

# 3. curl fails outright (offline/timeout) -> legible failure, nonzero exit,
#    date/hwclock never invoked (nothing gets set on a failed fetch).
setup
out=$(CURL_MODE=fail sh "$SCRIPT" http://example.test/ 2>&1); rc=$?
check "offline/curl-failure reports a legible message" "no response from" "$out"
[ "$rc" -ne 0 ] && echo "  ok: nonzero exit on curl failure" || { echo "  FAIL: exit=$rc (wanted nonzero)"; fails=$((fails+1)); }
[ -s "$DATE_LOG" ] && { echo "  FAIL: date -s was invoked despite curl failing"; fails=$((fails+1)); } || echo "  ok: date -s never invoked"
teardown

# 4. curl succeeds but the response has no Date header -> legible failure.
setup
out=$(CURL_MODE=nodate sh "$SCRIPT" http://example.test/ 2>&1); rc=$?
check "missing Date header reports a legible message" "no Date header" "$out"
[ "$rc" -ne 0 ] && echo "  ok: nonzero exit on missing header" || { echo "  FAIL: exit=$rc (wanted nonzero)"; fails=$((fails+1)); }
teardown

# 5. `date -s` itself rejects the string -> legible failure, nonzero exit.
setup
out=$(DATE_EXIT=1 sh "$SCRIPT" http://example.test/ 2>&1); rc=$?
check "unparseable date reports a legible message" "did not parse as a date" "$out"
[ "$rc" -ne 0 ] && echo "  ok: nonzero exit on unparseable date" || { echo "  FAIL: exit=$rc (wanted nonzero)"; fails=$((fails+1)); }
check_not "hwclock is not invoked when date -s itself failed" "-w" "$(cat "$HWCLOCK_LOG")"
teardown

# 6. No hwclock on PATH (RTC-less machine) -> still succeeds, no crash.
setup
rm -f "$BIN/hwclock"
out=$(sh "$SCRIPT" http://example.test/ 2>&1); rc=$?
check "still corrects the clock with no hwclock present" "clock set to" "$out"
[ "$rc" -eq 0 ] && echo "  ok: exit 0 with no hwclock" || { echo "  FAIL: exit=$rc"; fails=$((fails+1)); }
teardown

# 7. Positional URL arg is passed straight to curl.
setup
out=$(sh "$SCRIPT" http://custom.example/probe.txt 2>&1)
check "positional URL arg reaches curl" "http://custom.example/probe.txt" "$(cat "$CURL_LOG")"
teardown

# 8. MONOLITH_TIME_URL env var used when no positional arg is given.
setup
out=$(MONOLITH_TIME_URL=http://env.example/ sh "$SCRIPT" 2>&1)
check "MONOLITH_TIME_URL env var reaches curl" "http://env.example/" "$(cat "$CURL_LOG")"
teardown

# 9. A positional arg wins over the env var.
setup
out=$(MONOLITH_TIME_URL=http://env.example/ sh "$SCRIPT" http://arg.example/ 2>&1)
check "positional arg overrides MONOLITH_TIME_URL" "http://arg.example/" "$(cat "$CURL_LOG")"
check_not "env URL not used when an arg is given" "http://env.example/" "$(cat "$CURL_LOG")"
teardown

echo; [ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
