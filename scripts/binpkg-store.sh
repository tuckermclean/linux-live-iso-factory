#!/bin/bash
#
# binpkg-store.sh — GHCR-backed OCI store for the build epoch's binary packages.
#
# WHY: CI used to `aws s3 sync` the ENTIRE epoch's binpkg set (PKGDIR,
# Portage GPKG multi-instance layout) into output/packages/ on every build —
# one object per gpkg, most of them unchanged run to run. That per-object S3
# sync is the big transfer-cost line item. This replaces it with a single OCI
# artifact per epoch on GHCR (ghcr.io/<owner>/monolith-binpkgs:<epoch>),
# pushed/pulled as one deterministic tar+zstd blob via `oras` — one GET, one
# PUT, whole-epoch granularity — and prunes superseded package builds first so
# the artifact only ever carries current-best gpkgs, not every revision ever
# built. See docs/superpowers/plans/2026-08-18-ci-efficiency-round2.md.
#
# Mechanism: GHCR single-layer OCI via `oras push`/`oras pull` (ruling R0).
# Deliberately NOT `docker import` — that fakes container-image semantics for
# what is just an opaque blob; oras treats it as what it is, an OCI artifact
# with one layer.
#
# Portage GPKG layout (PKGDIR root):
#   <CATEGORY>/<PN>/<PN>-<PVR>-<BUILDID>.gpkg.tar
#   e.g. net-dns/dnsmasq/dnsmasq-2.90-r1-3.gpkg.tar
#   PVR (version + optional Gentoo revision, e.g. "2.90-r1" or
#   "1.0_p20260805") is everything between "<PN>-" and the final
#   "-<BUILDID>" (BUILDID is a trailing integer appended by
#   binpkg-multi-instance, disjoint from a "-rN" Gentoo revision because a
#   revision always carries the literal "r"). The root also holds a
#   plaintext binhost index (Packages, maybe Packages.gz) that `emaint
#   binhost --fix` regenerates; prune must invalidate it since a stale index
#   can point at a gpkg that pruning just deleted.
#
# Subcommands:
#   pack             tar+zstd PKGDIR deterministically -> a single blob
#   push             oras push the blob as ghcr.io/<owner>/monolith-binpkgs:<epoch>
#   pull             oras pull + unpack into PKGDIR; FAILS OPEN (warn + empty
#                    dir + exit 0) when the epoch tag doesn't exist yet (first
#                    build of a new epoch) or `oras` itself is missing — the
#                    build then just compiles from source, same as an S3 miss
#                    does today. A genuine unexpected error (auth failure,
#                    corrupt pull, truncated archive) is NOT swallowed; it
#                    exits non-zero so CI surfaces it instead of silently
#                    losing the whole binpkg cache.
#   prune            delete every gpkg that isn't the newest PVR for its
#                    <CAT>/<PN> (except versions.lock pins, which are always
#                    kept even if a newer PVR exists locally), then invalidate
#                    the Packages/Packages.gz index. Run before `pack`.
#   prune-predicate  the PURE decision function `prune` is built on: reads a
#                    newline-delimited listing of PKGDIR-relative gpkg paths
#                    on stdin (plus an optional versions.lock path argument),
#                    and prints the paths that WOULD be deleted — one per
#                    line, in input order, nothing else. No filesystem
#                    mutation, no network. This is what
#                    scripts/tests/binpkg-store.test.sh drives directly.
#
# Config is via args (each subcommand takes positional overrides — see
# `usage()`) or environment, never hardcoded:
#   GHCR_OWNER      GHCR namespace owner. Falls back to GITHUB_REPOSITORY_OWNER
#                   (set for free in Actions) when unset.
#   BUILD_EPOCH     epoch tag (matches the Dockerfile ARG / build.yml env of
#                   the same name).
#   PKGDIR          the binpkg tree. Defaults to <repo>/output/packages,
#                   which is what /output/packages resolves to under the
#                   repo checkout on the runner (see configs/portage/make.conf).
#   VERSIONS_LOCK   path to versions.lock. Defaults to
#                   configs/portage/versions.lock.
#   BINPKG_TARBALL  pack/push blob path. Defaults to <repo>/output/binpkgs.tar.zst.
#
# GHCR auth (oras login / docker login) is assumed already done by the caller
# (a later CI task runs it) — this script does not implement login.
#
# Idempotent and best-effort where the interface above says so (pull fails
# open on a missing tag); best-effort does NOT mean silent about real errors.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

