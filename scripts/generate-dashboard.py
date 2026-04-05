#!/usr/bin/env python3
"""
generate-dashboard.py — Static HTML attestation dashboard for The Monolith.

Reads all attestation-summary.json files from a local directory (or syncs
from S3 first), and generates:
  output-dir/index.html                  — build table, newest first
  output-dir/builds/{build_tag}.html     — per-build detail page

No JavaScript frameworks. No external resources. Dark theme, monospace font.
Status colors: green=pass, red=fail, yellow=revoked, grey=unknown.

Usage:
  generate-dashboard.py --input-dir PATH --output-dir PATH [--s3-sync s3://...]
"""

import argparse
import html
import json
import os
import subprocess
import sys
from pathlib import Path


# ── CSS (inline in every page) ───────────────────────────────────────────────
STYLE = """
body {
    font-family: 'Courier New', Courier, monospace;
    background: #0a0a0a;
    color: #c0c0c0;
    margin: 0;
    padding: 20px 40px;
    font-size: 14px;
}
h1 { color: #e0e0e0; border-bottom: 1px solid #333; padding-bottom: 8px; }
h2 { color: #b0b0b0; }
a  { color: #5599ff; text-decoration: none; }
a:hover { text-decoration: underline; }
table { border-collapse: collapse; width: 100%; margin-top: 12px; }
th {
    background: #1a1a1a;
    color: #e0e0e0;
    padding: 8px 12px;
    text-align: left;
    border: 1px solid #333;
}
td {
    padding: 8px 12px;
    border: 1px solid #222;
}
tr:hover td { background: #111; }
.pass    { color: #00cc44; font-weight: bold; }
.fail    { color: #ff3333; font-weight: bold; }
.revoked { color: #ffaa00; font-weight: bold; }
.unknown { color: #666; }
.overall-pass    { background: #001a0a; }
.overall-fail    { background: #1a0000; }
.overall-revoked { background: #1a1000; }
pre {
    background: #111;
    border: 1px solid #333;
    padding: 12px;
    overflow-x: auto;
    white-space: pre-wrap;
    word-break: break-all;
    font-size: 12px;
}
.section { margin-top: 24px; }
.back { margin-bottom: 16px; display: block; }
.hash { font-size: 11px; color: #888; word-break: break-all; }
"""


def status_badge(status: str) -> str:
    s = html.escape(str(status))
    css = {"pass": "pass", "fail": "fail", "revoked": "revoked"}.get(status, "unknown")
    return f'<span class="{css}">{s.upper()}</span>'


def row_class(overall: str) -> str:
    mapping = {"pass": "overall-pass", "fail": "overall-fail", "revoked": "overall-revoked"}
    return mapping.get(overall, "")


def h(val) -> str:
    """HTML-escape a value, converting None to ''."""
    return html.escape(str(val)) if val is not None else ""


def load_summaries(input_dir: str) -> list:
    """
    Walk input_dir for all attestation-summary.json files.
    Returns list sorted by timestamp descending (newest first).
    """
    summaries = []
    base = Path(input_dir)
    for summary_path in base.rglob("attestation-summary.json"):
        try:
            with open(summary_path) as f:
                data = json.load(f)
            data["_source_dir"] = str(summary_path.parent)
            summaries.append(data)
        except Exception as e:
            print(f"[dashboard] WARNING: could not load {summary_path}: {e}", file=sys.stderr)

    summaries.sort(key=lambda d: d.get("timestamp", ""), reverse=True)
    return summaries


def load_json_optional(path: str) -> dict:
    """Load a JSON file, returning empty dict on any error."""
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return {}


def render_index(summaries: list) -> str:
    rows = []
    for s in summaries:
        tag = s.get("build_tag", "unknown")
        ts = s.get("timestamp", "")[:10]  # date only
        pkg_count = s.get("package_count", "?")
        unmapped = s.get("unmapped_cpe_count", "?")
        lic = s.get("license_check", "unknown")
        cve = s.get("cve_check", "unknown")
        overall = s.get("overall", "unknown")
        rc = row_class(overall)

        rows.append(f"""
  <tr class="{rc}">
    <td><a href="builds/{h(tag)}.html">{h(tag)}</a></td>
    <td>{h(ts)}</td>
    <td>{h(pkg_count)}</td>
    <td>{h(unmapped)}</td>
    <td>{status_badge(lic)}</td>
    <td>{status_badge(cve)}</td>
    <td>{status_badge(overall)}</td>
  </tr>""")

    rows_html = "\n".join(rows) if rows else "<tr><td colspan='7'>No builds found.</td></tr>"

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>The Monolith — Attestation Dashboard</title>
<style>{STYLE}</style>
</head>
<body>
<h1>&#9632; The Monolith — Attestation Dashboard</h1>
<p>Build attestation records: SBOM, license compliance, and CVE scan results.
   <br>Status colors: <span class="pass">PASS</span> &nbsp;
   <span class="fail">FAIL</span> &nbsp;
   <span class="revoked">REVOKED</span> (new CVEs discovered after ship)
