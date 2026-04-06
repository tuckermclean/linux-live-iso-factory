#!/usr/bin/env python3
"""
check-unowned.py — Pillar 4: Unowned files audit for The Monolith ISO.

Reads the Syft native JSON SBOM and identifies files present on the filesystem
that are not owned by any Portage package.

Syft's native JSON contains:
  artifacts[].metadata.Files[]  — files owned by each portage package (from CONTENTS)
  files[]                       — all files found on disk by the file cataloger

The diff (disk files minus owned files) = unowned files: not tracked by Portage,
not in the SBOM, not subject to license or CVE checks.

Known-unowned files (init scripts, advisory scripts, /etc config files installed
by build-rootfs.sh) are suppressed via an allowlist of fnmatch glob patterns.

Exit codes:
  0  no unallowlisted unowned files
  1  one or more unowned files not covered by the allowlist
"""

import argparse
import fnmatch
import json
import sys
from datetime import datetime, timezone
from pathlib import Path


def load_yaml_simple(path: str) -> dict:
    try:
        import yaml
    except ImportError:
        print(
            "[check-unowned] ERROR: pyyaml is not installed.\n"
            "  Install with: pip3 install pyyaml",
            file=sys.stderr,
        )
        sys.exit(1)
    with open(path) as f:
        return yaml.safe_load(f) or {}


def load_allowlist(path: str) -> list:
    """Load glob patterns from the allowlist YAML."""
    data = load_yaml_simple(path)
    return data.get("allowlist", [])


def get_file_path(file_entry: dict) -> str | None:
    """Extract the path from a Syft files[] entry, handling schema variations."""
    loc = file_entry.get("location", {})
    # Try realPath first (Syft >= 0.80), then path
    return loc.get("realPath") or loc.get("path") or loc.get("accessPath")


def get_owned_paths(syft_json: dict) -> set:
    """
    Build the set of paths owned by Portage packages.
    Reads the CONTENTS file list from each portage artifact.

    Portage CONTENTS paths are target-absolute (e.g. /usr/bin/bash),
    not prefixed with the scan root. Returns them as-is.

    Syft schema variations across versions:
      metadata.installedFiles[]  — current Syft (camelCase)
      metadata.Files[]           — older Syft (PascalCase)
      metadata.files[]           — alternate older schema
    """
    owned = set()
    portage_pkg_count = 0
    for artifact in syft_json.get("artifacts", []):
        if artifact.get("type", "").lower() != "portage":
            continue
        portage_pkg_count += 1
        metadata = artifact.get("metadata") or {}
        files = (
            metadata.get("installedFiles")
            or metadata.get("Files")
            or metadata.get("files")
            or []
        )
        for f in files:
            p = f.get("path") or f.get("Path")
            if p:
                owned.add(p)

    if portage_pkg_count > 0 and not owned:
        # Dump the metadata keys of the first portage artifact so the field
        # name mismatch can be diagnosed in CI logs.
        for artifact in syft_json.get("artifacts", []):
            if artifact.get("type", "").lower() == "portage":
                meta = artifact.get("metadata") or {}
                print(
                    f"[check-unowned] WARN: portage pkg '{artifact.get('name')}' "
                    f"has metadata keys: {list(meta.keys())} — no file list found",
                    file=sys.stderr,
                )
                break

    return owned


def get_disk_files(syft_json: dict, sysroot: str) -> dict:
    """
    Build a dict of {in_system_path: file_entry} from Syft's top-level files[].

    File cataloger paths include the sysroot prefix (e.g. /output/sysroot/usr/bin/bash).
    Strip it to get the in-system path (/usr/bin/bash).
    """
    disk_files = {}
    sysroot = sysroot.rstrip("/")

    for f in syft_json.get("files", []):
        full_path = get_file_path(f)
        if not full_path:
            continue
        # Strip sysroot prefix
        if sysroot and full_path.startswith(sysroot):
            in_system = full_path[len(sysroot):]
        else:
            in_system = full_path
        if not in_system or in_system == "/":
            continue
        disk_files[in_system] = f

    return disk_files


def auto_detect_prefix(owned_paths: set, sysroot: str) -> bool:
    """
    Check whether the portage cataloger is also prefixing CONTENTS paths
    with the sysroot (it normally doesn't, but verify defensively).
    Returns True if owned paths need the same sysroot stripping as disk files.
    """
    if not owned_paths or not sysroot:
        return False
    sample = next(iter(owned_paths))
    return sample.startswith(sysroot.rstrip("/") + "/")