OWNER_DEFAULT="${GHCR_OWNER:-${GITHUB_REPOSITORY_OWNER:-}}"
EPOCH_DEFAULT="${BUILD_EPOCH:-}"
PKGDIR_DEFAULT="${PKGDIR:-${REPO_ROOT}/output/packages}"
VERSIONS_LOCK_DEFAULT="${VERSIONS_LOCK:-${REPO_ROOT}/configs/portage/versions.lock}"
TARBALL_DEFAULT="${BINPKG_TARBALL:-${REPO_ROOT}/output/binpkgs.tar.zst}"
IMAGE_REPO="monolith-binpkgs"

usage() {
    cat <<'EOF'
Usage: binpkg-store.sh <command> [args...]

Commands:
  pack   [pkgdir] [tarball]              tar+zstd pkgdir -> tarball (deterministic)
  push   [owner] [epoch] [tarball]       oras push tarball as ghcr.io/<owner>/monolith-binpkgs:<epoch>
  pull   [owner] [epoch] [pkgdir]        oras pull + unpack into pkgdir (fails open on a missing tag)
  prune  [pkgdir] [versions-lock]        delete superseded gpkgs, invalidate the Packages index
  prune-predicate [versions-lock]        pure function: reads a gpkg path listing on stdin,
                                          prints the paths that would be deleted (testing hook)
  pull-is-benign-miss                    pure function: reads an `oras pull` stderr capture on
                                          stdin, exits 0 if it's a benign "nothing published yet"
                                          miss (fail-open) or 1 for a genuine error (testing hook)

Config defaults come from env: GHCR_OWNER, BUILD_EPOCH, PKGDIR, VERSIONS_LOCK, BINPKG_TARBALL.
EOF
}

# --- Gentoo PVR ("package version + revision") comparator --------------------
#
# Grammar handled: <dotted-numeric>[single-trailing-letter]{_suffix{digits}}*[-rN]
# e.g. "2.90", "2.90-r1", "1.0_p20260805", "1.0_rc1", "1.2.3a_beta2-r4".
#
# Ordering implemented (most to least significant):
#   1. Dotted numeric components, left to right, integer comparison (each
#      forced base-10 via `10#` so a component like "090" is never
#      misread as octal). A version with FEWER components than another,
#      once their shared prefix is equal, sorts LOWER than the version with
#      the extra trailing component (i.e. "1.1" < "1.1.0") — a deliberate,
#      documented choice for the case PMS leaves ambiguous in practice; not
#      exercised by any real package in this tree.
#   2. Single trailing letter on the last numeric component (e.g. the "a" in
#      "2.90a"), plain string order, absent < 'a' < 'b' < ...
#   3. The "_suffix" chain (each of alpha/beta/pre/rc/p, each with an
#      optional trailing digit run defaulting to 0), compared position by
#      position. Each type has a fixed rank:
#        alpha(0) < beta(1) < pre(2) < rc(3) < NO-SUFFIX(4) < p(5)
#      "no suffix" is a virtual entry used once one side's chain is
#      exhausted — this is what makes plain "1.0" rank ABOVE "1.0_rc1" (rc's
#      rank 3 < no-suffix's rank 4) but BELOW "1.0_p1" (p's rank 5 > 4).
#      Within the same suffix type at the same position, the trailing digit
#      runs are compared numerically (also forced base-10).
#   4. The "-rN" revision suffix, numeric, absent == 0 (so "2.90-r1" > "2.90").
#
# Known limits (documented per design-brief request rather than guessed
# around): this does NOT implement PMS's leading-zero-forces-string-compare
# rule for numeric components (e.g. a hypothetical "1.010" vs "1.02" pair);
# an unrecognized suffix token (not alpha/beta/pre/rc/p) is silently dropped
# rather than erroring. Neither case appears in this repo's actual package
# set. The pinned-version guard in prune_predicate is the safety net if a
# future package ever hits one of these edges: a pin is never deleted
# regardless of what the comparator decides is "newest".

