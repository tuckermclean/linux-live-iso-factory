#!/bin/sh
# Unit tests for /etc/bash/bashrc.d/60-monolith-cnf.bash (Monolith UX Pass
# Task 5): bash's command_not_found_handle, pointing a miss at `monolith
# tools` instead of the bare "command not found".
#
# bashrc.d files are sourced unconditionally by bash's own bashrc chain (no
# `case "$-"` guard in the file itself -- see its header), so these tests
# source it directly inside `bash -c '...'` and then invoke a command that
# does not exist on PATH, letting bash's own dispatch call the handler --
# this exercises the real bash contract (argv, exit status), not just the
# function body in isolation.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../../configs/overlay/app-misc/monolith-base/files/60-monolith-cnf.bash"
fails=0
has() { if printf '%s' "$2" | grep -qF -- "$1"; then echo "  ok: $3"; else echo "  FAIL: $3 (wanted '$1')"; echo "----"; printf '%s\n' "$2"; echo "----"; fails=$((fails+1)); fi; }
has_not() { if printf '%s' "$2" | grep -qF -- "$1"; then echo "  FAIL: $3 (did NOT want '$1')"; fails=$((fails+1)); else echo "  ok: $3"; fi; }

# 1. an unknown command prints the monolith-tools redirect on stderr and
#    exits 127 (the standard "command not found" status).
out=$(bash -c ". '$SCRIPT'; this-command-does-not-exist-anywhere; echo \"RC=\$?\"" 2>&1)
has "this-command-does-not-exist-anywhere: not on the disc. 'monolith tools' lists what is." "$out" "unknown command names itself and points at monolith tools"
has 'RC=127' "$out" "unknown command exits 127"

# 2. the message goes to stderr, not stdout (scripts piping stdout should
#    not see it mixed in).
stdout_only=$(bash -c ". '$SCRIPT'; this-command-does-not-exist-anywhere" 2>/dev/null)
[ -z "$stdout_only" ] && echo "  ok: the redirect message is on stderr, not stdout" || { echo "  FAIL: stdout was not empty: $stdout_only"; fails=$((fails+1)); }

# 3. a real, existing command is completely unaffected -- the handler is
#    reached only on an actual PATH miss.
out=$(bash -c ". '$SCRIPT'; echo real-command-output; echo \"RC=\$?\"" 2>&1)
has 'real-command-output' "$out" "an existing command still runs normally"
has 'RC=0' "$out" "an existing command's exit status is untouched"
has_not 'not on the disc' "$out" "an existing command never triggers the not-on-the-disc message"

# 4. sourcing the file itself has no side effects (defines a function,
#    prints nothing, does not error).
out=$(bash -c ". '$SCRIPT'; echo \"SOURCE_RC=\$?\"" 2>&1)
has 'SOURCE_RC=0' "$out" "sourcing the file alone is silent and exits 0"

echo; [ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
