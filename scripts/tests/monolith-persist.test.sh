#!/bin/sh
# Unit tests for monolith-persist. Stubs mkfs.ext4/mkswap/blkid/mount/umount/
# fallocate on PATH — no root, no real block device, no real mount.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../../configs/overlay/app-misc/monolith-base/files/monolith-persist"
# Absolute path to the shell interpreter itself, resolved once via the
# NORMAL (unmodified) PATH — test 11 overrides PATH down to just its stub
# dir to prove "mkfs.ext4 missing" without a real system mkfs.ext4 masking
# it, but still needs to be able to exec $SCRIPT via an explicit sh.
SH=$(command -v sh)
fails=0
has() { if printf '%s' "$2" | grep -qF -- "$1"; then echo "  ok: $3"; else echo "  FAIL: $3 (wanted '$1')"; echo "----"; printf '%s\n' "$2"; echo "----"; fails=$((fails+1)); fi; }

setup() {
    TMP=$(mktemp -d)
    BIN="$TMP/bin"; mkdir -p "$BIN"
    MKFSLOG="$TMP/mkfs.log"; : > "$MKFSLOG"
    MKSWAPLOG="$TMP/mkswap.log"; : > "$MKSWAPLOG"

    cat > "$BIN/mkfs.ext4" <<STUB
#!/bin/sh
echo "mkfs.ext4 \$*" >> "$MKFSLOG"
[ -n "\${MKFS_FAIL:-}" ] && exit 1
exit 0
STUB
    cat > "$BIN/mkswap" <<STUB
#!/bin/sh
echo "mkswap \$*" >> "$MKSWAPLOG"
exit 0
STUB
    # blkid: reports $BLKID_TYPE/$BLKID_LABEL for any device if set, else
    # "nothing found" (exit 2, mirroring real blkid on a signature-less device).
    cat > "$BIN/blkid" <<'STUB'
#!/bin/sh
case "$*" in
    *"-s TYPE"*) [ -n "${BLKID_TYPE:-}" ] && { echo "$BLKID_TYPE"; exit 0; }; exit 2 ;;
    *"-s LABEL"*) [ -n "${BLKID_LABEL:-}" ] && { echo "$BLKID_LABEL"; exit 0; }; exit 2 ;;
