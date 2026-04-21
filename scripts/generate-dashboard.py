#!/usr/bin/env python3
"""
generate-dashboard.py — Generate the builds-index.json consumed by the SPA.

Reads all attestation-summary.json files under --input-dir (one subdirectory
per build), sorts newest-first, computes CPE delta, and writes:

  <output-dir>/builds-index.json   — full build list array
  <output-dir>/latest-build.json   — single-entry array (first build only)

The SPA at web/index.html fetches builds-index.json from S3 at runtime.
"""

import argparse
import json
import sys
from pathlib import Path


def load_summary(path: Path) -> dict | None:
    try:
        with open(path) as f:
            return json.load(f)
    except Exception as e:
        print(f"[generate-dashboard] WARN: could not read {path}: {e}", file=sys.stderr)
        return None


def main():
    parser = argparse.ArgumentParser(description="Generate builds-index.json for the Monolith SPA.")
    parser.add_argument("--input-dir",  required=True, metavar="PATH",
                        help="Directory containing per-build attestation subdirectories")
    parser.add_argument("--output-dir", required=True, metavar="PATH",
                        help="Output directory for builds-index.json and latest-build.json")
    args = parser.parse_args()

    input_dir  = Path(args.input_dir)
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    # Collect all attestation-summary.json files, one per build subdirectory.
    entries = []
    for summary_path in sorted(input_dir.rglob("attestation-summary.json"), reverse=True):
        s = load_summary(summary_path)
        if not s:
            continue
        tag = s.get("build_tag", summary_path.parent.name)
        entries.append({
            "tag":          tag,
            "date":         s.get("timestamp", "")[:10],   # YYYY-MM-DD
            "packages":     s.get("package_count", 0),
            "unmappedCPEs": s.get("unmapped_cpe_count", 0),
            "excludedCPEs": s.get("excluded_cpe_count", 0),
            "cpeDelta":     0,   # computed below
            "licenses":     (s.get("license_check") or "").upper(),
            "cves":         (s.get("cve_check")     or "").upper(),
            "unowned":      (s.get("unowned_check") or "").upper(),
            "overall":      (s.get("overall")       or "").upper(),
        })

    # Sort newest first by tag (YYYYMMDD-hash lexsort works correctly).
    entries.sort(key=lambda e: e["tag"], reverse=True)

    # Compute CPE delta: how the unmapped CPE count changed vs the prior build.
    for i, e in enumerate(entries):
        if i + 1 < len(entries):
            e["cpeDelta"] = e["unmappedCPEs"] - entries[i + 1]["unmappedCPEs"]
        # else cpeDelta stays 0 for the oldest build

    # Write outputs.
    index_path  = output_dir / "builds-index.json"
    latest_path = output_dir / "latest-build.json"

    with open(index_path, "w") as f:
        json.dump(entries, f, indent=2)
        f.write("\n")

    with open(latest_path, "w") as f:
        json.dump(entries[:1], f, indent=2)
        f.write("\n")

    print(f"[generate-dashboard] {len(entries)} builds → {index_path}", file=sys.stderr)
    print(f"[generate-dashboard] Latest build → {latest_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
