#!/bin/bash
#
# attestation.sh — Five-pillar attestation pipeline for The Monolith ISO.
#
# Pillar 1: SBOM generation (Syft) + CPE enrichment (enrich-sbom.py)
# Pillar 2: License compliance (check-licenses.py)
# Pillar 3: CVE scanning (Grype via check-cves.sh)
# Pillar 4: Unowned files audit (check-unowned.py)
# Pillar 5: Builder environment SBOM + CVE scan (--include-builder only)
#
# IMPORTANT: All pillars always run to completion regardless of
# earlier failures. You want every red light visible at once.
#
# Usage:
#   attestation.sh --sysroot PATH --iso PATH --build-tag TAG [options]
#
# Options:
#   --sysroot PATH       Path to the extracted sysroot (must contain /var/db/pkg)
#   --iso PATH           Path to the ISO file (for SHA-256; may not exist yet)
#   --build-tag TAG      Build version string (e.g. "20260405" or "1.2.3")
#   --output-dir PATH    Directory for attestation artifacts [default: <iso-dir>/attestation]
#   --overrides PATH     CPE overrides YAML [default: /configs/attestation/cpe-overrides.yaml]
#   --policy PATH        License policy YAML [default: /configs/attestation/license-policy.yaml]
#   --unowned-allowlist PATH
#                        Unowned files allowlist YAML [default: /configs/attestation/unowned-allowlist.yaml]
#   --include-builder    Also attest to the builder image itself (Pillar 5): scans the
#                        running container's filesystem (dir:/) with Syft + Grype,
#                        excluding bind-mounted volumes that are not part of the image.
#                        Captures full provenance: BUILD_EPOCH, CROSS_TARGET, image
#                        digest, toolchain package inventory, and CVE scan results.
#   --builder-digest ID  Docker image digest or ID to record in the summary
#                        (pass via: docker inspect --format='{{.Id}}' monolith-builder)
#   --help               Show this help
#
# Output files (in output-dir):
#   sbom.cdx.json              Raw Syft SBOM (CycloneDX — for pillars 2 and 3)
#   sbom.syft.json             Raw Syft SBOM (native JSON — for pillar 4)
#   bom.cdx.json               SBOM with CPE overrides applied
#   license-report.json        License compliance report
#   cve-report.cdx.json        Grype CVE findings (CycloneDX VEX BOM)
#   unowned-report.json        Files not owned by any Portage package
#   cpe-gap-count.txt          Number of packages with no CPE
#   builder-sbom.cdx.json      Builder image SBOM (Pillar 5, if --include-builder)
#   builder-bom.cdx.json       Builder SBOM with CPE overrides (Pillar 5)
#   builder-cve-report.cdx.json Builder Grype CVE findings (CycloneDX VEX BOM, Pillar 5)
#   builder-cpe-gap-count.txt  Builder packages with no CPE (Pillar 5)
#   attestation-summary.json   Machine-readable summary of all pillar results
#
# Exit codes:
#   0   all pillars pass
#   1   one or more pillars fail (but all artifacts are always written)

set -uo pipefail

# Record the attestation start time before any work begins.
# Passed to generate-provenance.py as startedOn; finishedOn is recorded
# just before the provenance call so the two timestamps bracket all pillars.
BUILD_STARTED_ON="${BUILD_STARTED_ON:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

# ── Argument defaults ────────────────────────────────────────────────────────
SYSROOT=""
ISO=""
BUILD_TAG=""
OUTPUT_DIR=""
OVERRIDES_FILE="/configs/attestation/cpe-overrides.yaml"
POLICY_FILE="/configs/attestation/license-policy.yaml"
UNOWNED_ALLOWLIST_FILE="/configs/attestation/unowned-allowlist.yaml"
INCLUDE_BUILDER=0
BUILDER_DIGEST=""

