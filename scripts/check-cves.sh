#!/bin/bash
#
# check-cves.sh — Grype CVE scan wrapper for The Monolith attestation pipeline.
#
# Runs Grype against an enriched CycloneDX SBOM and produces:
#   - cve-report.cdx.json     Raw Grype CycloneDX VEX report (dashboard-compatible,
#                              unchanged format — this is what the SPA fetches directly)
#   - *.grype.json             Raw Grype native JSON report (richer per-finding data:
#                              severity, fix.state, fix.versions — used to build coverage)
#   - *-coverage.json           Machine-readable scan coverage + policy verdict:
#                              scanner name/version, vuln DB build timestamp/schema/
#                              checksum, policy path + SHA-256, scanned/matched/clean/
#                              unscanned component counts, and the full finding list
#                              (including WAIVED ones — nothing is dropped from this
#                              file just because policy doesn't gate on it)
#
# This script never reports "clean" for a component it never actually evaluated.
# Components with no CPE mapping are always reported as UNSCANNED, distinct from
# "scanned and found zero vulnerabilities."
#
# Usage:
#   check-cves.sh --sbom PATH --output PATH [--policy PATH] [--native-output PATH]
#                 [--coverage-output PATH] [--help]
#
# Exit codes:
#   0  scan completed; no gating findings under policy
#   1  scan completed; one or more gating findings under policy (or grype/tool error)
#
# See docs/cve-gate.md for why this script exists in its current form — it replaces
# a version that reported "PASS: no CVEs found" with no scanner metadata, no DB
# timestamp, and no way to tell an honest zero from a matcher that never had a
# chance to find anything.

set -uo pipefail

SBOM=""
OUTPUT=""
POLICY=""
NATIVE_OUTPUT=""
COVERAGE_OUTPUT=""

usage() {
    cat <<EOF
Usage: $(basename "$0") --sbom PATH --output PATH [options]

Options:
  --sbom PATH             Path to the enriched CycloneDX JSON SBOM
  --output PATH           Path to write the Grype CycloneDX JSON report
  --policy PATH           Path to cve-policy.yaml
                          [default: /configs/attestation/cve-policy.yaml,
                           fallback: configs/attestation/cve-policy.yaml relative to cwd]
  --native-output PATH    Path to write Grype's native JSON report
                          [default: <output-without-.cdx.json-suffix>.grype.json]
  --coverage-output PATH  Path to write the coverage + policy verdict report
                          [default: <output-without-.cdx.json-suffix>-coverage.json]
  --help                  Show this help

Exit codes:
  0  no gating CVEs found under policy
  1  gating CVEs found under policy, or a tool/DB error occurred
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sbom)             SBOM="$2";             shift 2 ;;
        --output)           OUTPUT="$2";           shift 2 ;;
        --policy)           POLICY="$2";           shift 2 ;;
        --native-output)    NATIVE_OUTPUT="$2";    shift 2 ;;
        --coverage-output)  COVERAGE_OUTPUT="$2";  shift 2 ;;
        --help)             usage; exit 0 ;;
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

# ── Resolve derived output paths ─────────────────────────────────────────────
# Strip a trailing ".cdx.json" (falling back to any extension) so
# "cve-report.cdx.json" → "cve-report" and "builder-cve-report.cdx.json" →
# "builder-cve-report" — this is how Pillar 5 (builder) gets distinctly named
# coverage/native files without attestation.sh having to rename anything.
OUTPUT_BASE="${OUTPUT%.cdx.json}"
[[ "$OUTPUT_BASE" == "$OUTPUT" ]] && OUTPUT_BASE="${OUTPUT%.*}"
[[ -z "$NATIVE_OUTPUT"   ]] && NATIVE_OUTPUT="${OUTPUT_BASE}.grype.json"
[[ -z "$COVERAGE_OUTPUT" ]] && COVERAGE_OUTPUT="${OUTPUT_BASE}-coverage.json"

# ── Resolve policy path (same fallback convention as attestation.sh) ─────────
if [[ -z "$POLICY" ]]; then
    POLICY="/configs/attestation/cve-policy.yaml"
fi
if [[ ! -f "$POLICY" && -f "configs/attestation/cve-policy.yaml" ]]; then
    POLICY="configs/attestation/cve-policy.yaml"
