#!/bin/bash
#
# attestation.sh — Four-pillar attestation pipeline for The Monolith ISO.
#
# Pillar 1: SBOM generation (Syft) + CPE enrichment (enrich-sbom.py)
# Pillar 2: License compliance (check-licenses.py)
# Pillar 3: CVE scanning (Grype via check-cves.sh)
# Pillar 4: Unowned files audit (check-unowned.py)
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
#   --help               Show this help
#
# Output files (in output-dir):
#   sbom.cdx.json              Raw Syft SBOM (CycloneDX — for pillars 2 and 3)
#   sbom.syft.json             Raw Syft SBOM (native JSON — for pillar 4)
#   sbom-enriched.cdx.json     SBOM with CPE overrides applied
#   license-report.json        License compliance report
#   cve-report.json            Grype CVE findings
#   unowned-report.json        Files not owned by any Portage package
#   cpe-gap-count.txt          Number of packages with no CPE
#   attestation-summary.json   Machine-readable summary of all pillar results
#
# Exit codes:
#   0   all pillars pass
#   1   one or more pillars fail (but all artifacts are always written)

set -uo pipefail

# ── Argument defaults ────────────────────────────────────────────────────────
SYSROOT=""
ISO=""
BUILD_TAG=""
OUTPUT_DIR=""
OVERRIDES_FILE="/configs/attestation/cpe-overrides.yaml"
POLICY_FILE="/configs/attestation/license-policy.yaml"
UNOWNED_ALLOWLIST_FILE="/configs/attestation/unowned-allowlist.yaml"

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

for script in "$ENRICH_SCRIPT" "$LICENSE_SCRIPT" "$CVE_SCRIPT" "$UNOWNED_SCRIPT"; do
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
SBOM_FILE="${OUTPUT_DIR}/sbom.cdx.json"
SYFT_JSON_FILE="${OUTPUT_DIR}/sbom.syft.json"
ENRICHED_FILE="${OUTPUT_DIR}/sbom-enriched.cdx.json"

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
# file.metadata.selection=all: enable file cataloger so files[] is populated.
syft "dir:${SYSROOT}" \
    --override-default-catalogers portage-cataloger \
    -c 'file.metadata.selection=all' \
    -o "cyclonedx-json=${SBOM_FILE}" \
    -o "json=${SYFT_JSON_FILE}" \
    2>&1 || SBOM_RC=$?

if [[ $SBOM_RC -eq 0 ]]; then
    PKG_COUNT=$(python3 -c "import json; d=json.load(open('${SBOM_FILE}')); print(len(d.get('components', [])))" 2>/dev/null || echo 0)
    log "Syft found ${PKG_COUNT} packages in sysroot."
else
    fail "Syft exited with code $SBOM_RC"
    PKG_COUNT=0
fi

# ── Pillar 1b: CPE enrichment ────────────────────────────────────────────────
log "--- Pillar 1: CPE Enrichment (enrich-sbom.py) ---"
# Use raw SBOM as input; update SBOM_FILE to enriched on success
if [[ $SBOM_RC -eq 0 ]]; then
    python3 "${ENRICH_SCRIPT}" \
        --sbom "${SBOM_FILE}" \
        --overrides "${OVERRIDES_FILE}" \
        --output "${ENRICHED_FILE}" || ENRICH_RC=$?

    if [[ $ENRICH_RC -eq 0 ]]; then
        SBOM_FILE="$ENRICHED_FILE"
        log "CPE enrichment complete. Using enriched SBOM for pillars 2 and 3."
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
    --output "${OUTPUT_DIR}/cve-report.json" || CVE_RC=$?

# Collect CVE failures for summary
CVE_FAILURES="[]"
if [[ -f "${OUTPUT_DIR}/cve-report.json" ]]; then
    CVE_FAILURES=$(python3 -c "
import json, sys
from collections import defaultdict
try:
    r = json.load(open('${OUTPUT_DIR}/cve-report.json'))
    matches = r.get('matches') or []
    by_pkg = defaultdict(list)
    for m in matches:
        art = m.get('artifact', {})
        name = art.get('name', '?')
        ver = art.get('version', '?')
        cve = m.get('vulnerability', {}).get('id', '?')
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

# ── Determine overall status ─────────────────────────────────────────────────
OVERALL_SBOM_STATUS="pass"
OVERALL_LICENSE_STATUS="pass"
OVERALL_CVE_STATUS="pass"
OVERALL_UNOWNED_STATUS="pass"
OVERALL_STATUS="pass"

[[ $SBOM_RC -ne 0 ]]    && OVERALL_SBOM_STATUS="fail"    && OVERALL_STATUS="fail"
[[ $LICENSE_RC -ne 0 ]] && OVERALL_LICENSE_STATUS="fail" && OVERALL_STATUS="fail"
[[ $CVE_RC -ne 0 ]]     && OVERALL_CVE_STATUS="fail"     && OVERALL_STATUS="fail"
[[ $UNOWNED_RC -ne 0 ]] && OVERALL_UNOWNED_STATUS="fail" && OVERALL_STATUS="fail"

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
    "overall": "${OVERALL_STATUS}",
    "cve_failures": ${CVE_FAILURES},
    "license_failures": ${LICENSE_FAILURES},
    "unowned_files": ${UNOWNED_FILES},
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
echo ""
printf "  %-28s %s\n" "Packages scanned:" "${PKG_COUNT}"
printf "  %-28s %s\n" "Unmapped CPEs (unscanned):" "${UNMAPPED_CPE_COUNT}"
printf "  %-28s %s\n" "Unowned files:" "${UNOWNED_COUNT}"
printf "  %-28s %s\n" "ISO SHA-256:" "${ISO_SHA256}"
echo ""

if [[ "$OVERALL_STATUS" = "pass" ]]; then
    echo -e "  ${GREEN}${BOLD}OVERALL: PASS — all attestation gates cleared.${NC}"
else
    echo -e "  ${RED}${BOLD}OVERALL: FAIL — see details above.${NC}"
    # Print specific failures
    python3 - <<PYEOF
import json

lf = ${LICENSE_FAILURES}
cf = ${CVE_FAILURES}
uf = ${UNOWNED_FILES}
if lf:
    print("\n  License failures:")
    for f in lf: print(f"    {f}")
if cf:
    print("\n  CVE failures:")
    for f in cf: print(f"    {f}")
if uf:
    print("\n  Unowned files (not in allowlist):")
    for f in uf: print(f"    {f}")
PYEOF
fi

echo ""
log "Artifacts in: ${OUTPUT_DIR}"

# ── Exit with overall status ─────────────────────────────────────────────────
if [[ "$OVERALL_STATUS" = "fail" ]]; then
    exit 1
fi
exit 0