# ── ANSI colors ──────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${BOLD}[attestation]${NC} $*"; }
pass() { echo -e "${GREEN}[PASS]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

usage() {
    cat <<EOF
Usage: $(basename "$0") --sysroot PATH --iso PATH --build-tag TAG [options]

Required:
  --sysroot PATH       Extracted sysroot containing /var/db/pkg
  --iso PATH           ISO file path (for SHA-256; may be absent)
  --build-tag TAG      Build version string

Optional:
  --output-dir PATH    Attestation artifact directory
                       [default: <iso-parent>/attestation or /output/attestation]
  --overrides PATH     CPE overrides YAML [default: /configs/attestation/cpe-overrides.yaml]
                       Fallback: config/cpe-overrides.yaml (relative to cwd)
  --policy PATH        License policy YAML [default: /configs/attestation/license-policy.yaml]
                       Fallback: config/license-policy.yaml (relative to cwd)
  --include-builder    Pillar 5: attest the builder image (SBOM + CVE scan of dir:/)
  --builder-digest ID  Docker image digest to record (from: docker inspect --format='{{.Id}}' monolith-builder)
  --help               Show this help
EOF
}

# ── Parse arguments ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --sysroot)      SYSROOT="$2";      shift 2 ;;
        --iso)          ISO="$2";          shift 2 ;;
        --build-tag)    BUILD_TAG="$2";    shift 2 ;;
        --output-dir)   OUTPUT_DIR="$2";   shift 2 ;;
        --overrides)          OVERRIDES_FILE="$2";         shift 2 ;;
        --policy)             POLICY_FILE="$2";            shift 2 ;;
        --unowned-allowlist)  UNOWNED_ALLOWLIST_FILE="$2"; shift 2 ;;
        --include-builder)    INCLUDE_BUILDER=1;           shift ;;
        --builder-digest)     BUILDER_DIGEST="$2";         shift 2 ;;
        --help)         usage; exit 0 ;;
        *) echo "[attestation] ERROR: unknown argument: $1" >&2; usage; exit 1 ;;
    esac
done

# ── Validate required args ───────────────────────────────────────────────────
MISSING=0
[[ -z "$SYSROOT"   ]] && { echo "[attestation] ERROR: --sysroot is required" >&2; MISSING=1; }
[[ -z "$BUILD_TAG" ]] && { echo "[attestation] ERROR: --build-tag is required" >&2; MISSING=1; }
[[ $MISSING -eq 1  ]] && { usage; exit 1; }

if [[ -n "$SYSROOT" && ! -d "$SYSROOT" ]]; then
    echo "[attestation] ERROR: sysroot directory not found: $SYSROOT" >&2
    exit 1
fi

# ── Resolve output directory ─────────────────────────────────────────────────
if [[ -z "$OUTPUT_DIR" ]]; then
    if [[ -n "$ISO" ]]; then
        OUTPUT_DIR="$(dirname "$ISO")/attestation"
    else
        OUTPUT_DIR="/output/attestation"
    fi
fi
mkdir -p "$OUTPUT_DIR"

# ── Resolve config file paths (fallback to relative paths) ───────────────────
# Allow relative config/ paths when running from project root
if [[ ! -f "$OVERRIDES_FILE" && -f "config/cpe-overrides.yaml" ]]; then
    OVERRIDES_FILE="config/cpe-overrides.yaml"
fi
if [[ ! -f "$POLICY_FILE" && -f "config/license-policy.yaml" ]]; then
    POLICY_FILE="config/license-policy.yaml"
fi
if [[ ! -f "$UNOWNED_ALLOWLIST_FILE" && -f "config/unowned-allowlist.yaml" ]]; then
    UNOWNED_ALLOWLIST_FILE="config/unowned-allowlist.yaml"
fi

# ── Validate tools ───────────────────────────────────────────────────────────
TOOLS_OK=1
for tool in syft grype python3; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "[attestation] ERROR: $tool not found in PATH" >&2
        TOOLS_OK=0
    fi
done
[[ $TOOLS_OK -eq 0 ]] && exit 1

# ── Locate Python scripts (relative to this script or project root) ──────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENRICH_SCRIPT="${SCRIPT_DIR}/enrich-sbom.py"
LICENSE_SCRIPT="${SCRIPT_DIR}/check-licenses.py"
CVE_SCRIPT="${SCRIPT_DIR}/check-cves.sh"
UNOWNED_SCRIPT="${SCRIPT_DIR}/check-unowned.py"
PROVENANCE_SCRIPT="${SCRIPT_DIR}/generate-provenance.py"

for script in "$ENRICH_SCRIPT" "$LICENSE_SCRIPT" "$CVE_SCRIPT" "$UNOWNED_SCRIPT" "$PROVENANCE_SCRIPT"; do
    if [[ ! -f "$script" ]]; then
        echo "[attestation] ERROR: required script not found: $script" >&2
        exit 1
    fi
done

# ── ISO SHA-256 ──────────────────────────────────────────────────────────────
ISO_SHA256="(not computed)"
if [[ -n "$ISO" && -f "$ISO" ]]; then
    ISO_SHA256="$(sha256sum "$ISO" | cut -d' ' -f1)"
    log "ISO SHA-256: $ISO_SHA256"
elif [[ -n "$ISO" ]]; then
    warn "ISO not found at $ISO — SHA-256 skipped"
fi

