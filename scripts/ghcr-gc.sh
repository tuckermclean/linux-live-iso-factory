#!/bin/sh
# GHCR garbage collector for the monolith-binpkgs container package.
# Mirrors scripts/s3-gc.sh: dry-run default, --apply to delete, abort guard,
# KEEP-first classification.
#
# classify TAG CURRENT_EPOCH -> "KEEP" | "DELETE"
set -u
classify() {
    tag="$1"; cur="$2"
    case "$tag" in
        "$cur") echo KEEP; return;;                                       # current epoch
        [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) echo DELETE; return;;   # old 8-digit epoch
        *) echo KEEP; return;;                                            # unknown/non-epoch -> keep (safe)
    esac
}

# version_verdict TAGS_CSV CURRENT_EPOCH -> "KEEP" | "DELETE"
# A version may carry multiple tags. Condemn a version only if ALL its tags
# classify DELETE; if any tag is KEEP (or there are no tags at all), keep the
# whole version (KEEP-first: untagged versions are never pruned here).
version_verdict() {
    tags_csv="$1"; cur="$2"
    if [ -z "$tags_csv" ]; then
        echo KEEP; return
    fi
    old_ifs="$IFS"; IFS=','
    set -- $tags_csv
    IFS="$old_ifs"
    for t in "$@"; do
        if [ "$(classify "$t" "$cur")" = KEEP ]; then
            echo KEEP; return
        fi
    done
    echo DELETE
}

# --source-only detection: `sh`/dash's `.` (unlike bash) does not propagate
# arguments into the sourced file, so "${1:-}" alone is unreliable for
# detecting `. ghcr-gc.sh --source-only` under dash. $0 stays as the sourcing
# script's own path under both shells when sourced, so fall back to a
# basename check: if we're not being run as ourselves, treat it as sourced.
case "${0##*/}" in
    ghcr-gc.sh) sourced=0 ;;
    *) sourced=1 ;;
esac
if [ "${1:-}" = "--source-only" ] || [ "$sourced" -eq 1 ]; then
    return 0
fi

# Live mode: KEEP_EPOCH + GITHUB_REPOSITORY_OWNER required. --apply to
# delete; default dry-run. Auth comes from the ambient gh token (GH_TOKEN /
# GITHUB_TOKEN env, set by the workflow) — no secrets read directly here.
CUR="${KEEP_EPOCH:?set KEEP_EPOCH}"
OWNER=$(printf '%s' "${GITHUB_REPOSITORY_OWNER:?set GITHUB_REPOSITORY_OWNER}" | tr '[:upper:]' '[:lower:]')
APPLY=""; [ "${1:-}" = "--apply" ] && APPLY=1

PKG="monolith-binpkgs"
TAB="$(printf '\t')"

# Capture the listing ONCE (same rationale as s3-gc.sh: looping over a piped
# command drops counters updated in the loop body because of the subshell
# `cmd | while read` creates). Each line: "<version-id> TAB <comma-tags-or-empty>".
ERRFILE=$(mktemp)
LISTING=$(gh api --paginate "/user/packages/container/$PKG/versions" \
    --jq '.[] | [.id, ((.metadata.container.tags // []) | join(","))] | @tsv' 2>"$ERRFILE")
status=$?
ERR=$(cat "$ERRFILE"); rm -f "$ERRFILE"

if [ "$status" -ne 0 ]; then
    # GitHub's API deliberately returns 404 for permission-denied/inaccessible
    # resources too (info-disclosure mitigation), not only for genuinely
    # missing packages. Treating every 404 as benign would let a scope
    # regression (bad GH_TOKEN, wrong OWNER, org policy change) silently
    # no-op the GC forever with no failure signal. So: auth/permission-shaped
    # errors are a HARD failure first; only a message that actually carries
    # not-found semantics is swallowed as benign. When in doubt, fail loud —
    # a noisy GC failure is recoverable, a silently dead GC is not.
    if printf '%s' "$ERR" | grep -Eqi 'bad credentials|resource not accessible|must have admin|HTTP 403|403 Forbidden'; then
        echo "ghcr-gc: ABORT — auth/permission error listing package versions (check GH_TOKEN scope / packages:write): $ERR" >&2
        exit 1
    fi
    if printf '%s' "$ERR" | grep -Eqi 'Not Found|Package .* not found|HTTP 404'; then
        echo "ghcr-gc: package $PKG not found (404) — nothing to GC yet." >&2
        exit 0
    fi
    echo "ghcr-gc: failed to list package versions: $ERR" >&2
    exit "$status"
fi

# Counting pass: abort if the keep-list would match nothing (mis-set
# epoch/owner is the classic way to accidentally delete everything).
total=0; keep=0
while IFS="$TAB" read -r id tags_csv; do
    [ -z "$id" ] && continue
    total=$((total+1))
    [ "$(version_verdict "$tags_csv" "$CUR")" = KEEP ] && keep=$((keep+1))
done <<EOF
$LISTING
EOF

if [ "$total" -gt 0 ] && [ "$keep" -eq 0 ]; then
    echo "ghcr-gc: ABORT — keep-list matched 0 of $total versions (mis-set epoch/owner?). Refusing to delete." >&2
    exit 1
fi

# A genuinely empty listing (0 versions, no error) is indistinguishable here
# from a masked permission problem: GITHUB_TOKEN lacking authority over
# /user/packages/container/... can surface as a plain empty array rather than
# the 403/404 caught above, so the GC would otherwise exit 0 having silently
# done nothing, forever, with no signal. Stay fail-open (exit 0 still covers
# the legitimate not-pushed-yet bootstrap case) but make it loud.
if [ "$total" -eq 0 ]; then
    echo "ghcr-gc: NOTE — 0 package versions returned for $PKG (owner=$OWNER). If versions were expected, verify GH_TOKEN has packages access (delete:packages) and OWNER is correct. Run a manual 'gh api /user/packages/container/$PKG/versions' to confirm." >&2
fi

# Delete pass — same captured listing, so it's consistent with the count above.
del=0
while IFS="$TAB" read -r id tags_csv; do
    [ -z "$id" ] && continue
    if [ "$(version_verdict "$tags_csv" "$CUR")" = DELETE ]; then
        del=$((del+1))
        echo "DELETE ghcr.io/$OWNER/$PKG:$tags_csv (version $id)"
        [ -n "$APPLY" ] && gh api --method DELETE "/user/packages/container/$PKG/versions/$id" >/dev/null
    fi
done <<EOF
$LISTING
EOF

# A successful run must exit 0 regardless of which command the delete loop's
# last iteration happened to execute — otherwise a trailing false test (e.g.
# `[ -n "$APPLY" ]` in dry-run mode, which short-circuits `&&` to a false
# exit status) leaks out as the script's exit status and makes the weekly
# cron dry-run show as a failed GitHub Actions run even though nothing is
# wrong. The abort guard above already exits 1 on the genuine mis-set-epoch
# case, so it's correct for this to be an unconditional success exit.
exit 0