fi
POLICY_MISSING=0
if [[ ! -f "$POLICY" ]]; then
    echo "[check-cves] WARNING: policy file not found at $POLICY — falling back to a" >&2
    echo "  built-in default (gate on Critical/High/Unknown, no allowlist). This is a" >&2
    echo "  misconfiguration: fix the --policy path so the gate is auditable." >&2
    POLICY_MISSING=1
fi

# ── Grype vulnerability DB status — always captured, never assumed fresh ─────
# check-cves.sh does not itself run `grype db update`; that happens once
# upstream (see Makefile target grype-db-update / build.yml step "Update Grype
# DB") so a single CI run doesn't re-download the DB per pillar. What this
# script guarantees is that it NEVER reports a verdict without also recording
# exactly which DB build produced it, so a stale/failed-to-update DB is
# visible on the dashboard instead of silently producing a "clean" result.
echo ""
echo "[check-cves] Grype vulnerability DB status:"
GRYPE_DB_STATUS="$(grype db status 2>&1 || true)"
echo "$GRYPE_DB_STATUS" | sed 's/^/  /'

# ── Report packages with no CPE (cannot be scanned by Grype) ─────────────────
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
    print("[check-cves] All packages have CPE mappings — full candidate coverage.")
PYEOF

# ── Run Grype: two single-format invocations (see docs/cve-gate.md) ──────────
# We deliberately run grype twice rather than passing two `-o fmt=path` flags
# in one invocation. Grype's multi-output syntax is version-sensitive and this
# script has to work across whatever grype version `install.sh` pulls as
# "latest" at image-build time; two --file invocations only ever rely on the
# single-output form that has been stable across grype releases. The DB is
# loaded from local cache both times, so the extra cost is one more match pass,
# not one more DB download.
echo ""
echo "[check-cves] Running Grype against SBOM (native JSON: fix-state + full severity)..."
GRYPE_RC=0
grype "sbom:${SBOM}" -o json --file "${NATIVE_OUTPUT}" 2>&1 || GRYPE_RC=$?
if [[ $GRYPE_RC -ne 0 ]]; then
    echo "[check-cves] ERROR: grype (native JSON pass) exited with code $GRYPE_RC" >&2
    echo "[check-cves] Check grype DB status with: grype db status" >&2
    exit "$GRYPE_RC"
fi

echo "[check-cves] Running Grype against SBOM (CycloneDX VEX: dashboard-compatible)..."
grype "sbom:${SBOM}" -o cyclonedx-json --file "${OUTPUT}" 2>&1 || GRYPE_RC=$?
if [[ $GRYPE_RC -ne 0 ]]; then
    echo "[check-cves] ERROR: grype (cyclonedx-json pass) exited with code $GRYPE_RC" >&2
    echo "[check-cves] Check grype DB status with: grype db status" >&2
    exit "$GRYPE_RC"
fi

GRYPE_VERSION="$(grype version --output json 2>/dev/null \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('version',''))" 2>/dev/null \
    || grype version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "")"

# ── Coverage + policy evaluation ──────────────────────────────────────────────
python3 - "$SBOM" "$NATIVE_OUTPUT" "$OUTPUT" "$POLICY" "$POLICY_MISSING" \
         "$COVERAGE_OUTPUT" "$GRYPE_VERSION" "$GRYPE_DB_STATUS" <<'PYEOF'
import hashlib
import json
import re
import sys
from datetime import datetime, timezone

(sbom_path, native_path, cdx_path, policy_path, policy_missing_flag,
 coverage_path, grype_version, grype_db_status) = sys.argv[1:9]
policy_missing = policy_missing_flag == "1"

RED, GREEN, YELLOW, BOLD, NC = (
    "\033[0;31m", "\033[0;32m", "\033[1;33m", "\033[1m", "\033[0m",
)

# ── Load SBOM: total components, CPE-scanned vs unscanned ────────────────────
try:
    sbom = json.load(open(sbom_path))
except Exception as e:
    print(f"[check-cves] ERROR: could not parse SBOM: {e}", file=sys.stderr)
    sys.exit(1)

pkg_components = [c for c in sbom.get("components", []) if c.get("type") != "file"]
scanned_components = [c for c in pkg_components if c.get("cpe")]
unscanned_components = [
    {"name": c.get("name", "?"), "version": c.get("version", "")}
    for c in pkg_components if not c.get("cpe")
]