_bp_version_parse() {
    local v="$1"
    _BPV_NUMS=(); _BPV_LETTER=""; _BPV_REV=0
    _BPV_STYPES=(); _BPV_SNUMS=()

    if [[ "$v" =~ ^(.*)-r([0-9]+)$ ]]; then
        v="${BASH_REMATCH[1]}"
        _BPV_REV="${BASH_REMATCH[2]}"
    fi

    local main="$v"
    local -a suffixes=()
    while [[ "$main" == *_* ]]; do
        suffixes=("${main##*_}" "${suffixes[@]}")
        main="${main%_*}"
    done

    if [[ "$main" =~ ^([0-9][0-9.]*)([a-z])$ ]]; then
        main="${BASH_REMATCH[1]}"
        _BPV_LETTER="${BASH_REMATCH[2]}"
    fi

    IFS='.' read -r -a _BPV_NUMS <<< "$main"

    local s
    for s in "${suffixes[@]}"; do
        if [[ "$s" =~ ^(alpha|beta|pre|rc|p)([0-9]*)$ ]]; then
            _BPV_STYPES+=("${BASH_REMATCH[1]}")
            _BPV_SNUMS+=("${BASH_REMATCH[2]:-0}")
        fi
        # else: unrecognized suffix token — dropped, see "Known limits" above.
    done
}

_bp_suffix_rank() {
    case "$1" in
        alpha) echo 0 ;;
        beta)  echo 1 ;;
        pre)   echo 2 ;;
        rc)    echo 3 ;;
        none)  echo 4 ;;
        p)     echo 5 ;;
        *)     echo 4 ;;
    esac
}

