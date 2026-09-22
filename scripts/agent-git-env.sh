#!/bin/sh
# Restore working git inside a Paperclip agent run.
#
# Why this exists (DCX-131):
#   The execution workspace ships the right git config as discrete environment
#   pairs -- GIT_CONFIG_KEY_0=safe.directory / GIT_CONFIG_VALUE_0=* and a
#   GIT_CONFIG_KEY_1 credential helper -- but exports GIT_CONFIG_COUNT empty.
#   Git only reads GIT_CONFIG_KEY_n/VALUE_n for n < GIT_CONFIG_COUNT, so with
#   the count unset it silently ignores every pair. Because /workspace is owned
#   by root while runs execute as uid 1000, dropping safe.directory makes every
#   single git command die with:
#
#       fatal: detected dubious ownership in repository at '/workspace'
#
#   Agents read that as "there is no checkout here" and redo their work from
#   scratch. The error message's own remedy (git config --global --add
#   safe.directory) cannot work either, because GIT_CONFIG_GLOBAL and
#   GIT_CONFIG_SYSTEM are both pinned to /dev/null.
#
# Usage:
#   . scripts/agent-git-env.sh     # source it, then use git normally
#
# Verify it worked: `git status` must print a branch, not "dubious ownership".

# 1. Normalise GIT_CONFIG_COUNT: if it is empty/invalid but KEY_n pairs exist,
#    count the pairs the workspace actually exported.
case "${GIT_CONFIG_COUNT:-}" in
	'' | *[!0-9]*)
		n=0
		while eval "[ -n \"\${GIT_CONFIG_KEY_${n}+set}\" ]"; do
			n=$((n + 1))
		done
		GIT_CONFIG_COUNT=$n
		;;
esac
export GIT_CONFIG_COUNT

# 2. Guarantee safe.directory is among the pairs. Without it every git command
#    fails on the root-owned workspace, and the error's suggested fix cannot be
#    applied because GIT_CONFIG_GLOBAL/GIT_CONFIG_SYSTEM are both /dev/null.
found=no
n=0
while [ "$n" -lt "$GIT_CONFIG_COUNT" ]; do
	eval "key=\${GIT_CONFIG_KEY_${n}-}"
	[ "$key" = "safe.directory" ] && found=yes
	n=$((n + 1))
done
if [ "$found" = no ]; then
	eval "export GIT_CONFIG_KEY_${GIT_CONFIG_COUNT}=safe.directory"
	eval "export GIT_CONFIG_VALUE_${GIT_CONFIG_COUNT}='*'"
	GIT_CONFIG_COUNT=$((GIT_CONFIG_COUNT + 1))
	export GIT_CONFIG_COUNT
fi

# 3. Call `agent_git_clear_empty_identity` before committing. Empty
#    GIT_AUTHOR_*/GIT_COMMITTER_* values outrank `git -c user.name=...` and
#    produce "fatal: empty ident name (for <>) not allowed". This is a function
#    rather than unconditional, so sourcing the script never mutates a caller's
#    deliberately-set identity.
agent_git_clear_empty_identity() {
	for v in GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL; do
		eval "[ -z \"\${$v-}\" ] && unset $v"
	done
}
