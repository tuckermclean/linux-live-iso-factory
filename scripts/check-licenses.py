#!/usr/bin/env python3
"""
check-licenses.py — License policy enforcement for The Monolith ISO.

Reads the enriched CycloneDX SBOM produced by enrich-sbom.py and validates
each package's license against the allowlist in config/license-policy.yaml.

Supports Portage compound license expressions:
  "MIT"                    — single license
  "MIT BSD-2-Clause"       — conjunctive: ALL must be allowed
  "|| ( MIT GPL-2.0+ )"   — disjunctive: at least ONE must be allowed
  "MIT || ( ISC BSD )"     — mixed: evaluated as DNF

Portage license names are mapped to SPDX identifiers via the gentoo_to_spdx
table in license-policy.yaml before checking.

Unknown licenses (no license field in SBOM) are NOT treated as failures —
they appear as "unknown" in the report. Only explicit license violations fail.

Exit codes:
  0  all licenses pass (or unknown)
  1  one or more licenses fail policy
"""

import argparse
import hashlib
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path


def load_yaml_simple(path: str) -> dict:
    try:
        import yaml
    except ImportError:
        print(
            "[check-licenses] ERROR: pyyaml is not installed.\n"
            "  Install with: pip3 install pyyaml",
            file=sys.stderr,
        )
        sys.exit(1)
    with open(path) as f:
        return yaml.safe_load(f) or {}


def load_policy(path: str) -> dict:
    """Load license-policy.yaml. Returns dict with policy keys."""
    data = load_yaml_simple(path)
    return {
        "allowed_spdx": set(data.get("allowed_spdx", [])),
        "gentoo_to_spdx": data.get("gentoo_to_spdx", {}),
        "denied_spdx": set(data.get("denied_spdx", [])),
    }


def normalize(raw: str, gentoo_map: dict) -> str:
    """Apply gentoo_to_spdx mapping. Returns SPDX identifier or original."""
    return gentoo_map.get(raw, raw)


def parse_portage_expr(expr: str) -> list:
    """
    Parse a Portage LICENSE expression into a list of alternative license sets.

    Returns a list of lists. A package passes if ANY inner list has ALL its
    licenses allowed (disjunctive normal form).

    Portage grammar (relevant subset):
      expr     := term+
      term     := '||' '(' expr ')'    -- disjunctive group
               |  identifier           -- single license (conjunctive with siblings)

    Examples:
      "MIT"                     → [["MIT"]]
      "MIT BSD-2-Clause"        → [["MIT", "BSD-2-Clause"]]
      "|| ( MIT GPL-2+ )"       → [["MIT"], ["GPL-2+"]]
      "MIT || ( ISC BSD )"      → [["MIT", "ISC"], ["MIT", "BSD"]]

    Malformed / unknown: treat entire string as one license.
    """
    expr = expr.strip()
    if not expr:
        return [[]]

    tokens = re.findall(r"\|\||[()]|[^\s()|]+", expr)
    if not tokens:
        return [[expr]]

    try:
        result = _parse_alternatives(tokens, 0)
        alternatives, _ = result
        return alternatives if alternatives else [[expr]]
    except Exception:
        return [[expr]]