# ── Load Grype native JSON (richer per-match data) ────────────────────────────
try:
    native = json.load(open(native_path))
except Exception as e:
    print(f"[check-cves] ERROR: could not parse grype native output: {e}", file=sys.stderr)
    sys.exit(1)

matches = native.get("matches") or []

# ── Load policy ────────────────────────────────────────────────────────────
DEFAULT_POLICY = {
    "gating_severities": ["Critical", "High", "Unknown"],
    "informational_severities": ["Medium", "Low", "Negligible"],
    "fail_on_unscanned": False,
    "allowlist": [],
}
policy = dict(DEFAULT_POLICY)
policy_sha256 = ""
if not policy_missing:
    try:
        import yaml
        with open(policy_path) as f:
            loaded = yaml.safe_load(f) or {}
        policy.update({k: v for k, v in loaded.items() if v is not None})
        policy_sha256 = hashlib.sha256(open(policy_path, "rb").read()).hexdigest()
    except ImportError:
        print("[check-cves] ERROR: pyyaml is not installed — cannot load policy", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"[check-cves] WARNING: could not parse policy {policy_path}: {e} — using built-in default", file=sys.stderr)
        policy = dict(DEFAULT_POLICY)

gating_severities = {s.lower() for s in policy.get("gating_severities", [])}
allowlist = policy.get("allowlist") or []

def waiver_for(cve_id: str, component: str):
    for entry in allowlist:
        if entry.get("cve", "").upper() != cve_id.upper():
            continue
        comp = entry.get("component")
        if comp and comp != component:
            continue
        return entry
    return None

# ── Parse grype DB status (Built / Version / Checksum) ───────────────────────
def _grab(label_re, text):
    m = re.search(label_re, text)
    return m.group(1).strip() if m else ""

db_built = _grab(r"Built:\s+(.+)", grype_db_status)
db_schema = _grab(r"Version:\s+(\S+)", grype_db_status)
db_checksum = _grab(r"Checksum:\s+(\S+)", grype_db_status)
db_status_line = _grab(r"Status:\s+(\S+)", grype_db_status)

db_age_days = None
db_age_warning = ""
if db_built:
    parsed = None
    for fmt in ("%Y-%m-%d %H:%M:%S %z", "%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%d"):
        try:
            parsed = datetime.strptime(db_built.split(" +")[0].split(" -")[0].strip() if fmt == "%Y-%m-%d" else db_built, fmt)
            break
        except ValueError:
            continue
    if parsed:
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        db_age_days = (datetime.now(timezone.utc) - parsed).total_seconds() / 86400.0
        if db_age_days > 3:
            db_age_warning = (
                f"Grype vulnerability DB was built {db_age_days:.1f} days ago. "
                "`grype db update` should run immediately before every scan (see "
                "Makefile target grype-db-update / build.yml step 'Update Grype DB'); "
                "a DB this old means either that step failed silently or didn't run."
            )
else:
    db_age_warning = (
        "Could not parse a DB build timestamp from `grype db status` output — "
        "the DB status format may have changed, or the DB has never been built. "
        "Treat any 'no findings' result from this run with suspicion until this "
        "is fixed."
    )

# ── Build per-finding records ─────────────────────────────────────────────────
findings = []
matched_component_keys = set()
for m in matches:
    vuln = m.get("vulnerability") or {}
    artifact = m.get("artifact") or {}
    cve_id = vuln.get("id", "?")
    severity = (vuln.get("severity") or "Unknown").strip() or "Unknown"
    comp_name = artifact.get("name", "?")
    comp_version = artifact.get("version", "")
    matched_component_keys.add((comp_name, comp_version))

    fix = vuln.get("fix") or {}
    waiver = waiver_for(cve_id, comp_name)
    gating = (severity.lower() in gating_severities) and waiver is None

    findings.append({
        "cve": cve_id,
        "severity": severity,
        "component": comp_name,
        "version": comp_version,
        "cpe": artifact.get("cpes", [None])[0] if artifact.get("cpes") else None,
        "fix_state": fix.get("state", "unknown"),
        "fix_versions": fix.get("versions", []),
        "gating": gating,
        "waived": waiver is not None,
        "waiver_justification": (waiver or {}).get("justification"),
        "waiver_approved_by": (waiver or {}).get("approved_by"),
        "waiver_expires": (waiver or {}).get("expires"),
        "url": (vuln.get("dataSource") or f"https://nvd.nist.gov/vuln/detail/{cve_id}"),
    })