</p>
<table>
  <thead>
    <tr>
      <th>Build Tag</th>
      <th>Date</th>
      <th>Packages</th>
      <th>Unmapped CPEs</th>
      <th>Licenses</th>
      <th>CVEs</th>
      <th>Overall</th>
    </tr>
  </thead>
  <tbody>
{rows_html}
  </tbody>
</table>
<p style="color:#555; font-size:12px; margin-top:24px;">
  Generated by generate-dashboard.py &mdash; {len(summaries)} build(s) listed.
</p>
</body>
</html>
"""


def render_build_page(summary: dict, source_dir: str) -> str:
    tag = summary.get("build_tag", "unknown")
    ts = summary.get("timestamp", "")
    overall = summary.get("overall", "unknown")
    iso_sha = summary.get("iso_sha256", "")
    pkg_count = summary.get("package_count", "?")
    unmapped = summary.get("unmapped_cpe_count", "?")
    lic_status = summary.get("license_check", "unknown")
    cve_status = summary.get("cve_check", "unknown")
    sbom_check = summary.get("sbom_check", "unknown")
    cve_failures = summary.get("cve_failures") or []
    license_failures = summary.get("license_failures") or []

    # Load detail reports if available
    license_report = load_json_optional(os.path.join(source_dir, "license-report.json"))
    cve_report = load_json_optional(os.path.join(source_dir, "cve-report.json"))
    sbom_data = load_json_optional(os.path.join(source_dir, "sbom-enriched.cdx.json"))
    if not sbom_data:
        sbom_data = load_json_optional(os.path.join(source_dir, "sbom.cdx.json"))

    # ── SBOM package table ───────────────────────────────────────────────────
    sbom_rows = []
    for c in sbom_data.get("components", []):
        name = c.get("name", "")
        ver = c.get("version", "")
        cpe = c.get("cpe", "")
        purl = c.get("purl", "")
        lic_val = ""
        for entry in (c.get("licenses") or []):
            if "expression" in entry:
                lic_val = entry["expression"]
            elif "license" in entry:
                lobj = entry["license"]
                lic_val = lobj.get("id") or lobj.get("name") or ""
        sbom_rows.append(
            f"<tr><td>{h(name)}</td><td>{h(ver)}</td>"
            f"<td>{h(lic_val)}</td><td class='hash'>{h(cpe)}</td></tr>"
        )

    sbom_table = ""
    if sbom_rows:
        sbom_table = (
            "<table><thead><tr>"
            "<th>Package</th><th>Version</th><th>License</th><th>CPE</th>"
            "</tr></thead><tbody>"
            + "\n".join(sbom_rows)
            + "</tbody></table>"
        )
    else:
        sbom_table = "<p class='unknown'>SBOM data not available.</p>"

    # ── License detail table ──────────────────────────────────────────────────
    lic_rows = []
    for c in license_report.get("components", []):
        status = c.get("status", "unknown")
        lic_rows.append(
            f"<tr><td>{h(c.get('name',''))}</td>"
            f"<td>{h(c.get('version',''))}</td>"
            f"<td>{h(c.get('raw_license',''))}</td>"
            f"<td>{status_badge(status)}</td>"
            f"<td>{h(c.get('reason',''))}</td></tr>"
        )

    lic_table = ""
    if lic_rows:
        lic_sum = license_report.get("summary", {})
        lic_table = (
            f"<p>{h(lic_sum.get('total','?'))} packages: "
            f"{h(lic_sum.get('pass','?'))} pass, "
            f"{h(lic_sum.get('fail','?'))} fail, "
            f"{h(lic_sum.get('unknown','?'))} unknown</p>"
            "<table><thead><tr>"
            "<th>Package</th><th>Version</th><th>License</th><th>Status</th><th>Reason</th>"
            "</tr></thead><tbody>"
            + "\n".join(lic_rows)
            + "</tbody></table>"
        )
    else:
        lic_table = "<p class='unknown'>License report not available.</p>"

    # ── CVE detail table ──────────────────────────────────────────────────────
    cve_rows = []
    for m in (cve_report.get("matches") or []):
        art = m.get("artifact", {})
        vuln = m.get("vulnerability", {})
        cve_rows.append(
            f"<tr>"
            f"<td>{h(art.get('name',''))}</td>"
            f"<td>{h(art.get('version',''))}</td>"
            f"<td>{h(vuln.get('id',''))}</td>"
            f"<td>{h(vuln.get('severity',''))}</td>"
            f"<td>{h(vuln.get('description','')[:120])}</td>"
            f"</tr>"
        )

    cve_table = ""
    if cve_rows:
        cve_table = (
            f"<p>{len(cve_rows)} finding(s)</p>"
            "<table><thead><tr>"
            "<th>Package</th><th>Version</th><th>CVE</th><th>Severity</th><th>Description</th>"
            "</tr></thead><tbody>"
            + "\n".join(cve_rows)
            + "</tbody></table>"
        )
    elif cve_report:
        cve_table = "<p class='pass'>No CVE findings.</p>"
    else:
        cve_table = "<p class='unknown'>CVE report not available.</p>"

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>The Monolith — Build {h(tag)}</title>
<style>{STYLE}</style>
</head>
<body>
<a href="../index.html" class="back">&larr; Back to dashboard</a>
<h1>&#9632; Build: {h(tag)}</h1>

<table style="width:auto">
  <tr><th>Build Tag</th><td>{h(tag)}</td></tr>
  <tr><th>Timestamp</th><td>{h(ts)}</td></tr>
  <tr><th>Packages</th><td>{h(pkg_count)}</td></tr>
  <tr><th>Unmapped CPEs</th><td>{h(unmapped)}</td></tr>
  <tr><th>ISO SHA-256</th><td class="hash">{h(iso_sha)}</td></tr>
  <tr><th>SBOM</th><td>{status_badge(sbom_check)}</td></tr>
  <tr><th>Licenses</th><td>{status_badge(lic_status)}</td></tr>
  <tr><th>CVEs</th><td>{status_badge(cve_status)}</td></tr>
  <tr><th>Overall</th><td>{status_badge(overall)}</td></tr>
</table>

<div class="section">
  <h2>SBOM — Package Inventory</h2>
  {sbom_table}
</div>

<div class="section">
  <h2>License Compliance</h2>
  {lic_table}
</div>

<div class="section">
  <h2>CVE Check</h2>
  {cve_table}
</div>

</body>
</html>
"""