# ── Pillar result tracking ────────────────────────────────────────────────────
SBOM_RC=0
ENRICH_RC=0
LICENSE_RC=0
CVE_RC=0
UNOWNED_RC=0
BUILDER_SBOM_RC=0
BUILDER_CVE_RC=0
PROVENANCE_RC=0
SBOM_FILE="${OUTPUT_DIR}/sbom.cdx.json"
SYFT_JSON_FILE="${OUTPUT_DIR}/sbom.syft.json"
ENRICHED_FILE="${OUTPUT_DIR}/bom.cdx.json"

# ── Header ───────────────────────────────────────────────────────────────────
log "========================================================"
log "  Attestation Pipeline — Build: ${BUILD_TAG}"
log "========================================================"
log "  Sysroot:    ${SYSROOT}"
log "  Output:     ${OUTPUT_DIR}"
log "  Overrides:  ${OVERRIDES_FILE}"
log "  Policy:     ${POLICY_FILE}"
echo ""

# ── Pillar 1a: Syft SBOM generation ─────────────────────────────────────────
log "--- Pillar 1: SBOM Generation (Syft) ---"
# Run Syft with dual output:
#   cyclonedx-json  — package SBOM for pillars 2 (license) and 3 (CVE).
#                     CycloneDX only includes package-level artifacts; the file
#                     cataloger's entries stay in the native JSON, so this output
#                     is unaffected by enabling file.metadata.selection=all.
#   json            — Syft native JSON for pillar 4 (unowned files).
#                     Contains artifacts[].metadata.Files[] (CONTENTS-owned paths)
#                     and files[] (all paths found on disk). Diff = unowned files.
#
# SYFT_FILE_METADATA_SELECTION=all: enable file cataloger so files[] is populated.
# (-c takes a config file path, not inline key=value; use env var instead)
SYFT_FILE_METADATA_SELECTION=all syft "dir:${SYSROOT}" \
    --override-default-catalogers portage-cataloger \
    -o "cyclonedx-json=${SBOM_FILE}" \
    -o "json=${SYFT_JSON_FILE}" \
    2>&1 || SBOM_RC=$?

if [[ $SBOM_RC -eq 0 ]]; then
    PKG_COUNT=$(python3 -c "import json; d=json.load(open('${SBOM_FILE}')); print(sum(1 for c in d.get('components',[]) if c.get('type')!='file'))" 2>/dev/null || echo 0)
    log "Syft found ${PKG_COUNT} packages in sysroot."
else
    fail "Syft exited with code $SBOM_RC"
    PKG_COUNT=0
fi

# ── Pillar 1b: CPE enrichment ────────────────────────────────────────────────
log "--- Pillar 1: CPE Enrichment (enrich-sbom.py) ---"

# Capture scanner tool versions before enrichment so they can be embedded in
# metadata.tools of the SBOM (canonical home per CycloneDX spec).
SYFT_VERSION=$(syft version --output json 2>/dev/null \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('version',''))" 2>/dev/null \
    || syft version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "")
GRYPE_VERSION=$(grype version --output json 2>/dev/null \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('version',''))" 2>/dev/null \
    || grype version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "")
_GRYPE_DB_STATUS=$(grype db status 2>/dev/null || echo "")
GRYPE_DB_BUILT=$(echo "$_GRYPE_DB_STATUS" \
    | python3 -c "import sys,re; m=re.search(r'Built:\s+(.+)',sys.stdin.read()); print(m.group(1).strip() if m else '')" 2>/dev/null || echo "")
GRYPE_DB_SCHEMA=$(echo "$_GRYPE_DB_STATUS" \
    | python3 -c "import sys,re; m=re.search(r'Version:\s+(\S+)',sys.stdin.read()); print(m.group(1) if m else '')" 2>/dev/null || echo "")
GRYPE_DB_CHECKSUM=$(echo "$_GRYPE_DB_STATUS" \
    | python3 -c "import sys,re; m=re.search(r'Checksum:\s+(\S+)',sys.stdin.read()); print(m.group(1) if m else '')" 2>/dev/null || echo "")