findings.sort(key=lambda f: (not f["gating"], f["cve"]))

scanned_count = len(scanned_components)
unscanned_count = len(unscanned_components)
matched_count = len({k for k in matched_component_keys})
clean_count = max(scanned_count - matched_count, 0)
gating_findings = [f for f in findings if f["gating"]]
waived_findings = [f for f in findings if f["waived"]]

verdict = "pass"
reasons = []
if gating_findings:
    verdict = "fail"
    reasons.append(f"{len(gating_findings)} gating finding(s) (severity in {sorted(policy.get('gating_severities', []))})")
if policy.get("fail_on_unscanned") and unscanned_count:
    verdict = "fail"
    reasons.append(f"{unscanned_count} unscanned component(s) and fail_on_unscanned=true")

coverage = {
    "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "sbom_path": sbom_path,
    "cve_report_path": cdx_path,
    "native_report_path": native_path,
    "scanner": {"name": "grype", "version": grype_version or "unknown"},
    "db": {
        "built": db_built or None,
        "schema_version": db_schema or None,
        "checksum": db_checksum or None,
        "status": db_status_line or None,
        "age_days": round(db_age_days, 2) if db_age_days is not None else None,
        "age_warning": db_age_warning or None,
    },
    "policy": {
        "path": policy_path,
        "sha256": policy_sha256 or None,
        "loaded": not policy_missing,
        "gating_severities": policy.get("gating_severities", []),
        "informational_severities": policy.get("informational_severities", []),
        "fail_on_unscanned": policy.get("fail_on_unscanned", False),
        "allowlist_size": len(allowlist),
    },
    "coverage": {
        "total_components": len(pkg_components),
        "scanned": scanned_count,
        "unscanned": unscanned_count,
        "matched": matched_count,
        "clean": clean_count,
    },
    "unscanned_components": sorted(unscanned_components, key=lambda c: c["name"]),
    "findings": findings,
    "summary": {
        "total_findings": len(findings),
        "gating_findings": len(gating_findings),
        "waived_findings": len(waived_findings),
    },
    "verdict": verdict,
    "verdict_reasons": reasons,
}

with open(coverage_path, "w") as f:
    json.dump(coverage, f, indent=2)
    f.write("\n")

# ── Human-readable summary ────────────────────────────────────────────────────
print("")
print(f"[check-cves] Scanner: grype {grype_version or 'unknown'}   "
      f"DB built: {db_built or 'UNKNOWN'}   DB schema: {db_schema or 'UNKNOWN'}")
if db_age_warning:
    print(f"[check-cves] {YELLOW}WARNING{NC}: {db_age_warning}")
print(f"[check-cves] Policy: {policy_path}"
      f"{' (' + policy_sha256[:12] + '…)' if policy_sha256 else ' — NOT LOADED, using built-in default'}")
print(f"[check-cves] Coverage: {scanned_count} scanned (candidate for matching), "
      f"{matched_count} matched (>=1 finding), {clean_count} clean (scanned, zero findings), "
      f"{unscanned_count} UNSCANNED (no CPE mapping — never evaluated)")

if findings:
    print(f"\n[check-cves] {len(findings)} total finding(s) "
          f"({len(gating_findings)} gating, {len(waived_findings)} waived):\n")
    for f in findings:
        tag = "GATING" if f["gating"] else ("WAIVED" if f["waived"] else "info")
        print(f"  {f['cve']} ({f['severity']}, fix={f['fix_state']}) — "
              f"{f['component']}@{f['version'] or '?'}  [{tag}]")
else:
    print("\n[check-cves] Grype returned zero matches across "
          f"{scanned_count} scanned component(s).")

print("")
if verdict == "pass":
    print(f"[check-cves] {GREEN}PASS{NC}: no gating findings under policy {policy_path}.")
    if unscanned_count:
        print(f"[check-cves] {YELLOW}NOTE{NC}: {unscanned_count} component(s) were never evaluated "
              "(no CPE) — this PASS covers only the scanned set. See cve-coverage.json.")
else:
    print(f"[check-cves] {RED}FAIL{NC}: " + "; ".join(reasons))

print(f"[check-cves] Coverage report: {coverage_path}")

sys.exit(0 if verdict == "pass" else 1)
PYEOF