def is_allowlisted(path: str, patterns: list) -> bool:
    """Check if a path matches any allowlist glob pattern."""
    rel = path.lstrip("/")
    for pattern in patterns:
        if fnmatch.fnmatch(rel, pattern):
            return True
        # Also try matching the full path for patterns with leading /
        if fnmatch.fnmatch(path, pattern):
            return True
    return False


def main():
    parser = argparse.ArgumentParser(
        description="Audit filesystem files against Portage package ownership.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s --syft-json attestation/sbom.syft.json \\
           --sysroot /output/sysroot \\
           --output  attestation/unowned-report.json \\
           --allowlist config/unowned-allowlist.yaml

Exit codes:
  0  no unallowlisted unowned files
  1  unowned files found
        """,
    )
    parser.add_argument("--syft-json",  required=True, metavar="PATH", help="Syft native JSON SBOM")
    parser.add_argument("--sysroot",    required=True, metavar="PATH", help="Sysroot prefix to strip from file paths")
    parser.add_argument("--output",     required=True, metavar="PATH", help="JSON report output path")
    parser.add_argument("--allowlist",  metavar="PATH", help="YAML file with glob patterns for known-unowned files")
    args = parser.parse_args()

    syft_path = Path(args.syft_json)
    if not syft_path.exists():
        print(f"[check-unowned] ERROR: Syft JSON not found: {args.syft_json}", file=sys.stderr)
        sys.exit(1)

    allowlist = []
    if args.allowlist:
        al_path = Path(args.allowlist)
        if al_path.exists():
            allowlist = load_allowlist(args.allowlist)
        else:
            print(f"[check-unowned] WARN: allowlist not found: {args.allowlist}", file=sys.stderr)

    with open(syft_path) as f:
        syft_json = json.load(f)

    schema_ver = syft_json.get("schema", {}).get("version", "unknown")
    print(f"[check-unowned] Syft schema version: {schema_ver}")

    owned_paths = get_owned_paths(syft_json)
    print(f"[check-unowned] Portage-owned paths: {len(owned_paths)}")

    sysroot = args.sysroot.rstrip("/")

    # Defensive: check if owned paths also carry the sysroot prefix
    if auto_detect_prefix(owned_paths, sysroot):
        print(f"[check-unowned] NOTE: portage metadata paths also include sysroot prefix; normalizing", file=sys.stderr)
        owned_paths = {p[len(sysroot):] for p in owned_paths}

    disk_files = get_disk_files(syft_json, sysroot)
    print(f"[check-unowned] Files on disk (from Syft): {len(disk_files)}")

    if not disk_files:
        print(
            "[check-unowned] WARN: no entries in Syft files[] — was file.metadata.selection=all set?",
            file=sys.stderr,
        )

    unowned_all = []
    allowlisted_count = 0
    owned_count = 0

    for path in sorted(disk_files):
        if path in owned_paths:
            owned_count += 1
        elif is_allowlisted(path, allowlist):
            allowlisted_count += 1
        else:
            unowned_all.append(path)

    n_unowned = len(unowned_all)
    n_total = len(disk_files)

    report = {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "syft_schema": schema_ver,
        "sysroot": sysroot,
        "summary": {
            "total_files": n_total,
            "owned": owned_count,
            "allowlisted": allowlisted_count,
            "unowned": n_unowned,
        },
        "unowned_files": unowned_all,
    }

    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with open(out_path, "w") as f:
        json.dump(report, f, indent=2)
        f.write("\n")

    color_pass = "\033[0;32m"
    color_fail = "\033[0;31m"
    reset = "\033[0m"
    status = "PASS" if n_unowned == 0 else "FAIL"
    color = color_pass if n_unowned == 0 else color_fail

    print(
        f"\n[check-unowned] {color}{status}{reset}: "
        f"{n_total} files — {owned_count} owned, {allowlisted_count} allowlisted, {n_unowned} unowned"
    )

    if n_unowned > 0:
        print("[check-unowned] Unowned files (add to allowlist or move to an ebuild):")
        for p in unowned_all:
            print(f"  {p}")

    print(f"[check-unowned] Report written to {args.output}")
    sys.exit(1 if n_unowned > 0 else 0)


if __name__ == "__main__":
    main()
