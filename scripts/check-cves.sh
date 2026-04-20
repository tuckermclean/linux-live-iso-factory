#!/bin/bash
#
# check-cves.sh — Grype CVE scan wrapper for The Monolith attestation pipeline.
#
# Runs Grype against an enriched CycloneDX SBOM and produces:
#   - A JSON report (output path)
#   - A human-readable per-package summary to stdout
#   - A list of packages with no CPE (cannot be scanned)
#
# Usage:
#   check-cves.sh --sbom PATH --output PATH [--help]
#
# Exit codes:
#   0  no CVEs found
#   1  CVEs found or grype error

set -euo pipefail

SBOM=""
OUTPUT=""

usage() {
    cat <<EOF
Usage: $(basename "$0") --sbom PATH --output PATH

Options:
  --sbom PATH      Path to the enriched CycloneDX JSON SBOM
  --output PATH    Path to write the Grype JSON report
  --help           Show this help

Exit codes:
  0  no CVEs found
  1  CVEs found or grype error
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sbom)    SBOM="$2"; shift 2 ;;
        --output)  OUTPUT="$2"; shift 2 ;;
        --help)    usage; exit 0 ;;
        *) echo "[check-cves] ERROR: unknown argument: $1" >&2; usage; exit 1 ;;
    esac
done

if [[ -z "$SBOM" || -z "$OUTPUT" ]]; then
    echo "[check-cves] ERROR: --sbom and --output are required" >&2
    usage
    exit 1
fi

if [[ ! -f "$SBOM" ]]; then
    echo "[check-cves] ERROR: SBOM not found: $SBOM" >&2
    exit 1
fi

if ! command -v grype >/dev/null 2>&1; then
    echo "[check-cves] ERROR: grype not found in PATH" >&2
    echo "  Install from: https://github.com/anchore/grype" >&2
    exit 1
fi

mkdir -p "$(dirname "$OUTPUT")"

# Report packages with no CPE (cannot be scanned by Grype)
echo ""
echo "[check-cves] Checking for packages with no CPE mapping (unscanned)..."
python3 - "$SBOM" <<'PYEOF'
import json, sys

try:
    sbom = json.load(open(sys.argv[1]))
except Exception as e:
    print(f"[check-cves] WARNING: could not parse SBOM for pre-check: {e}", file=sys.stderr)
    sys.exit(0)

no_cpe = [
    (c.get("name", "?"), c.get("version", ""))
    for c in sbom.get("components", [])
    if c.get("type") != "file" and not c.get("cpe")
]

if no_cpe:
    print(f"[check-cves] UNSCANNED — no CPE mapping ({len(no_cpe)} packages):")
    for name, ver in sorted(no_cpe):
        ver_str = f" ({ver})" if ver else ""
        print(f"  - {name}{ver_str}")
    print("[check-cves] These packages cannot be matched against CVE databases.")
else:
    print("[check-cves] All packages have CPE mappings — full coverage.")
PYEOF

# Run Grype
echo ""
echo "[check-cves] Running Grype against SBOM..."
GRYPE_RC=0
grype "sbom:${SBOM}" -o cyclonedx-json --file "${OUTPUT}" 2>&1 || GRYPE_RC=$?

if [[ $GRYPE_RC -ne 0 ]]; then
    echo "[check-cves] ERROR: grype exited with code $GRYPE_RC" >&2
    echo "[check-cves] Check grype DB status with: grype db status" >&2
    exit "$GRYPE_RC"
fi

# Parse and summarize results (CycloneDX VEX format)
python3 - "$OUTPUT" <<'PYEOF'
import json, sys

try:
    report = json.load(open(sys.argv[1]))
except Exception as e:
    print(f"[check-cves] ERROR: could not parse grype output: {e}", file=sys.stderr)
    sys.exit(1)

vulns = report.get("vulnerabilities") or []

if not vulns:
    print("[check-cves] \033[0;32mPASS\033[0m: No CVEs found.")
    sys.exit(0)

total_affects = sum(len(v.get("affects") or []) for v in vulns)
print(f"\n[check-cves] \033[0;31mFAIL\033[0m: {len(vulns)} CVE(s) found "
      f"affecting {total_affects} component reference(s):\n")
for v in sorted(vulns, key=lambda x: x.get("id", "")):
    ratings = v.get("ratings") or [{}]
    sev = ratings[0].get("severity", "Unknown")
    n = len(v.get("affects") or [])
    print(f"  {v.get('id','?')} ({sev}) — {n} component(s)")

sys.exit(1)
PYEOF