# _bp_version_gt A B — true (exit 0) iff PVR string A is strictly newer than B.
_bp_version_gt() {
    local va="$1" vb="$2"

    _bp_version_parse "$va"
    local -a a_nums=("${_BPV_NUMS[@]}") a_stypes=("${_BPV_STYPES[@]}") a_snums=("${_BPV_SNUMS[@]}")
    local a_letter="$_BPV_LETTER" a_rev="$_BPV_REV"

    _bp_version_parse "$vb"
    local -a b_nums=("${_BPV_NUMS[@]}") b_stypes=("${_BPV_STYPES[@]}") b_snums=("${_BPV_SNUMS[@]}")
    local b_letter="$_BPV_LETTER" b_rev="$_BPV_REV"

    local i n=${#a_nums[@]}
    (( ${#b_nums[@]} > n )) && n=${#b_nums[@]}
    for (( i=0; i<n; i++ )); do
        local an bn
        if (( i < ${#a_nums[@]} )); then an=$((10#${a_nums[i]:-0})); else an=-1; fi
        if (( i < ${#b_nums[@]} )); then bn=$((10#${b_nums[i]:-0})); else bn=-1; fi
        if (( an != bn )); then
            (( an > bn )) && return 0 || return 1
        fi
    done

    if [[ "$a_letter" != "$b_letter" ]]; then
        [[ "$a_letter" > "$b_letter" ]] && return 0 || return 1
    fi

    n=${#a_stypes[@]}
    (( ${#b_stypes[@]} > n )) && n=${#b_stypes[@]}
    for (( i=0; i<n; i++ )); do
        local at bt ar br
        if (( i < ${#a_stypes[@]} )); then at="${a_stypes[i]}"; else at="none"; fi
        if (( i < ${#b_stypes[@]} )); then bt="${b_stypes[i]}"; else bt="none"; fi
        ar=$(_bp_suffix_rank "$at")
        br=$(_bp_suffix_rank "$bt")
        if (( ar != br )); then
            (( ar > br )) && return 0 || return 1
        fi
        local asn bsn
        if (( i < ${#a_snums[@]} )); then asn=$((10#${a_snums[i]:-0})); else asn=0; fi
        if (( i < ${#b_snums[@]} )); then bsn=$((10#${b_snums[i]:-0})); else bsn=0; fi
        if (( asn != bsn )); then
            (( asn > bsn )) && return 0 || return 1
        fi
    done

    local a_rev_n=$((10#${a_rev:-0})) b_rev_n=$((10#${b_rev:-0}))
    (( a_rev_n > b_rev_n )) && return 0
    return 1
}

# --- gpkg path parsing --------------------------------------------------------

# parse_gpkg_entry REL_PATH — sets _CAT, _PN, _PVR, _BUILDID on success;
# returns 1 (and leaves them empty) if REL_PATH isn't CAT/PN/PN-PVR-BUILDID.gpkg.tar.
parse_gpkg_entry() {
    local rel="$1"
    _CAT=""; _PN=""; _PVR=""; _BUILDID=""

    local cat="${rel%%/*}"
    [[ "$cat" == "$rel" ]] && return 1
    local rest="${rel#*/}"
    [[ "$rest" == */* ]] || return 1
    local pn="${rest%%/*}"
    local file="${rest#*/}"
    [[ "$file" == */* ]] && return 1
    [[ "$file" == "${pn}-"*".gpkg.tar" ]] || return 1

    local mid="${file#"${pn}-"}"
    mid="${mid%.gpkg.tar}"
    [[ "$mid" =~ ^(.+)-([0-9]+)$ ]] || return 1

    _CAT="$cat"; _PN="$pn"; _PVR="${BASH_REMATCH[1]}"; _BUILDID="${BASH_REMATCH[2]}"
    return 0
}

# --- prune predicate (pure) ---------------------------------------------------

# prune_predicate [VERSIONS_LOCK_PATH] — reads a newline-delimited listing of
# PKGDIR-relative gpkg paths on stdin, prints (to stdout) the subset that
# should be DELETED: for each <CAT>/<PN> group, every entry except the one
# with the newest PVR survives deletion UNLESS its PVR matches a
# versions.lock pin for that <CAT>/<PN> — pins are never deleted, even when a
# newer PVR exists in the same group (both the newest and the pin survive in
# that case). Unparseable lines are skipped with a warning on stderr, never
# fatal. No filesystem access beyond reading the optional lock file; no
# network; deterministic (output preserves input order).
prune_predicate() {
    local lockfile="${1:-}"
    local -A pin_version=()

    if [[ -n "$lockfile" && -f "$lockfile" ]]; then
        local line atom ver slot
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line%%#*}"
            line="${line%$'\r'}"
            [[ -z "${line//[[:space:]]/}" ]] && continue
            IFS=: read -r atom ver slot <<< "$line"
            [[ -z "$atom" || -z "$ver" ]] && continue
            pin_version["$atom"]="$ver"
        done < "$lockfile"
    fi

    local -a all_paths=()
    local -A path_key=() path_pvr=() best_pvr=()
    local path key

    while IFS= read -r path || [[ -n "$path" ]]; do
        [[ -z "$path" ]] && continue
        if ! parse_gpkg_entry "$path"; then
            echo "binpkg-store: prune: WARNING: skipping unparseable gpkg path: ${path}" >&2
            continue
        fi
        key="${_CAT}/${_PN}"
        all_paths+=("$path")
        path_key["$path"]="$key"
        path_pvr["$path"]="$_PVR"
        if [[ -z "${best_pvr[$key]+x}" ]]; then
            best_pvr["$key"]="$_PVR"
        elif _bp_version_gt "$_PVR" "${best_pvr[$key]}"; then
            best_pvr["$key"]="$_PVR"
        fi
    done

    for path in "${all_paths[@]}"; do
        key="${path_key[$path]}"
        local pvr="${path_pvr[$path]}"
        local keep=0
        [[ "$pvr" == "${best_pvr[$key]}" ]] && keep=1
        if [[ -n "${pin_version[$key]+x}" && "${pin_version[$key]}" == "$pvr" ]]; then
            keep=1
        fi
        [[ "$keep" -eq 0 ]] && echo "$path"
    done
}

# --- pull error classification (pure) -----------------------------------------

# _bp_pull_is_benign_miss ERR_TEXT — pure predicate: exit 0 if ERR_TEXT (an
# `oras pull` stderr capture) represents a benign "nothing published for this
# epoch yet" condition that `pull` should fail OPEN on (warn + empty PKGDIR +
# exit 0); exit 1 for a genuine error that should propagate non-zero.
#
# GHCR's well-known quirk: pulling a tag from a package repository that has
# NEVER been pushed to returns 401 Unauthorized / "denied", NOT 404 — and
# that unauthorized/denied response is exactly the first-build-of-a-new-epoch
# bootstrap this fail-open path exists to protect. So unauthorized/denied/401
# must classify as benign here alongside the more conventional
# not-found/manifest-unknown/name-unknown/404 tokens, or the very first CI
# pull of a brand new epoch would hit the genuine-error branch instead and
# break the "compile from source on an empty store" guarantee.
_bp_pull_is_benign_miss() {
    printf '%s' "$1" | grep -qiE 'not found|manifest unknown|name unknown|404|unauthorized|denied|401'
}

# --- filesystem-facing subcommands -------------------------------------------

cmd_prune() {
    local pkgdir="${1:-$PKGDIR_DEFAULT}"
    local lockfile="${2:-$VERSIONS_LOCK_DEFAULT}"

    if [[ ! -d "$pkgdir" ]]; then
        echo "binpkg-store: prune: ${pkgdir} does not exist — nothing to prune"
        return 0
    fi

    local listing
    listing="$(cd "$pkgdir" && find . -name '*.gpkg.tar' -type f -print | sed 's|^\./||')"

    if [[ -z "$listing" ]]; then
        echo "binpkg-store: prune: no gpkgs found under ${pkgdir}"
    else
        local to_delete
        to_delete="$(printf '%s\n' "$listing" | prune_predicate "$lockfile")"
        local n=0 rel
        while IFS= read -r rel; do
            [[ -z "$rel" ]] && continue
            rm -f -- "${pkgdir}/${rel}"
            n=$((n + 1))
        done <<< "$to_delete"
        echo "binpkg-store: prune: deleted ${n} superseded gpkg(s)"
    fi

    # Invalidate the binhost index so it never references a deleted gpkg.
    # The build step regenerates it with `emaint binhost --fix` after a pull.
    rm -f "${pkgdir}/Packages" "${pkgdir}/Packages.gz"
    echo "binpkg-store: prune: invalidated the Packages/Packages.gz binhost index"
}

cmd_pack() {
    local pkgdir="${1:-$PKGDIR_DEFAULT}"
    local out="${2:-$TARBALL_DEFAULT}"

    if [[ ! -d "$pkgdir" ]]; then
        echo "binpkg-store: pack: ${pkgdir} does not exist — nothing to pack" >&2
        return 1
    fi
    if ! command -v zstd >/dev/null 2>&1; then
        echo "binpkg-store: pack: FATAL: zstd not found on PATH" >&2
        return 1
    fi

    mkdir -p "$(dirname "$out")"
    echo "binpkg-store: pack: tarring ${pkgdir} -> ${out}"
    tar --sort=name --numeric-owner --owner=0 --group=0 \
        --mtime="@${SOURCE_DATE_EPOCH:-0}" \
        -C "$pkgdir" -cf - . \
        | zstd -q -T0 -f -o "$out" -
}

cmd_push() {
    local owner="${1:-$OWNER_DEFAULT}"
    local epoch="${2:-$EPOCH_DEFAULT}"
    local tarball="${3:-$TARBALL_DEFAULT}"

    : "${owner:?binpkg-store push: owner required (arg, or GHCR_OWNER/GITHUB_REPOSITORY_OWNER env)}"
    : "${epoch:?binpkg-store push: epoch required (arg, or BUILD_EPOCH env)}"

    if [[ ! -f "$tarball" ]]; then
        echo "binpkg-store: push: ${tarball} not found — run 'pack' first" >&2
        return 1
    fi
    if ! command -v oras >/dev/null 2>&1; then
        echo "binpkg-store: push: FATAL: oras not found on PATH" >&2
        return 1
    fi

    local ref="ghcr.io/${owner}/${IMAGE_REPO}:${epoch}"
    echo "binpkg-store: push: pushing ${tarball} -> ${ref}"
    # oras rejects an ABSOLUTE file path by default ("absolute file path
    # detected") — the path becomes the layer's title annotation, and an
    # absolute one would make `pull` try to restore outside its workdir. Push
    # from the tarball's own directory so the stored name is a clean relative
    # basename (e.g. "binpkgs.tar.zst"); cmd_pull globs *.tar.zst, so it stays
    # compatible regardless of the name.
    local dir base
    dir="$(cd "$(dirname "$tarball")" && pwd)"
    base="$(basename "$tarball")"
    ( cd "$dir" && oras push "$ref" "${base}:application/vnd.oci.image.layer.v1.tar+zstd" )
}

cmd_pull() {
    local owner="${1:-$OWNER_DEFAULT}"
    local epoch="${2:-$EPOCH_DEFAULT}"
    local pkgdir="${3:-$PKGDIR_DEFAULT}"

    : "${owner:?binpkg-store pull: owner required (arg, or GHCR_OWNER/GITHUB_REPOSITORY_OWNER env)}"
    : "${epoch:?binpkg-store pull: epoch required (arg, or BUILD_EPOCH env)}"

    mkdir -p "$pkgdir"

    if ! command -v oras >/dev/null 2>&1; then
        echo "binpkg-store: pull: WARNING: oras not found on PATH — leaving ${pkgdir} empty (fail-open, build compiles from source)" >&2
        return 0
    fi

    local ref="ghcr.io/${owner}/${IMAGE_REPO}:${epoch}"
    local workdir
    workdir="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '${workdir}'" RETURN

    local err rc
    err="$(oras pull "$ref" -o "$workdir" 2>&1)"; rc=$?
    if [[ $rc -ne 0 ]]; then
        if _bp_pull_is_benign_miss "$err"; then
            echo "binpkg-store: pull: no store for epoch ${epoch} yet (${ref}) — starting from an empty cache (fail-open, build compiles from source)"
            return 0
        fi
        echo "binpkg-store: pull: ERROR: oras pull failed unexpectedly for ${ref}: ${err}" >&2
        return 1
    fi

    local tarball
    tarball="$(find "$workdir" -maxdepth 1 -name '*.tar.zst' -print | head -1)"
    if [[ -z "$tarball" ]]; then
        echo "binpkg-store: pull: ERROR: pulled ${ref} but found no .tar.zst layer in it" >&2
        return 1
    fi

    echo "binpkg-store: pull: unpacking ${tarball} -> ${pkgdir}"
    if ! zstd -dc "$tarball" | tar -x -C "$pkgdir"; then
        echo "binpkg-store: pull: ERROR: failed to unpack ${tarball} into ${pkgdir}" >&2
        return 1
    fi
}

# --- main ---------------------------------------------------------------------

CMD="${1:-}"
shift || true

case "$CMD" in
    pack)             cmd_pack "$@" ;;
    push)             cmd_push "$@" ;;
    pull)             cmd_pull "$@" ;;
    prune)            cmd_prune "$@" ;;
    prune-predicate)  prune_predicate "$@" ;;
    pull-is-benign-miss) _bp_pull_is_benign_miss "$(cat)" ;;
    *)                usage; exit 2 ;;
esac
