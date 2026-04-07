#!/usr/bin/env python3
"""
enrich-sbom.py — CPE enrichment for Syft CycloneDX SBOM output.

Reads a CycloneDX JSON SBOM (as produced by Syft from a Portage sysroot),
applies CPE overrides from a YAML config file, and writes an enriched SBOM.

Usage:
    enrich-sbom.py --sbom PATH --overrides PATH --output PATH

The overrides file (config/cpe-overrides.yaml) is an EXCEPTION LIST — only
packages where Syft's automatic CPE detection is wrong or absent. Packages
that Syft handles correctly should NOT appear in the overrides file.

After enrichment, reports to stderr any packages that still have no CPE
(neither Syft nor the overrides file provided one). These are attestation
gaps — Grype cannot scan them for CVEs.

Exit code: always 0. Gaps are informational, not failures.
"""

import argparse
import json
import re
import sys
from pathlib import Path


def load_yaml_simple(path: str) -> dict:
    """Load YAML using pyyaml with a helpful error if not installed."""
    try:
        import yaml
    except ImportError:
        print(
            "[enrich-sbom] ERROR: pyyaml is not installed.\n"
            "  Install with: pip3 install pyyaml\n"
            "  Or inside the Docker image: emerge dev-python/pyyaml",
            file=sys.stderr,
        )
        sys.exit(1)
    with open(path) as f:
        return yaml.safe_load(f) or {}


def load_overrides(path: str) -> dict:
    """Load cpe-overrides.yaml and return dict of bare_name → cpe_template."""
    data = load_yaml_simple(path)
    return data.get("overrides", {})


def bare_name(component_name: str) -> str:
    """
    Normalize a Portage component name to a bare package name for matching.

    Syft may produce names in several forms:
      "bash"                        → "bash"
      "app-shells/bash"             → "bash"
      "app-shells/bash-5.2_p21"     → "bash"  (strip version suffix)
    """
    name = component_name
    # Strip category prefix (e.g. "app-shells/")
    if "/" in name:
        name = name.split("/", 1)[1]
    # Strip version suffix: Portage versions start with a digit after "-"
    # e.g. "bash-5.2_p21" → "bash", "monolith-kernel-6.12.80" → "monolith-kernel"
    # Use a conservative regex: strip trailing "-<digit>..." segment
    name = re.sub(r"-\d.*$", "", name)
    return name.lower()


def apply_version_to_cpe(template: str, version: str) -> str:
    """
    Substitute the actual package version into a CPE 2.3 template string.

    CPE 2.3 format: cpe:2.3:<type>:<vendor>:<product>:<version>:<rest...>
    The version is field index 5 (0-indexed) when splitting on ':'.
    Templates in cpe-overrides.yaml use '*' as the version placeholder.

    Example:
      template = "cpe:2.3:a:haxx:curl:*:*:*:*:*:*:*:*"
      version  = "8.5.0"
      result   = "cpe:2.3:a:haxx:curl:8.5.0:*:*:*:*:*:*:*"
    """
    parts = template.split(":")
    if len(parts) >= 6 and parts[5] == "*":
        # Sanitize version: CPE doesn't allow spaces; replace _ with . (Portage convention)
        safe_version = version.replace("_", ".").replace(" ", "")
        parts[5] = safe_version
    return ":".join(parts)


def enrich(sbom: dict, overrides: dict) -> tuple:
    """
    Apply CPE overrides to SBOM components.

    Returns:
        (enriched_sbom, enriched_names, no_cpe_names)
        - enriched_sbom:  the full SBOM dict with CPEs updated
        - enriched_names: list of component names that received an override
        - no_cpe_names:   list of (name, version) tuples with no CPE after enrichment
    """
    enriched_names = []
    no_cpe_names = []

    # Skip type: "file" components — these are individual filesystem files from
    # the file cataloger, not packages. Only packages can have CPEs or be scanned.
    components = [c for c in sbom.get("components", []) if c.get("type") != "file"]
    for component in components:
        name = component.get("name", "")
        version = component.get("version", "")
        key = bare_name(name)

        if key in overrides:
            template = overrides[key]
            cpe = apply_version_to_cpe(template, version)
            component["cpe"] = cpe
            enriched_names.append(name)
        elif not component.get("cpe"):
            no_cpe_names.append((name, version))

    return sbom, enriched_names, no_cpe_names


def main():
    parser = argparse.ArgumentParser(
        description="Apply CPE overrides to a Syft CycloneDX SBOM.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s --sbom attestation/sbom.cdx.json \\
           --overrides config/cpe-overrides.yaml \\
           --output attestation/sbom-enriched.cdx.json

Output:
  Writes the enriched SBOM to --output.
  Prints a CPE gap report (packages with no CPE after enrichment) to stderr.
  Always exits 0 — gaps are informational, not failures.
        """,
    )
    parser.add_argument(
        "--sbom",
        required=True,
        metavar="PATH",
        help="Path to the Syft-generated CycloneDX JSON SBOM",
    )
    parser.add_argument(
        "--overrides",
        required=True,
        metavar="PATH",
        help="Path to cpe-overrides.yaml (exception list)",
    )
    parser.add_argument(
        "--output",
        required=True,
        metavar="PATH",
        help="Path to write the enriched CycloneDX JSON SBOM",
    )
    args = parser.parse_args()

    # Load inputs
    sbom_path = Path(args.sbom)
    if not sbom_path.exists():
        print(f"[enrich-sbom] ERROR: SBOM file not found: {args.sbom}", file=sys.stderr)
        sys.exit(1)

    overrides_path = Path(args.overrides)
    if not overrides_path.exists():
        print(
            f"[enrich-sbom] WARNING: Overrides file not found: {args.overrides} — "
            "proceeding with no overrides.",
            file=sys.stderr,
        )
        overrides = {}
    else:
        overrides = load_overrides(args.overrides)

    with open(sbom_path) as f:
        sbom = json.load(f)

    # Enrich
    enriched_sbom, enriched_names, no_cpe_names = enrich(sbom, overrides)

    total_components = len(sbom.get("components", []))
    total_packages = sum(1 for c in sbom.get("components", []) if c.get("type") != "file")
    print(
        f"[enrich-sbom] Processed {total_packages} packages "
        f"({total_components - total_packages} file-type components skipped); "
        f"applied {len(enriched_names)} CPE override(s).",
        file=sys.stderr,
    )

    # Report gaps
    if no_cpe_names:
        print(
            f"[enrich-sbom] CPE GAPS ({len(no_cpe_names)} packages with no CPE — "
            "Grype cannot scan these):",
            file=sys.stderr,
        )
        for name, version in sorted(no_cpe_names):
            ver_str = f" ({version})" if version else ""
            print(f"  - {name}{ver_str}", file=sys.stderr)
    else:
        print("[enrich-sbom] No CPE gaps — all packages have CPE mappings.", file=sys.stderr)

    # Write enriched SBOM
    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with open(out_path, "w") as f:
        json.dump(enriched_sbom, f, indent=2)
        f.write("\n")

    print(f"[enrich-sbom] Enriched SBOM written to {args.output}", file=sys.stderr)

    # Return gap count for use by attestation.sh summary
    # (written to a sidecar file that attestation.sh can read)
    gap_file = out_path.parent / "cpe-gap-count.txt"
    with open(gap_file, "w") as f:
        f.write(str(len(no_cpe_names)) + "\n")

    sys.exit(0)


if __name__ == "__main__":
    main()
