# /etc/profile.d/20-persist.sh
#
# Persist continuity (Monolith UX Pass Task 3): "the disc remembers you,
# when asked."
#
# The WHOLE rootfs is an overlayfs (lowerdir=/squashfs,
# upperdir=/overlay/upper, workdir=/overlay/work — see rootfs/init). When
# boot found a partition labeled MONOLITH_PERSIST (the `persist` kernel
# param), /overlay IS that partition and every write under / — shell
# history, ~/.vimrc, ~/.inputrc, /etc/profile.local, anything — already
# survives a reboot with no redirection or symlinking needed. When
# `persist` wasn't requested or no such partition was found, /overlay is a
# plain tmpfs and vanishes at power-off. See: monolith help persist.
#
# This file is sourced by /etc/profile — do NOT use set -e, subshells, or
# command substitutions that could abort profile loading on error.
#
# MONOLITH_PERSIST_DIR / MONOLITH_PERSIST_MOUNTS override the mountpoint
# and mount-table path this checks (default /overlay, /proc/mounts) — a
# test hook only, mirroring monolith-net's MONOLITH_NET_SYSCLASS pattern;
# unset in production so this always reads the real mount.

: "${MONOLITH_PERSIST_DIR:=/overlay}"
: "${MONOLITH_PERSIST_MOUNTS:=/proc/mounts}"

case "$-" in
    *i*)
        # Is $MONOLITH_PERSIST_DIR the real persistent partition, or the
        # tmpfs fallback? One mount-table read (cheap, no subprocess).
        # Take the LAST match for the mountpoint in case of stacked mounts.
        _persist_fstype=""
        while read -r _p_dev _p_mnt _p_fstype _p_rest; do
            [ "$_p_mnt" = "$MONOLITH_PERSIST_DIR" ] && _persist_fstype="$_p_fstype"
        done < "$MONOLITH_PERSIST_MOUNTS"

        if [ -n "$_persist_fstype" ] && [ "$_persist_fstype" != "tmpfs" ]; then
            _persist_free=$(df -m "$MONOLITH_PERSIST_DIR" 2>/dev/null | awk 'NR==2 {print $4}')
            printf 'persist: mounted (%s MB free)\n' "${_persist_free:-?}"

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
            if [ -n "$BASH_VERSION" ]; then
                shopt -s histappend
                case "$PROMPT_COMMAND" in
                    *'history -a'*) ;;
                    *) PROMPT_COMMAND="history -a${PROMPT_COMMAND:+; $PROMPT_COMMAND}" ;;
                esac
            fi
        else
            printf 'persist: none (see monolith help persist)\n'
        fi
        unset _persist_fstype _persist_free _p_dev _p_mnt _p_fstype _p_rest
        ;;
esac
