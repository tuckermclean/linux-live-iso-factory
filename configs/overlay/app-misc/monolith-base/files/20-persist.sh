# /etc/profile.d/20-persist.sh
#
# Persist continuity (Monolith UX Pass Task 3): "the disc remembers you,
# when asked." Login STATUS line only — see
# /etc/bash/bashrc.d/50-persist-history.bash for the history-reliability
# half, split out to a separate file on review (a profile.d snippet's
# PROMPT_COMMAND wiring can be silently clobbered by Gentoo's stock
# /etc/bash/bashrc, which /etc/profile sources AFTER profile.d/*.sh — see
# that file's own header for the full reasoning).
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
        else
            printf 'persist: none (see monolith help persist)\n'
        fi
        unset _persist_fstype _persist_free _p_dev _p_mnt _p_fstype _p_rest
        ;;
esac