def write_html(path: str, content: str) -> None:
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(content, encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(
        description="Generate a static HTML attestation dashboard.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s --input-dir output/attestation --output-dir output/dashboard
  %(prog)s --input-dir /tmp/attest --output-dir /tmp/dash \\
           --s3-sync s3://my-bucket/attestation
        """,
    )
    parser.add_argument(
        "--input-dir", required=True, metavar="PATH",
        help="Directory containing attestation-summary.json files (one per build subdirectory)"
    )
    parser.add_argument(
        "--output-dir", required=True, metavar="PATH",
        help="Directory to write the HTML dashboard"
    )
    parser.add_argument(
        "--s3-sync", metavar="S3_PATH",
        help="If given, sync attestation artifacts from S3 before generating (requires aws CLI)"
    )
    args = parser.parse_args()

    if args.s3_sync:
        print(f"[dashboard] Syncing from {args.s3_sync} → {args.input_dir} ...")
        os.makedirs(args.input_dir, exist_ok=True)
        result = subprocess.run(
            ["aws", "s3", "sync", args.s3_sync, args.input_dir],
            capture_output=False,
        )
        if result.returncode != 0:
            print("[dashboard] WARNING: S3 sync failed — proceeding with local data", file=sys.stderr)

    summaries = load_summaries(args.input_dir)
    print(f"[dashboard] Found {len(summaries)} attestation record(s).")

    index_html = render_index(summaries)
    write_html(os.path.join(args.output_dir, "index.html"), index_html)
    print(f"[dashboard] Wrote {args.output_dir}/index.html")

    for s in summaries:
        tag = s.get("build_tag", "unknown")
        source_dir = s.get("_source_dir", "")
        page_html = render_build_page(s, source_dir)
        page_path = os.path.join(args.output_dir, "builds", f"{tag}.html")
        write_html(page_path, page_html)
        print(f"[dashboard] Wrote builds/{tag}.html")

    print(f"[dashboard] Dashboard complete: {args.output_dir}/index.html")


if __name__ == "__main__":
    main()
