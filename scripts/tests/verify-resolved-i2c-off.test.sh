#!/bin/sh
# Unit tests for scripts/verify-resolved-i2c-off.sh (DCX-99): a missing
# resolved-config artifact must FAIL loudly (no vacuous pass on a binpkg cache
# hit), a real CONFIG_I2C=y escalation must FAIL, a clean config must PASS,
# both plain-text and gzip inputs are read correctly, and the build-mode label
# passed by the caller is echoed back in the PASS/FAIL line.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../verify-resolved-i2c-off.sh"
fails=0
check() { # desc, expected_substr, actual
    if printf '%s' "$3" | grep -qF -- "$2"; then echo "  ok: $1"
    else echo "  FAIL: $1 (wanted '$2')"; echo "----"; printf '%s\n' "$3"; echo "----"; fails=$((fails+1)); fi
}

setup() { TMP=$(mktemp -d); }
teardown() { rm -rf "$TMP"; }

# 1. Missing artifact: hard FAIL, not a skip — the whole point of DCX-99.
setup
out=$(sh "$SCRIPT" "$TMP/nope.config.gz" binpkg 2>&1); rc=$?
[ "$rc" -eq 1 ] && echo "  ok: exit 1 on missing artifact" || { echo "  FAIL: exit=$rc"; fails=$((fails+1)); }
check "FAIL names missing artifact" "FAIL: $TMP/nope.config.gz not found" "$out"
check "FAIL states build mode" "kernel build mode: binpkg" "$out"
teardown

# 2. CONFIG_I2C=y escalation (plain text): FAIL.
setup
printf 'CONFIG_FOO=y\nCONFIG_I2C=y\nCONFIG_BAR=m\n' > "$TMP/resolved.config"
out=$(sh "$SCRIPT" "$TMP/resolved.config" source 2>&1); rc=$?
[ "$rc" -eq 1 ] && echo "  ok: exit 1 on CONFIG_I2C=y" || { echo "  FAIL: exit=$rc"; fails=$((fails+1)); }
check "FAIL names the escalation" "FAIL: CONFIG_I2C=y" "$out"
check "FAIL states build mode" "kernel build mode: source" "$out"
teardown

# 3. Clean config (plain text): PASS.
setup
printf 'CONFIG_FOO=y\nCONFIG_I2C=m\nCONFIG_BAR=m\n' > "$TMP/resolved.config"
out=$(sh "$SCRIPT" "$TMP/resolved.config" source 2>&1); rc=$?
[ "$rc" -eq 0 ] && echo "  ok: exit 0 on clean config" || { echo "  FAIL: exit=$rc"; fails=$((fails+1)); }
check "PASS message" "PASS: CONFIG_I2C not =y" "$out"
check "PASS states build mode" "kernel build mode: source" "$out"
teardown

# 4. Clean config, gzip (the real CI artifact shape): PASS.
setup
printf 'CONFIG_FOO=y\nCONFIG_I2C=m\nCONFIG_BAR=m\n' | gzip -9c > "$TMP/resolved.config.gz"
out=$(sh "$SCRIPT" "$TMP/resolved.config.gz" binpkg 2>&1); rc=$?
[ "$rc" -eq 0 ] && echo "  ok: exit 0 on clean gzipped config" || { echo "  FAIL: exit=$rc"; fails=$((fails+1)); }
check "PASS message on gzip input" "PASS: CONFIG_I2C not =y" "$out"
check "PASS states build mode" "kernel build mode: binpkg" "$out"
teardown

# 5. CONFIG_I2C=y escalation, gzip: FAIL.
setup
printf 'CONFIG_I2C=y\n' | gzip -9c > "$TMP/resolved.config.gz"
out=$(sh "$SCRIPT" "$TMP/resolved.config.gz" binpkg 2>&1); rc=$?
[ "$rc" -eq 1 ] && echo "  ok: exit 1 on gzipped CONFIG_I2C=y" || { echo "  FAIL: exit=$rc"; fails=$((fails+1)); }
check "FAIL names the escalation on gzip input" "FAIL: CONFIG_I2C=y" "$out"
teardown

# 6. No build-mode argument: defaults to "unknown" rather than erroring.
setup
printf 'CONFIG_I2C=m\n' > "$TMP/resolved.config"
out=$(sh "$SCRIPT" "$TMP/resolved.config" 2>&1); rc=$?
[ "$rc" -eq 0 ] && echo "  ok: exit 0 with default mode" || { echo "  FAIL: exit=$rc"; fails=$((fails+1)); }
check "defaults build mode to unknown" "kernel build mode: unknown" "$out"
teardown

echo; [ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
