# /etc/profile.d/zz-fortune.sh
#
# Console comfort (Monolith UX Pass Task 5): one fortune cookie per boot, on
# interactive login. "Wisdom must never bury status" — this must run AFTER
# every status/hint profile.d snippet (persist status, dropbear hint,
# security advisory, clock-ignorance hint).
#
# Named zz- rather than the "90-fortune.sh" the task brief suggested as an
# example: /etc/profile's `for f in /etc/profile.d/*.sh` glob sorts
# lexically (verified), and this repo already has two hint files with NO
# numeric prefix — monolith-advisory.sh and monolith-time-hint.sh. A "90-"
# prefix sorts BEFORE "monolith-advisory.sh" in ASCII (digits < letters),
# which would print the fortune ahead of the security advisory — exactly
# backwards. zz- sorts after every profile.d file in this tree today
# (10-, 20-, monolith-*). Task 6 (hint hygiene) is expected to formalize
# an ordering scheme repo-wide; until then, zz- is the one prefix
# guaranteed to lose every comparison.
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
