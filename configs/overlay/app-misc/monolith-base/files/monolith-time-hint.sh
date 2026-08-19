# /etc/profile.d/monolith-time-hint.sh
#
# Prints a reminder ONLY when boot detected the clock was demonstrably
# ignorant of the time (dead RTC at the epoch, or a common BIOS/CMOS
# reset default — see monolith-time-check for the exact sentinels) AND
# monolith-time could not fix it automatically (offline, or no interface
# at all). Never fires for a clock that has any opinion, including a
# correct 1996 clock — see the INVARIANT in monolith-time-check.
#
# The flag is written by /etc/init.d/S45monolith-time (via
# monolith-time-check) at boot; this file only reads it. Interactive-only
# (no point on a script/cron shell), and a cheap single stat() so it stays
# inside the profile's fast-boot budget.
#
# This file is sourced by /etc/profile — do NOT use set -e, subshells, or
# command substitutions that could abort profile loading on error.

case "$-" in
    *i*)
        if [ -f /run/monolith-clock-ignorant ]; then
            printf '\n'
            printf 'This machine does not know what time it is. TLS certificates require a date.\n'
            printf '  Set it:                 date MMDDhhmmYYYY\n'
            printf '  — or ask the network:   monolith-time\n'
        fi
        ;;
esac
