# /etc/profile.d/monolith-advisory.sh
#
# Displays a security warning at login if this build of The Monolith
# has been revoked (new CVEs discovered after the ISO was released).
#
# The advisory file is written by /usr/sbin/monolith-advisory-check
# at boot time (after networking comes up).
#
# This file is sourced by /etc/profile — do NOT use set -e, subshells,
# or command substitutions that could abort profile loading on error.

if [ -f /run/monolith-advisory ]; then
    _monolith_ver=
    [ -f /etc/monolith-release ] && read -r _monolith_ver < /etc/monolith-release
    printf '\n'
    printf '\033[1;33m!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\033[0m\n'
    printf '\033[1;33m!!          SECURITY ADVISORY — ACTION REQUIRED    !!\033[0m\n'
    printf '\033[1;33m!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\033[0m\n'
    printf '\033[0;33m\n'
    printf 'This build of The Monolith %s has been marked REVOKED.\n' "$_monolith_ver"
    printf 'One or more CVEs were discovered after this ISO was released.\n'
    printf 'Please obtain a newer build as soon as possible.\n'
    printf '\n'
    # Print CVE IDs if present in the advisory JSON (simple grep extraction)
    if grep -q '"advisories"' /run/monolith-advisory 2>/dev/null; then
        printf 'Affected CVEs: '
        # Extract CVE IDs — grep for CVE-YYYY-NNNNN pattern, one per line
        grep -o 'CVE-[0-9][0-9][0-9][0-9]-[0-9]*' /run/monolith-advisory 2>/dev/null \
            | tr '\n' ' '
        printf '\n'
    fi
    if grep -q '"details_url"' /run/monolith-advisory 2>/dev/null; then
        printf 'Details: '
        # Extract URL value — relies on simple JSON key ordering
        grep -o '"details_url"[^"]*"[^"]*"' /run/monolith-advisory 2>/dev/null \
            | grep -o '"[^"]*"$' \
            | tr -d '"'
        printf '\n'
    fi
    printf '\033[0m\n'
fi