# Use raw SBOM as input; update SBOM_FILE to enriched on success
if [[ $SBOM_RC -eq 0 ]]; then
    python3 "${ENRICH_SCRIPT}" \
        --sbom "${SBOM_FILE}" \
        --overrides "${OVERRIDES_FILE}" \
        --output "${ENRICHED_FILE}" \
        --product-name "themonolith" \
        --build-tag "${BUILD_TAG}" \
        --git-sha "${GITHUB_SHA:-}" \
        --repo-url "${GITHUB_SERVER_URL:-}/${GITHUB_REPOSITORY:-}" \
        --arch "${CROSS_TARGET:-}" \
        --sysroot "${SYSROOT}" \
        --license-policy "${POLICY_FILE}" \
        --iso-sha256 "${ISO_SHA256}" \
        ${SYFT_VERSION:+--syft-version "${SYFT_VERSION}"} \
        ${GRYPE_VERSION:+--grype-version "${GRYPE_VERSION}"} \
        ${GRYPE_DB_BUILT:+--grype-db-built "${GRYPE_DB_BUILT}"} \
        ${GRYPE_DB_SCHEMA:+--grype-db-schema "${GRYPE_DB_SCHEMA}"} \
        ${GRYPE_DB_CHECKSUM:+--grype-db-checksum "${GRYPE_DB_CHECKSUM}"} \
        || ENRICH_RC=$?

    if [[ $ENRICH_RC -eq 0 ]]; then
        SBOM_FILE="$ENRICHED_FILE"
        log "CPE enrichment complete. Using enriched SBOM for pillars 2 and 3."

        # Extract the upstream kernel version for resolvedDependencies in Pillar 6.
        # The monolith-kernel component's version field holds the upstream version
        # (Gentoo revision stripped by enrich-sbom.py before CPE substitution).
        KERNEL_VERSION=$(python3 -c "
import json, sys
try:
    d = json.load(open('${ENRICHED_FILE}'))
    k = next((c for c in d.get('components', [])
               if 'monolith-kernel' in c.get('name', '')), {})
    print(k.get('version', ''))
except Exception:
    pass
" 2>/dev/null || echo "")
    else
        fail "CPE enrichment exited with code $ENRICH_RC — using raw SBOM for pillars 2 and 3"
        SBOM_RC=$ENRICH_RC  # Roll enrichment failure into SBOM pillar result
    fi
else
    warn "Skipping CPE enrichment (Syft failed)"
fi

# Read CPE gap count (written by enrich-sbom.py)
UNMAPPED_CPE_COUNT=0
if [[ -f "${OUTPUT_DIR}/cpe-gap-count.txt" ]]; then
    UNMAPPED_CPE_COUNT="$(cat "${OUTPUT_DIR}/cpe-gap-count.txt" | tr -d '[:space:]')"
fi

# ── Pillar 2: License compliance ─────────────────────────────────────────────
log "--- Pillar 2: License Compliance ---"
python3 "${LICENSE_SCRIPT}" \
    --sbom "${SBOM_FILE}" \
    --policy "${POLICY_FILE}" \
    --output "${OUTPUT_DIR}/license-report.json" || LICENSE_RC=$?

# Collect license failures for summary
LICENSE_FAILURES="[]"
if [[ -f "${OUTPUT_DIR}/license-report.json" ]]; then
    LICENSE_FAILURES=$(python3 -c "
import json, sys
r = json.load(open('${OUTPUT_DIR}/license-report.json'))
fails = [f\"{c['name']} ({c['version']}): {c['reason']}\"
         for c in r.get('components', []) if c.get('status') == 'fail']
print(json.dumps(fails))
" 2>/dev/null || echo "[]")
fi

# ── Pillar 3: CVE check ──────────────────────────────────────────────────────
log "--- Pillar 3: CVE Check (Grype) ---"
bash "${CVE_SCRIPT}" \
    --sbom "${SBOM_FILE}" \
    --output "${OUTPUT_DIR}/cve-report.cdx.json" || CVE_RC=$?

# Collect CVE failures for summary (CycloneDX VEX — join to SBOM for package names)
CVE_FAILURES="[]"
if [[ -f "${OUTPUT_DIR}/cve-report.cdx.json" ]]; then
    CVE_FAILURES=$(python3 -c "
import json
from collections import defaultdict
try:
    r = json.load(open('${OUTPUT_DIR}/cve-report.cdx.json'))
    vulns = r.get('vulnerabilities') or []
    try:
        bom = json.load(open('${OUTPUT_DIR}/bom.cdx.json'))
        comp_by_ref = {c.get('bom-ref',''): c for c in bom.get('components',[])}
    except Exception:
        comp_by_ref = {}
    by_pkg = defaultdict(list)
    for v in vulns:
        cve = v.get('id', '?')
        for aff in (v.get('affects') or []):
            ref  = aff.get('ref', '') if isinstance(aff, dict) else str(aff)
            comp = comp_by_ref.get(ref, {})
            name = comp.get('name', ref)
            ver  = comp.get('version', '?')
            by_pkg[f'{name}-{ver}'].append(cve)
    fails = [f\"{pkg}: {', '.join(cves)}\" for pkg, cves in sorted(by_pkg.items())]
    print(json.dumps(fails))
except Exception:
    print('[]')
" 2>/dev/null || echo "[]")
fi

# ── Pillar 4: Unowned files audit ────────────────────────────────────────────
log "--- Pillar 4: Unowned Files Audit (check-unowned.py) ---"
if [[ -f "${SYFT_JSON_FILE}" ]]; then
    UNOWNED_ARGS=(
        --syft-json "${SYFT_JSON_FILE}"
        --sysroot   "${SYSROOT}"
        --output    "${OUTPUT_DIR}/unowned-report.json"
    )
    [[ -f "${UNOWNED_ALLOWLIST_FILE}" ]] && UNOWNED_ARGS+=(--allowlist "${UNOWNED_ALLOWLIST_FILE}")
    python3 "${UNOWNED_SCRIPT}" "${UNOWNED_ARGS[@]}" || UNOWNED_RC=$?
else
    warn "Syft native JSON not found at ${SYFT_JSON_FILE} — skipping unowned files check"
fi

UNOWNED_COUNT=0
UNOWNED_FILES="[]"
if [[ -f "${OUTPUT_DIR}/unowned-report.json" ]]; then
    UNOWNED_COUNT=$(python3 -c "
import json
print(json.load(open('${OUTPUT_DIR}/unowned-report.json')).get('summary', {}).get('unowned', 0))
" 2>/dev/null || echo 0)
    UNOWNED_FILES=$(python3 -c "
import json
print(json.dumps(json.load(open('${OUTPUT_DIR}/unowned-report.json')).get('unowned_files', [])))
" 2>/dev/null || echo "[]")
fi

# ── Pillar 5: Builder environment SBOM + CVE ─────────────────────────────────
BUILDER_PKG_COUNT=0
BUILDER_UNMAPPED_CPE_COUNT=0
BUILDER_CVE_FAILURES="[]"
BUILDER_SBOM_FILE="${OUTPUT_DIR}/builder-sbom.cdx.json"
BUILDER_ENRICHED_FILE="${OUTPUT_DIR}/builder-bom.cdx.json"

# Collect builder metadata from the environment (set by Dockerfile/docker run)
BUILDER_EPOCH="${BUILD_EPOCH:-unknown}"
BUILDER_CROSS_TARGET="${CROSS_TARGET:-unknown}"

if [[ $INCLUDE_BUILDER -eq 1 ]]; then
    log "--- Pillar 5: Builder Environment SBOM (Syft on dir:/) ---"
    log "  BUILD_EPOCH:   ${BUILDER_EPOCH}"
    log "  CROSS_TARGET:  ${BUILDER_CROSS_TARGET}"
    [[ -n "$BUILDER_DIGEST" ]] && log "  Image digest:  ${BUILDER_DIGEST}"

    # Scan the builder image's own filesystem via dir:/, excluding all bind/volume
    # mounts that are overlaid at runtime and are NOT part of the image itself.
    # The portage-cataloger reads /var/db/pkg, which lives in the image layer.
    SYFT_FILE_METADATA_SELECTION=all syft dir:/ \
        --exclude '/output/**' \
        --exclude '/configs/**' \
        --exclude '/scripts/**' \
        --exclude '/rootfs/**' \
        --exclude '/build/**' \
        --exclude '/var/db/repos/**' \
        --exclude '/var/cache/distfiles/**' \
        --exclude '/var/log/portage/**' \
        --exclude '/root/.cache/**' \
        --override-default-catalogers portage-cataloger \
        -o "cyclonedx-json=${BUILDER_SBOM_FILE}" \
        2>&1 || BUILDER_SBOM_RC=$?

    if [[ $BUILDER_SBOM_RC -eq 0 ]]; then
        BUILDER_PKG_COUNT=$(python3 -c "
import json
d = json.load(open('${BUILDER_SBOM_FILE}'))
print(sum(1 for c in d.get('components', []) if c.get('type') != 'file'))
" 2>/dev/null || echo 0)
        log "Syft found ${BUILDER_PKG_COUNT} packages in builder environment."

        # Enrich builder SBOM with the same CPE overrides (Portage packages — same dictionary)
        log "--- Pillar 5: Builder CPE Enrichment ---"
        python3 "${ENRICH_SCRIPT}" \
            --sbom      "${BUILDER_SBOM_FILE}" \
            --overrides "${OVERRIDES_FILE}" \
            --output    "${BUILDER_ENRICHED_FILE}" \
            --product-name "themonolith-builder" \
            --build-tag "${BUILD_TAG}" \
            --git-sha   "${GITHUB_SHA:-}" \
            --repo-url  "${GITHUB_SERVER_URL:-}/${GITHUB_REPOSITORY:-}" \
            --license-policy "${POLICY_FILE}" \
            || BUILDER_SBOM_RC=$?

        if [[ $BUILDER_SBOM_RC -eq 0 ]]; then
            BUILDER_SBOM_FILE="${BUILDER_ENRICHED_FILE}"

            BUILDER_UNMAPPED_CPE_COUNT=0
            if [[ -f "${OUTPUT_DIR}/builder-cpe-gap-count.txt" ]]; then
                BUILDER_UNMAPPED_CPE_COUNT="$(cat "${OUTPUT_DIR}/builder-cpe-gap-count.txt" | tr -d '[:space:]')"
            fi

            # Move the gap file produced by enrich-sbom.py to its builder-specific name
            [[ -f "${OUTPUT_DIR}/cpe-gap-count.txt" ]] && \
                mv "${OUTPUT_DIR}/cpe-gap-count.txt" "${OUTPUT_DIR}/builder-cpe-gap-count.txt"
        else
            fail "Builder CPE enrichment failed (code $BUILDER_SBOM_RC) — using raw builder SBOM"
            BUILDER_SBOM_FILE="${OUTPUT_DIR}/builder-sbom.cdx.json"
        fi

        # CVE scan the builder
        log "--- Pillar 5: Builder CVE Check (Grype) ---"
        bash "${CVE_SCRIPT}" \
            --sbom    "${BUILDER_SBOM_FILE}" \
            --output  "${OUTPUT_DIR}/builder-cve-report.cdx.json" || BUILDER_CVE_RC=$?

        if [[ -f "${OUTPUT_DIR}/builder-cve-report.cdx.json" ]]; then
            BUILDER_CVE_FAILURES=$(python3 -c "
import json
from collections import defaultdict
try:
    r = json.load(open('${OUTPUT_DIR}/builder-cve-report.cdx.json'))
    vulns = r.get('vulnerabilities') or []
    try:
        bom = json.load(open('${OUTPUT_DIR}/builder-bom.cdx.json'))
        comp_by_ref = {c.get('bom-ref',''): c for c in bom.get('components',[])}
    except Exception:
        comp_by_ref = {}
    by_pkg = defaultdict(list)
    for v in vulns:
        cve = v.get('id', '?')
        for aff in (v.get('affects') or []):
            ref  = aff.get('ref', '') if isinstance(aff, dict) else str(aff)
            comp = comp_by_ref.get(ref, {})
            name = comp.get('name', ref)
            ver  = comp.get('version', '?')
            by_pkg[f'{name}-{ver}'].append(cve)
    fails = [f\"{pkg}: {', '.join(cves)}\" for pkg, cves in sorted(by_pkg.items())]
    print(json.dumps(fails))
except Exception:
    print('[]')
" 2>/dev/null || echo "[]")
        fi
    else
        fail "Builder SBOM generation failed (code $BUILDER_SBOM_RC)"
    fi
fi

# ── Pillar 6: SLSA v1.0 Provenance ───────────────────────────────────────────
log "--- Pillar 6: SLSA v1.0 Provenance ---"
if [[ -n "$ISO_SHA256" && "$ISO_SHA256" != "(not computed)" ]]; then
    BUILD_FINISHED_ON="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    BUILD_EPOCH_VAL="${BUILD_EPOCH:-}"

    # Portage snapshot digest — Gentoo publishes a .sha256 sidecar alongside each snapshot.
    PORTAGE_SNAPSHOT_SHA256=$(curl -fsSL \
        "https://distfiles.gentoo.org/snapshots/gentoo-${BUILD_EPOCH_VAL}.tar.xz.sha256" \
        2>/dev/null | awk '{print $1}' || echo "")

    # Kernel source digest — SHA-512 is already in the Portage Manifest (GPG-signed).
    KERNEL_SHA512=$(python3 -c "
import re
try:
    txt = open('/configs/overlay/sys-kernel/monolith-kernel/Manifest').read()
    m = re.search(r'DIST linux-\S+\.tar\.xz \d+ BLAKE2B \S+ SHA512 (\S+)', txt)
    print(m.group(1) if m else '')
except Exception:
    pass
" 2>/dev/null || echo "")

    PROVENANCE_ARGS=(
        --iso-sha256       "${ISO_SHA256}"
        --iso-name         "themonolith-${BUILD_TAG}.iso"
        --build-tag        "${BUILD_TAG}"
        --output           "${OUTPUT_DIR}/slsa-provenance.json"
        --build-started-on  "${BUILD_STARTED_ON}"
        --build-finished-on "${BUILD_FINISHED_ON}"
    )
    [[ -n "$BUILD_EPOCH_VAL"    ]] && PROVENANCE_ARGS+=(
        --portage-snapshot-epoch "${BUILD_EPOCH_VAL}"
        --stage3-epoch           "${BUILD_EPOCH_VAL}"
    )
    [[ -n "${PORTAGE_SNAPSHOT_SHA256}" ]] && PROVENANCE_ARGS+=(--portage-snapshot-sha256 "${PORTAGE_SNAPSHOT_SHA256}")
    [[ -n "${STAGE3_DIGEST:-}"         ]] && PROVENANCE_ARGS+=(--stage3-digest "${STAGE3_DIGEST}")
    [[ -n "${KERNEL_VERSION:-}"        ]] && PROVENANCE_ARGS+=(--kernel-version "${KERNEL_VERSION}")
    [[ -n "${KERNEL_SHA512}"           ]] && PROVENANCE_ARGS+=(--kernel-sha512 "${KERNEL_SHA512}")
    [[ -n "$BUILDER_DIGEST"            ]] && PROVENANCE_ARGS+=(--builder-digest "${BUILDER_DIGEST}")
    python3 "${PROVENANCE_SCRIPT}" "${PROVENANCE_ARGS[@]}" 2>&1 || PROVENANCE_RC=$?
else
    fail "ISO SHA-256 not computed — cannot generate provenance with valid subject"
    PROVENANCE_RC=1
fi

# ── Determine overall status ─────────────────────────────────────────────────
OVERALL_SBOM_STATUS="pass"
OVERALL_LICENSE_STATUS="pass"
OVERALL_CVE_STATUS="pass"
OVERALL_UNOWNED_STATUS="pass"
OVERALL_PROVENANCE_STATUS="pass"
OVERALL_BUILDER_SBOM_STATUS="not_run"
OVERALL_BUILDER_CVE_STATUS="not_run"
OVERALL_STATUS="pass"

[[ $SBOM_RC -ne 0 ]]       && OVERALL_SBOM_STATUS="fail"       && OVERALL_STATUS="fail"
[[ $LICENSE_RC -ne 0 ]]    && OVERALL_LICENSE_STATUS="fail"    && OVERALL_STATUS="fail"
[[ $CVE_RC -ne 0 ]]        && OVERALL_CVE_STATUS="fail"        && OVERALL_STATUS="fail"
[[ $UNOWNED_RC -ne 0 ]]    && OVERALL_UNOWNED_STATUS="fail"    && OVERALL_STATUS="fail"
[[ $PROVENANCE_RC -ne 0 ]] && OVERALL_PROVENANCE_STATUS="fail" && OVERALL_STATUS="fail"

if [[ $INCLUDE_BUILDER -eq 1 ]]; then
    OVERALL_BUILDER_SBOM_STATUS="pass"
    OVERALL_BUILDER_CVE_STATUS="pass"
    [[ $BUILDER_SBOM_RC -ne 0 ]] && OVERALL_BUILDER_SBOM_STATUS="fail" && OVERALL_STATUS="fail"
    [[ $BUILDER_CVE_RC -ne 0 ]]  && OVERALL_BUILDER_CVE_STATUS="fail"  && OVERALL_STATUS="fail"
fi

# ── Write attestation-summary.json ───────────────────────────────────────────
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
SUMMARY_FILE="${OUTPUT_DIR}/attestation-summary.json"

python3 - <<PYEOF
import json
from pathlib import Path

summary = {
    "build_tag": "${BUILD_TAG}",
    "timestamp": "${TIMESTAMP}",
    "iso_sha256": "${ISO_SHA256}",
    "package_count": ${PKG_COUNT},
    "unmapped_cpe_count": ${UNMAPPED_CPE_COUNT},
    "sbom_check": "${OVERALL_SBOM_STATUS}",
    "license_check": "${OVERALL_LICENSE_STATUS}",
    "cve_check": "${OVERALL_CVE_STATUS}",
    "unowned_check": "${OVERALL_UNOWNED_STATUS}",
    "unowned_count": ${UNOWNED_COUNT},
    "provenance_check": "${OVERALL_PROVENANCE_STATUS}",
    "overall": "${OVERALL_STATUS}",
    "cve_failures": ${CVE_FAILURES},
    "license_failures": ${LICENSE_FAILURES},
    "unowned_files": ${UNOWNED_FILES},
    "builder": {
        "attested": ${INCLUDE_BUILDER},
        "epoch": "${BUILDER_EPOCH}",
        "cross_target": "${BUILDER_CROSS_TARGET}",
        "image_digest": "${BUILDER_DIGEST}",
        "package_count": ${BUILDER_PKG_COUNT},
        "unmapped_cpe_count": ${BUILDER_UNMAPPED_CPE_COUNT},
        "sbom_check": "${OVERALL_BUILDER_SBOM_STATUS}",
        "cve_check": "${OVERALL_BUILDER_CVE_STATUS}",
        "cve_failures": ${BUILDER_CVE_FAILURES},
    },
}

out = Path("${SUMMARY_FILE}")
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(json.dumps(summary, indent=2) + "\n")
print(f"[attestation] Summary written to ${SUMMARY_FILE}")
PYEOF

# ── Print human-readable terminal summary ────────────────────────────────────
echo ""
log "========================================================"
log "  Attestation Summary — Build: ${BUILD_TAG}"
log "========================================================"
echo ""
printf "  %-28s %s\n" "SBOM / CPE Enrichment:" \
    "$([ "$OVERALL_SBOM_STATUS" = "pass" ] && echo -e "${GREEN}PASS${NC}" || echo -e "${RED}FAIL${NC}")"
printf "  %-28s %s\n" "License Compliance:" \
    "$([ "$OVERALL_LICENSE_STATUS" = "pass" ] && echo -e "${GREEN}PASS${NC}" || echo -e "${RED}FAIL${NC}")"
printf "  %-28s %s\n" "CVE Check (Grype):" \
    "$([ "$OVERALL_CVE_STATUS" = "pass" ] && echo -e "${GREEN}PASS${NC}" || echo -e "${RED}FAIL${NC}")"
printf "  %-28s %s\n" "Unowned Files:" \
    "$([ "$OVERALL_UNOWNED_STATUS" = "pass" ] && echo -e "${GREEN}PASS${NC}" || echo -e "${RED}FAIL${NC}")"
printf "  %-28s %s\n" "SLSA Provenance:" \
    "$([ "$OVERALL_PROVENANCE_STATUS" = "pass" ] && echo -e "${GREEN}PASS${NC}" || echo -e "${RED}FAIL${NC}")"
if [[ $INCLUDE_BUILDER -eq 1 ]]; then
    printf "  %-28s %s\n" "Builder SBOM:" \
        "$([ "$OVERALL_BUILDER_SBOM_STATUS" = "pass" ] && echo -e "${GREEN}PASS${NC}" || echo -e "${RED}FAIL${NC}")"
    printf "  %-28s %s\n" "Builder CVE Check:" \
        "$([ "$OVERALL_BUILDER_CVE_STATUS" = "pass" ] && echo -e "${GREEN}PASS${NC}" || echo -e "${RED}FAIL${NC}")"
fi
echo ""
printf "  %-28s %s\n" "Packages scanned:" "${PKG_COUNT}"
printf "  %-28s %s\n" "Unmapped CPEs (unscanned):" "${UNMAPPED_CPE_COUNT}"
printf "  %-28s %s\n" "Unowned files:" "${UNOWNED_COUNT}"
if [[ $INCLUDE_BUILDER -eq 1 ]]; then
    printf "  %-28s %s\n" "Builder packages:" "${BUILDER_PKG_COUNT}"
    printf "  %-28s %s\n" "Builder unmapped CPEs:" "${BUILDER_UNMAPPED_CPE_COUNT}"
    printf "  %-28s %s\n" "Builder epoch:" "${BUILDER_EPOCH}"
    printf "  %-28s %s\n" "Builder cross target:" "${BUILDER_CROSS_TARGET}"
    [[ -n "$BUILDER_DIGEST" ]] && \
        printf "  %-28s %s\n" "Builder image digest:" "${BUILDER_DIGEST}"
fi
printf "  %-28s %s\n" "ISO SHA-256:" "${ISO_SHA256}"
echo ""

if [[ "$OVERALL_STATUS" = "pass" ]]; then
    echo -e "  ${GREEN}${BOLD}OVERALL: PASS — all attestation gates cleared.${NC}"
else
    echo -e "  ${RED}${BOLD}OVERALL: FAIL — see details above.${NC}"
    # Print specific failures
    python3 - <<PYEOF
import json

lf  = ${LICENSE_FAILURES}
cf  = ${CVE_FAILURES}
uf  = ${UNOWNED_FILES}
bcf = ${BUILDER_CVE_FAILURES}
if lf:
    print("\n  License failures:")
    for f in lf: print(f"    {f}")
if cf:
    print("\n  CVE failures (sysroot):")
    for f in cf: print(f"    {f}")
if uf:
    print("\n  Unowned files (not in allowlist):")
    for f in uf: print(f"    {f}")
if bcf:
    print("\n  CVE failures (builder):")
    for f in bcf: print(f"    {f}")
PYEOF
fi

echo ""
log "Artifacts in: ${OUTPUT_DIR}"

# ── Exit with overall status ─────────────────────────────────────────────────
if [[ "$OVERALL_STATUS" = "fail" ]]; then
    exit 1
fi
exit 0
