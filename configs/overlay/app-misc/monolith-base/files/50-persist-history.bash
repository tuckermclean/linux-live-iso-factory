# /etc/bash/bashrc.d/50-persist-history.bash
#
# Persist continuity (Monolith UX Pass Task 3), history-reliability half.
#
# Split out of /etc/profile.d/20-persist.sh (which keeps only the login
# status line) on review: /etc/profile sources /etc/profile.d/*.sh BEFORE
# /etc/bash/bashrc (see scripts/build-rootfs.sh's /etc/profile heredoc:
# profile.d drop-ins run, THEN /etc/bash/bashrc). Gentoo's stock
# /etc/bash/bashrc (shipped by app-shells/bash, not in this repo) may
# assign PROMPT_COMMAND unconditionally — a profile.d snippet setting
# PROMPT_COMMAND could be silently clobbered before it ever fires. This
# file instead lives in /etc/bash/bashrc.d, which the stock bashrc sources
# itself, AFTER doing its own setup (mirrors 99-monolith-square.bash, which
# already relies on running "last" in that same chain) — so nothing here
# can be stomped on by whatever the stock bashrc does with PROMPT_COMMAND.
#
# Only /etc/bash/bashrc sources this chain, and only for interactive shells
# — this file is bash-only by construction (no BASH_VERSION guard needed,
# contrast 20-persist.sh, which is POSIX profile.d and DOES guard its
# bash-only bits) but still checks `$-` itself as a defense-in-depth match
# for that same interactive-only intent.
#
# MONOLITH_PERSIST_DIR / MONOLITH_PERSIST_MOUNTS override the mountpoint
# and mount-table path this checks (default /overlay, /proc/mounts) — a
# test hook only, mirroring monolith-net's MONOLITH_NET_SYSCLASS pattern;
# unset in production so this always reads the real mount. Kept identical
# to 20-persist.sh's own detection so the two files agree on "is persist
# real" without sharing state (each does its own cheap /proc/mounts read).

: "${MONOLITH_PERSIST_DIR:=/overlay}"
: "${MONOLITH_PERSIST_MOUNTS:=/proc/mounts}"

case "$-" in
    *i*)
        _persist_fstype=""
        while read -r _p_dev _p_mnt _p_fstype _p_rest; do
            [ "$_p_mnt" = "$MONOLITH_PERSIST_DIR" ] && _persist_fstype="$_p_fstype"
        done < "$MONOLITH_PERSIST_MOUNTS"

        if [ -n "$_persist_fstype" ] && [ "$_persist_fstype" != "tmpfs" ]; then
            # History reliability: bash only appends $HISTFILE on a CLEAN
            # shell exit, so an unclean poweroff (exactly the case persist
            # exists to survive) loses every command typed since the last
            # clean exit — even though the file itself is already on a
            # partition that persists. `shopt -s histappend` + a
            # per-prompt `history -a` turns that into an incremental
            # append: the instant a prompt redraws, the just-run command
            # is already on disk. Both are bash BUILTINS (no fork/exec),
            # so the added per-prompt cost is one small write to a file
            # already open — negligible even at -cpu 486. Gated on a REAL
            # persist mount: no point paying even that on tmpfs, and never
            # redirects $HISTFILE off the overlay (it's already there).
            shopt -s histappend
            case "$PROMPT_COMMAND" in
                *'history -a'*) ;;
                *) PROMPT_COMMAND="history -a${PROMPT_COMMAND:+; $PROMPT_COMMAND}" ;;
            esac
        fi
        unset _persist_fstype _p_dev _p_mnt _p_fstype _p_rest
        ;;
esac