def _parse_alternatives(tokens: list, pos: int) -> tuple:
    """
    Recursive descent parser.  Returns (alternatives, new_pos).

    alternatives: list of conjunctions (list of str).
    Each conjunction represents one way to satisfy the expression.

    For a conjunctive sequence  [A, B, C]:
        alternatives = [["A","B","C"]]

    For a disjunctive group || ( A B ):
        Each item becomes its own alternative:
        alternatives = [["A"], ["B"]]

    For mixed  A || ( B C ) D:
        Conjunctive prefix [A], then disjunctive group expands into
        [["A","B"], ["A","C"]], then append D to each:
        [["A","B","D"], ["A","C","D"]]
    """
    # Start with one empty conjunction (the "current" running conjunction)
    current_conjunctions = [[]]  # list of running conjunctions
    completed_alternatives = []  # alternatives finished by OR operators

    while pos < len(tokens):
        tok = tokens[pos]

        if tok == ")":
            break  # end of group — caller will consume ")"

        if tok == "||":
            pos += 1  # consume "||"
            if pos >= len(tokens) or tokens[pos] != "(":
                break  # malformed; stop
            pos += 1  # consume "("
            inner_alts, pos = _parse_alternatives(tokens, pos)
            if pos < len(tokens) and tokens[pos] == ")":
                pos += 1  # consume ")"

            # Cross-product: each current conjunction × each inner alternative
            new_conjunctions = []
            for cur in current_conjunctions:
                for inner in (inner_alts if inner_alts else [[]]):
                    new_conjunctions.append(cur + inner)
            current_conjunctions = new_conjunctions

        elif tok == "(":
            pos += 1  # consume "("
            inner_alts, pos = _parse_alternatives(tokens, pos)
            if pos < len(tokens) and tokens[pos] == ")":
                pos += 1  # consume ")"
            # Bare group — treat as conjunctive (flatten all inner licenses)
            inner_flat = [lic for alt in inner_alts for lic in alt]
            current_conjunctions = [cur + inner_flat for cur in current_conjunctions]

        elif tok == "AND":
            # SPDX conjunctive operator — same semantics as a space; skip it
            pos += 1

        elif tok == "OR":
            # SPDX disjunctive operator — flush current conjunctions as completed
            # alternatives and start a fresh conjunction set
            completed_alternatives.extend(current_conjunctions)
            current_conjunctions = [[]]
            pos += 1

        else:
            # Plain license identifier — conjunctive with everything so far
            current_conjunctions = [cur + [tok] for cur in current_conjunctions]
            pos += 1

    return completed_alternatives + current_conjunctions, pos


def extract_license_string(component: dict):
    """
    Extract the raw license string from a CycloneDX component.

    CycloneDX license field variants:
      [{"license": {"id": "MIT"}}]
      [{"license": {"name": "MIT"}}]
      [{"expression": "MIT OR Apache-2.0"}]

    Returns a single string for use by parse_portage_expr, or None if absent.
    """
    licenses = component.get("licenses")
    if not licenses:
        return None

    parts = []
    for entry in licenses:
        if "expression" in entry:
            parts.append(entry["expression"])
        elif "license" in entry:
            lic = entry["license"]
            val = lic.get("id") or lic.get("name")
            if val:
                parts.append(val)

    return " ".join(parts) if parts else None


def is_conjunction_allowed(conjunction: list, allowed: set, denied: set, gentoo_map: dict) -> tuple:
    """
    Check if all licenses in a conjunction are allowed.

    Returns (allowed: bool, failing_licenses: list).
    """
    failing = []
    for raw in conjunction:
        spdx = normalize(raw, gentoo_map)
        if spdx in denied:
            failing.append(f"{raw} (DENIED)")
        elif spdx not in allowed:
            failing.append(raw)
    return (len(failing) == 0, failing)


def check_component(component: dict, policy: dict) -> dict:
    """
    Check one CycloneDX component against the license policy.

    Returns a result dict with keys: name, version, raw_license, normalized,
    status ("pass"/"fail"/"unknown"), reason.
    """
    name = component.get("name", "unknown")
    version = component.get("version", "")
    raw = extract_license_string(component)

    if raw is None:
        return {
            "name": name,
            "version": version,
            "raw_license": None,
            "normalized": [],
            "status": "unknown",
            "reason": "no license information in SBOM",
        }

    conjunctions = parse_portage_expr(raw)
    allowed = policy["allowed_spdx"]
    denied = policy["denied_spdx"]
    gentoo_map = policy["gentoo_to_spdx"]

    # Normalize all licenses for reporting
    all_licenses = sorted({normalize(lic, gentoo_map) for conj in conjunctions for lic in conj})

    # A package passes if ANY conjunction is fully allowed
    for conjunction in conjunctions:
        ok, _ = is_conjunction_allowed(conjunction, allowed, denied, gentoo_map)
        if ok:
            return {
                "name": name,
                "version": version,
                "raw_license": raw,
                "normalized": all_licenses,
                "status": "pass",
                "reason": f"license satisfied by: {' '.join(conjunction)}",
            }

    # All conjunctions failed — collect the best failure reason
    _, failing = is_conjunction_allowed(conjunctions[0], allowed, denied, gentoo_map)
    return {
        "name": name,
        "version": version,
        "raw_license": raw,
        "normalized": all_licenses,
        "status": "fail",
        "reason": f"not in allowlist: {', '.join(failing)}",
    }


