# /etc/bash/bashrc.d/60-monolith-cnf.bash
#
# bash's command_not_found_handle hook (Monolith UX Pass Task 5): point at
# `monolith tools` instead of bash's bare "command not found". Lives in
# bashrc.d, not profile.d, because this is a function DEFINITION that must
# exist for the lifetime of the shell, not a one-shot login side effect —
# command_not_found_handle is only ever consulted by bash itself, at the
# moment a typed command's own PATH search already failed, so defining it
# here (bashrc.d already only sources for interactive bash — see
# 99-monolith-square.bash's own note) needs no separate interactive guard.
#
# Fires only on an actual miss — zero per-prompt cost, matching this
# repo's FAST-on-a-486 profile budget.

command_not_found_handle() {
    printf "%s: not on the disc. 'monolith tools' lists what is.\n" "$1" >&2
    return 127
}
