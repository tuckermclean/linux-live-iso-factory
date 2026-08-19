# /etc/profile.d/zz-fortune.sh
#
# Console comfort (Monolith UX Pass Task 5): one fortune cookie per boot, on
# interactive login. "Wisdom must never bury status" — this must run AFTER
# every status/hint profile.d snippet.
#
# Ordering contract (Task 6, hint hygiene — see the monolith-base ebuild's
# src_install, profile.d section for the full statement and the
# /run-flag policy per snippet): /etc/profile's
# `for f in /etc/profile.d/*.sh` glob sorts lexically (verified), and the
# repo-wide contract is now: STATUS lines first (20-persist.sh,
# 30-clock-hint.sh), ACTIONABLE hints second (40-advisory.sh,
# 50-dropbear-hint.sh), fortune last. Named zz- rather than a numeric
# prefix like "90-" so it is guaranteed to sort after any two-digit
# prefix ever added to this directory without requiring every future
# snippet author to stay under 90 — 'z' > any digit in ASCII.
#
# Guarded on a /run flag: once per BOOT, not once per shell — a user
# opening several terminals in one session should not see a fortune in
# each. Also guarded on `command -v fortune`: a --keep-going CI build can
# drop games-misc/fortune-mod (see this package's world/package.use entry
# for why that's a real, elevated risk here, not just the usual
# CI-unverified flag) — this stays a silent no-op if it did.
#
# This file is sourced by /etc/profile — do NOT use set -e, subshells, or
# command substitutions that could abort profile loading on error.
#
# MONOLITH_FORTUNE_FLAG overrides the once-per-boot flag path (default
# /run/monolith-fortune-shown) — a test hook only, mirroring 20-persist.sh's
# MONOLITH_PERSIST_DIR pattern; unset in production so this always uses the
# real /run.

: "${MONOLITH_FORTUNE_FLAG:=/run/monolith-fortune-shown}"

case "$-" in
    *i*)
        if [ ! -e "$MONOLITH_FORTUNE_FLAG" ] && command -v fortune >/dev/null 2>&1; then
            : > "$MONOLITH_FORTUNE_FLAG" 2>/dev/null
            printf '\n'
            fortune 2>/dev/null
        fi
        ;;
esac