def main():
    parser = argparse.ArgumentParser(
        description="Check package licenses in a CycloneDX SBOM against policy.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s --sbom attestation/bom.cdx.json \\
           --policy config/license-policy.yaml \\
           --output attestation/license-report.json

Exit codes:
  0  all licenses pass (unknowns are not failures)
  1  one or more licenses fail policy
        """,
    )
    parser.add_argument("--sbom", required=True, metavar="PATH", help="CycloneDX JSON SBOM")
    parser.add_argument("--policy", required=True, metavar="PATH", help="license-policy.yaml")
    parser.add_argument("--output", required=True, metavar="PATH", help="JSON report output path")
    args = parser.parse_args()

    sbom_path = Path(args.sbom)
    if not sbom_path.exists():
        print(f"[check-licenses] ERROR: SBOM not found: {args.sbom}", file=sys.stderr)
        sys.exit(1)

    policy_path = Path(args.policy)
    if not policy_path.exists():
        print(f"[check-licenses] ERROR: Policy file not found: {args.policy}", file=sys.stderr)
        sys.exit(1)

    with open(sbom_path) as f:
        sbom = json.load(f)

    policy = load_policy(args.policy)
    # Skip file-cataloger entries (type: "file") — these are individual filesystem
    # files that Syft emits when file.metadata.selection=all is enabled. They have
    # no license fields and are not packages; license checking them is meaningless.
    components = [c for c in sbom.get("components", []) if c.get("type") != "file"]
    # Include the top-level product component (metadata.component) — it has a declared
    # license (MIT) and should appear in the report rather than being silently omitted.
    # Deduplicate by name first: Syft sometimes emits a bare OS distro component with
    # the same name into components[] before enrich-sbom.py cleans it up.
    meta_comp = sbom.get("metadata", {}).get("component")
    if meta_comp and meta_comp.get("type") != "file":
        meta_name = meta_comp.get("name", "")
        if meta_name:
            components = [c for c in components if c.get("name") != meta_name]
        components = [meta_comp] + components

    results = [check_component(c, policy) for c in components]

    n_pass = sum(1 for r in results if r["status"] == "pass")
    n_fail = sum(1 for r in results if r["status"] == "fail")
    n_unknown = sum(1 for r in results if r["status"] == "unknown")

    policy_sha256 = hashlib.sha256(Path(args.policy).read_bytes()).hexdigest()

    report = {
        "build_tag": sbom.get("metadata", {}).get("component", {}).get("version", "unknown"),
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "sbom_path": args.sbom,
        "policy_path": args.policy,
        "policy_sha256": policy_sha256,
        "summary": {
            "total": len(results),
            "pass": n_pass,
            "fail": n_fail,
            "unknown": n_unknown,
        },
        "components": results,
    }

    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with open(out_path, "w") as f:
        json.dump(report, f, indent=2)
        f.write("\n")

    # Print summary to stdout
    status_icon = "PASS" if n_fail == 0 else "FAIL"
    color = "\033[0;32m" if n_fail == 0 else "\033[0;31m"
    reset = "\033[0m"
    print(f"\n[check-licenses] {color}{status_icon}{reset}: {len(results)} packages checked — "
          f"{n_pass} pass, {n_fail} fail, {n_unknown} unknown")

    if n_fail > 0:
        print("[check-licenses] Failing packages:")
        for r in results:
            if r["status"] == "fail":
                print(f"  FAIL  {r['name']} ({r['version']}): {r['reason']}")

    print(f"[check-licenses] Report written to {args.output}")
    sys.exit(1 if n_fail > 0 else 0)


if __name__ == "__main__":
    main()