esac
exit 2
STUB
    # mount/umount: no-op success (the swap path just needs a real directory
    # to write the swapfile into — $_mnt from mktemp -d already exists).
    printf '#!/bin/sh\nexit 0\n' > "$BIN/mount"
    printf '#!/bin/sh\nexit 0\n' > "$BIN/umount"
    # fallocate: fails so the script falls back to its `dd` path deterministically.
    printf '#!/bin/sh\nexit 1\n' > "$BIN/fallocate"
    chmod +x "$BIN"/*
    export PATH="$BIN:$PATH"
}
teardown() { rm -rf "$TMP"; unset MKFS_FAIL BLKID_TYPE BLKID_LABEL; }

# 1. no args -> usage on stderr, exit 2
setup; out=$(sh "$SCRIPT" 2>&1); rc=$?
has 'usage:' "$out" "no-args shows usage"
[ "$rc" -eq 2 ] && echo "  ok: no-args exits 2" || { echo "  FAIL: no-args exit=$rc"; fails=$((fails+1)); }
teardown

# 2. --help / -h -> usage, exit 0
setup; out=$(sh "$SCRIPT" --help 2>&1); rc=$?
has 'usage:' "$out" "--help shows usage"
[ "$rc" -eq 0 ] && echo "  ok: --help exits 0" || { echo "  FAIL: --help exit=$rc"; fails=$((fails+1)); }
teardown

# 2b. init --help -> usage, exit 0, mkfs never runs (regression: init's own
#     option loop must recognize -h/--help itself, not just the top level)
setup; out=$(sh "$SCRIPT" init --help 2>&1); rc=$?
has 'usage:' "$out" "init --help shows usage"
[ "$rc" -eq 0 ] && echo "  ok: init --help exits 0" || { echo "  FAIL: init --help exit=$rc"; fails=$((fails+1)); }
[ -s "$MKFSLOG" ] && { echo "  FAIL: mkfs ran for init --help"; fails=$((fails+1)); } || echo "  ok: mkfs not run (init --help)"
teardown

# 3. unknown command -> usage on stderr, exit 2, nothing run
setup; out=$(sh "$SCRIPT" bogus 2>&1); rc=$?
has "unknown command 'bogus'" "$out" "unknown command named in error"
[ "$rc" -eq 2 ] && echo "  ok: unknown command exits 2" || { echo "  FAIL: exit=$rc"; fails=$((fails+1)); }
[ -s "$MKFSLOG" ] && { echo "  FAIL: mkfs ran for unknown command"; fails=$((fails+1)); } || echo "  ok: mkfs not run"
teardown

# 4. init with no device -> usage, exit 2, mkfs never runs
setup; out=$(sh "$SCRIPT" init 2>&1); rc=$?
[ "$rc" -eq 2 ] && echo "  ok: init/no-dev exits 2" || { echo "  FAIL: exit=$rc"; fails=$((fails+1)); }
[ -s "$MKFSLOG" ] && { echo "  FAIL: mkfs ran with no device"; fails=$((fails+1)); } || echo "  ok: mkfs not run"
teardown

# 5. init <dev> --yes -> mkfs.ext4 -F -L MONOLITH_PERSIST <dev>, no prompt needed
setup; out=$(sh "$SCRIPT" init /dev/fake1 --yes </dev/null 2>&1); rc=$?
[ "$rc" -eq 0 ] && echo "  ok: init --yes exits 0" || { echo "  FAIL: exit=$rc: $out"; fails=$((fails+1)); }
has 'mkfs.ext4 -F -L MONOLITH_PERSIST /dev/fake1' "$(cat "$MKFSLOG")" "mkfs invoked with -F -L MONOLITH_PERSIST <dev>"
has '/dev/fake1 is now MONOLITH_PERSIST' "$out" "confirms the new label"
teardown

# 6. init <dev> -y (short flag) also skips the prompt
setup; out=$(sh "$SCRIPT" init /dev/fake1 -y </dev/null 2>&1); rc=$?
[ "$rc" -eq 0 ] && echo "  ok: init -y exits 0" || { echo "  FAIL: exit=$rc"; fails=$((fails+1)); }
has 'mkfs.ext4 -F -L MONOLITH_PERSIST /dev/fake1' "$(cat "$MKFSLOG")" "-y also runs mkfs"
teardown

# 7. init <dev>, interactive confirmation, device named + typing "yes" proceeds
setup; out=$(printf 'yes\n' | sh "$SCRIPT" init /dev/fake2 2>&1); rc=$?
has '/dev/fake2' "$out" "confirmation names the device"
has 'ERASE ALL DATA' "$out" "confirmation states data loss"
has 'mkfs.ext4 -F -L MONOLITH_PERSIST /dev/fake2' "$(cat "$MKFSLOG")" "typing yes proceeds to mkfs"
[ "$rc" -eq 0 ] && echo "  ok: confirmed init exits 0" || { echo "  FAIL: exit=$rc"; fails=$((fails+1)); }
teardown

# 8. init <dev>, confirmation declined ("no") -> aborts, mkfs never runs, non-zero exit
setup; out=$(printf 'no\n' | sh "$SCRIPT" init /dev/fake3 2>&1); rc=$?
[ "$rc" -ne 0 ] && echo "  ok: declined confirmation exits non-zero" || { echo "  FAIL: exit=$rc"; fails=$((fails+1)); }
has 'aborted' "$out" "decline reports aborted"
[ -s "$MKFSLOG" ] && { echo "  FAIL: mkfs ran despite declined confirmation"; fails=$((fails+1)); } || echo "  ok: mkfs not run (declined)"
teardown

# 9. init <dev>, no stdin at all (EOF immediately) -> aborts, does not hang, mkfs never runs
setup; out=$(sh "$SCRIPT" init /dev/fake4 </dev/null 2>&1); rc=$?
[ "$rc" -ne 0 ] && echo "  ok: EOF-on-confirm exits non-zero" || { echo "  FAIL: exit=$rc"; fails=$((fails+1)); }
[ -s "$MKFSLOG" ] && { echo "  FAIL: mkfs ran despite EOF on confirm"; fails=$((fails+1)); } || echo "  ok: mkfs not run (EOF)"
teardown

# 10. confirmation reports the device's CURRENT contents via blkid
setup
out=$(printf 'no\n' | BLKID_TYPE=vfat BLKID_LABEL=OLDDATA sh "$SCRIPT" init /dev/fake5 2>&1)
has 'vfat' "$out" "confirmation shows current fs type"
has 'OLDDATA' "$out" "confirmation shows current label"
teardown

# 11. mkfs.ext4 missing on PATH -> legible error, exit non-zero. Isolate PATH
#     to just $BIN (minus mkfs.ext4) so a real system mkfs.ext4 elsewhere on
#     PATH can't mask the check.
setup
rm -f "$BIN/mkfs.ext4"
out=$(PATH="$BIN" "$SH" "$SCRIPT" init /dev/fake6 --yes 2>&1); rc=$?
has 'mkfs.ext4 not found' "$out" "missing mkfs.ext4 reported"
[ "$rc" -ne 0 ] && echo "  ok: missing mkfs.ext4 exits non-zero" || { echo "  FAIL: exit=$rc"; fails=$((fails+1)); }
teardown

# 12. mkfs.ext4 itself fails -> error surfaced, non-zero exit
setup
out=$(MKFS_FAIL=1 sh "$SCRIPT" init /dev/fake7 --yes 2>&1); rc=$?
has 'mkfs.ext4 failed' "$out" "mkfs failure surfaced"
[ "$rc" -ne 0 ] && echo "  ok: mkfs failure exits non-zero" || { echo "  FAIL: exit=$rc"; fails=$((fails+1)); }
teardown

# 13. --swap N creates a swapfile: mkswap runs, output tells the user how to enable it
setup
out=$(sh "$SCRIPT" init /dev/fake8 --swap 32 --yes </dev/null 2>&1); rc=$?
[ "$rc" -eq 0 ] && echo "  ok: init --swap exits 0" || { echo "  FAIL: exit=$rc: $out"; fails=$((fails+1)); }
has 'swapfile' "$(cat "$MKSWAPLOG")" "mkswap ran against a swapfile path"
has 'swapon /overlay/swapfile' "$out" "tells the user how to enable the swapfile"
has '32MB swapfile' "$out" "reports the swapfile size"
teardown

# 14. --swap=N (equals form) also works
setup
out=$(sh "$SCRIPT" init /dev/fake9 --swap=16 --yes </dev/null 2>&1); rc=$?
[ "$rc" -eq 0 ] && echo "  ok: --swap=N exits 0" || { echo "  FAIL: exit=$rc: $out"; fails=$((fails+1)); }
has '16MB swapfile' "$out" "--swap=N honored"
teardown

# 15. --swap with a non-numeric value is rejected before mkfs ever runs
setup
out=$(sh "$SCRIPT" init /dev/fake10 --swap abc --yes 2>&1); rc=$?
[ "$rc" -ne 0 ] && echo "  ok: --swap abc exits non-zero" || { echo "  FAIL: exit=$rc"; fails=$((fails+1)); }
[ -s "$MKFSLOG" ] && { echo "  FAIL: mkfs ran despite bad --swap value"; fails=$((fails+1)); } || echo "  ok: mkfs not run (bad --swap)"
teardown

# 16. --swap 0 is rejected (must be a positive size)
setup
out=$(sh "$SCRIPT" init /dev/fake11 --swap 0 --yes 2>&1); rc=$?
[ "$rc" -ne 0 ] && echo "  ok: --swap 0 exits non-zero" || { echo "  FAIL: exit=$rc"; fails=$((fails+1)); }
teardown

# 17. unknown option -> usage error, mkfs never runs
setup
out=$(sh "$SCRIPT" init /dev/fake12 --bogus --yes 2>&1); rc=$?
[ "$rc" -ne 0 ] && echo "  ok: unknown option exits non-zero" || { echo "  FAIL: exit=$rc"; fails=$((fails+1)); }
[ -s "$MKFSLOG" ] && { echo "  FAIL: mkfs ran despite unknown option"; fails=$((fails+1)); } || echo "  ok: mkfs not run (unknown option)"
teardown

# 18. extra positional argument is rejected
setup
out=$(sh "$SCRIPT" init /dev/fake13 /dev/fake14 --yes 2>&1); rc=$?
[ "$rc" -ne 0 ] && echo "  ok: extra positional arg exits non-zero" || { echo "  FAIL: exit=$rc"; fails=$((fails+1)); }
teardown

# 19. never runs without an explicit subcommand — this script has no
#     autorun/daemon path, confirmed by asserting bare invocation never
#     touches mkfs (covered by test 1, restated here as the doctrine check).
setup; sh "$SCRIPT" >/dev/null 2>&1
[ -s "$MKFSLOG" ] && { echo "  FAIL: bare invocation ran mkfs"; fails=$((fails+1)); } || echo "  ok: bare invocation is inert (manual tool doctrine)"
teardown

echo; [ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
