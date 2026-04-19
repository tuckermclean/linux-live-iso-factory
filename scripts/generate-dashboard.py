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
.sq { color: #555555; }
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


def _cpe_delta_cell(current: int | str, previous: int | str | None) -> str:
    """Render a CPE-count delta cell. Green for improvement, red for regression."""
    if previous is None:
        return "<td style='color:#555'>—</td>"
    try:
        delta = int(current) - int(previous)
    except (TypeError, ValueError):
        return "<td style='color:#555'>?</td>"
    if delta == 0:
        return "<td style='color:#555'>0</td>"
    color = "#ff3333" if delta > 0 else "#00cc44"
    sign  = "+" if delta > 0 else ""
    return f"<td style='color:{color};font-weight:bold'>{sign}{delta}</td>"


def render_index(summaries: list) -> str:
    # summaries is sorted newest-first; we need previous-build CPE counts for delta.
    # Index i compares against index i+1 (the older build).
    rows = []
    for i, s in enumerate(summaries):
        tag = s.get("build_tag", "unknown")
        ts = s.get("timestamp", "")[:10]  # date only
        pkg_count = s.get("package_count", "?")
        unmapped = s.get("unmapped_cpe_count", "?")
        lic = s.get("license_check", "unknown")
        cve = s.get("cve_check", "unknown")
        overall = s.get("overall", "unknown")
        rc = row_class(overall)
        unowned = s.get("unowned_check", "unknown")

        prev_unmapped = summaries[i + 1].get("unmapped_cpe_count") if i + 1 < len(summaries) else None
        delta_cell = _cpe_delta_cell(unmapped, prev_unmapped)

        rows.append(f"""
  <tr class="{rc}">
    <td><a href="builds/{h(tag)}.html">{h(tag)}</a></td>
    <td>{h(ts)}</td>
    <td>{h(pkg_count)}</td>
    <td>{h(unmapped)}</td>
    {delta_cell}
    <td>{status_badge(lic)}</td>
    <td>{status_badge(cve)}</td>
    <td>{status_badge(unowned)}</td>
    <td>{status_badge(overall)}</td>
  </tr>""")

    rows_html = "\n".join(rows) if rows else "<tr><td colspan='9'>No builds found.</td></tr>"

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>The Monolith — Attestation Dashboard</title>
<style>{STYLE}</style>
</head>
<body>
<h1><span class="sq">&#9632;</span> The Monolith — Attestation Dashboard</h1>
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
      <th>CPE &Delta;</th>
      <th>Licenses</th>
      <th>CVEs</th>
      <th>Unowned</th>
      <th>Overall</th>
    </tr>
  </thead>
  <tbody>
{rows_html}
  </tbody>
</table>
<p style="color:#555; font-size:12px; margin-top:24px;">
  Generated by generate-dashboard.py &mdash; {len(summaries)} build(s) listed.
  CPE &Delta; = change in unmapped-CPE count vs. the prior build (red = more gaps, green = fewer).
</p>
</body>
</html>
"""


def render_build_page(summary: dict, source_dir: str, base_url: str = "") -> str:
    tag = summary.get("build_tag", "unknown")
    ts = summary.get("timestamp", "")
    overall = summary.get("overall", "unknown")
    iso_sha = summary.get("iso_sha256", "")
    pkg_count = summary.get("package_count", "?")
    unmapped = summary.get("unmapped_cpe_count", "?")
    lic_status = summary.get("license_check", "unknown")
    cve_status = summary.get("cve_check", "unknown")
    sbom_check = summary.get("sbom_check", "unknown")

    # ── Download links ────────────────────────────────────────────────────────
    download_rows = ""
    if base_url:
        base = base_url.rstrip("/")
        iso_url      = f"{base}/themonolith-{tag}.iso"
        sbom_url     = f"{base}/attestation/{tag}/sbom-enriched.cdx.json"
        cve_url      = f"{base}/attestation/{tag}/cve-report.json"
        lic_url      = f"{base}/attestation/{tag}/license-report.json"
        unowned_url  = f"{base}/attestation/{tag}/unowned-report.json"
        download_rows = (
            f"<tr><th>ISO Download</th><td><a href=\"{h(iso_url)}\">"
            f"themonolith-{h(tag)}.iso</a></td></tr>\n"
            f"  <tr><th>SBOM (CycloneDX)</th><td><a href=\"{h(sbom_url)}\">"
            f"sbom-enriched.cdx.json</a></td></tr>\n"
            f"  <tr><th>CVE Report</th><td><a href=\"{h(cve_url)}\">cve-report.json</a></td></tr>\n"
            f"  <tr><th>License Report</th><td><a href=\"{h(lic_url)}\">license-report.json</a></td></tr>\n"
            f"  <tr><th>Unowned Report</th><td><a href=\"{h(unowned_url)}\">unowned-report.json</a></td></tr>"
        )
    cve_failures = summary.get("cve_failures") or []
    license_failures = summary.get("license_failures") or []

    # Load detail reports if available
    license_report  = load_json_optional(os.path.join(source_dir, "license-report.json"))
    cve_report      = load_json_optional(os.path.join(source_dir, "cve-report.json"))
    unowned_report  = load_json_optional(os.path.join(source_dir, "unowned-report.json"))
    provenance_data = load_json_optional(os.path.join(source_dir, "slsa-provenance.json"))
    sbom_data = load_json_optional(os.path.join(source_dir, "sbom-enriched.cdx.json"))
    if not sbom_data:
        sbom_data = load_json_optional(os.path.join(source_dir, "sbom.cdx.json"))
    builder_sbom_data = load_json_optional(os.path.join(source_dir, "builder-sbom-enriched.cdx.json"))
    if not builder_sbom_data:
        builder_sbom_data = load_json_optional(os.path.join(source_dir, "builder-sbom.cdx.json"))
    builder_cve_report = load_json_optional(os.path.join(source_dir, "builder-cve-report.json"))
    builder_info = summary.get("builder") or {}

    unowned_status = summary.get("unowned_check", "unknown")

    # ── SBOM package table ───────────────────────────────────────────────────
    # Skip type:"file" entries — those are individual filesystem files from the
    # file cataloger, not packages. They have no license info and clutter the table.
    sbom_rows = []
    for c in sbom_data.get("components", []):
        if c.get("type") == "file":
            continue
        name = c.get("name", "")
        ver = c.get("version", "")
        cpe = c.get("cpe", "")
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

    # ── Builder environment section (Pillar 5) ───────────────────────────────
    builder_section = ""
    if builder_info.get("attested"):
        b_epoch       = builder_info.get("epoch", "unknown")
        b_target      = builder_info.get("cross_target", "unknown")
        b_digest      = builder_info.get("image_digest", "")
        b_pkg_count   = builder_info.get("package_count", "?")
        b_unmapped    = builder_info.get("unmapped_cpe_count", "?")
        b_sbom_status = builder_info.get("sbom_check", "unknown")
        b_cve_status  = builder_info.get("cve_check", "unknown")

        # Builder package table
        b_sbom_rows = []
        for c in builder_sbom_data.get("components", []):
            if c.get("type") == "file":
                continue
            cpe = c.get("cpe", "")
            b_sbom_rows.append(
                f"<tr><td>{h(c.get('name',''))}</td>"
                f"<td>{h(c.get('version',''))}</td>"
                f"<td class='hash'>{h(cpe)}</td></tr>"
            )
        b_sbom_table = (
            "<table><thead><tr><th>Package</th><th>Version</th><th>CPE</th></tr></thead><tbody>"
            + "\n".join(b_sbom_rows)
            + "</tbody></table>"
        ) if b_sbom_rows else "<p class='unknown'>Builder SBOM not available.</p>"

        # Builder CVE table
        b_cve_rows = []
        for m in (builder_cve_report.get("matches") or []):
            art  = m.get("artifact", {})
            vuln = m.get("vulnerability", {})
            b_cve_rows.append(
                f"<tr>"
                f"<td>{h(art.get('name',''))}</td>"
                f"<td>{h(art.get('version',''))}</td>"
                f"<td>{h(vuln.get('id',''))}</td>"
                f"<td>{h(vuln.get('severity',''))}</td>"
                f"<td>{h(vuln.get('description','')[:120])}</td>"
                f"</tr>"
            )
        if b_cve_rows:
            b_cve_table = (
                f"<p>{len(b_cve_rows)} finding(s)</p>"
                "<table><thead><tr>"
                "<th>Package</th><th>Version</th><th>CVE</th><th>Severity</th><th>Description</th>"
                "</tr></thead><tbody>"
                + "\n".join(b_cve_rows)
                + "</tbody></table>"
            )
        elif builder_cve_report:
            b_cve_table = "<p class='pass'>No CVE findings in builder environment.</p>"
        else:
            b_cve_table = "<p class='unknown'>Builder CVE report not available.</p>"

        builder_section = f"""
<div class="section">
  <h2>Builder Environment (Pillar 5)</h2>
  <table style="width:auto">
    <tr><th>BUILD_EPOCH</th><td>{h(b_epoch)}</td></tr>
    <tr><th>Cross target</th><td>{h(b_target)}</td></tr>
    <tr><th>Image digest</th><td class="hash">{h(b_digest) if b_digest else '(not recorded)'}</td></tr>
    <tr><th>Builder packages</th><td>{h(b_pkg_count)}</td></tr>
    <tr><th>Unmapped CPEs</th><td>{h(b_unmapped)}</td></tr>
    <tr><th>Builder SBOM</th><td>{status_badge(b_sbom_status)}</td></tr>
    <tr><th>Builder CVEs</th><td>{status_badge(b_cve_status)}</td></tr>
  </table>
  <h2>Builder Package Inventory</h2>
  {b_sbom_table}
  <h2>Builder CVE Findings</h2>
  {b_cve_table}
</div>"""

    # ── Packages without CPE (unscanned by Grype) ────────────────────────────
    no_cpe_pkgs = [
        (c.get("name", ""), c.get("version", ""))
        for c in sbom_data.get("components", [])
        if c.get("type") != "file" and not c.get("cpe")
    ]
    if no_cpe_pkgs:
        no_cpe_count = len(no_cpe_pkgs)
        no_cpe_rows = "".join(
            f"<tr><td>{h(name)}</td><td>{h(ver)}</td></tr>"
            for name, ver in sorted(no_cpe_pkgs)
        )
        no_cpe_section = (
            f"<p><span class='revoked'>{no_cpe_count} package(s)</span> have no CPE mapping "
            f"and were not submitted to Grype for CVE matching. This is an attestation gap — "
            f"CVE coverage for these packages is unknown.</p>"
            "<table><thead><tr><th>Package</th><th>Version</th></tr></thead><tbody>"
            + no_cpe_rows
            + "</tbody></table>"
        )
    else:
        no_cpe_section = "<p class='pass'>All packages have CPE mappings — full CVE coverage.</p>"

    # ── Scanner metadata ──────────────────────────────────────────────────────
    # Prefer summary.scanner_meta (written by attestation.sh from the sidecar);
    # fall back to descriptor block embedded in the loaded cve_report.
    scanner_meta = summary.get("scanner_meta") or {}
    if not scanner_meta and cve_report:
        desc = cve_report.get("descriptor", {})
        db   = desc.get("db", {})
        scanner_meta = {
            "scanner":         desc.get("name", ""),
            "scanner_version": desc.get("version", ""),
            "db_built":        db.get("built", ""),
        }
    scanner_name    = scanner_meta.get("scanner", "")
    scanner_version = scanner_meta.get("scanner_version", "")
    db_built        = scanner_meta.get("db_built", "")
    scanner_row = (
        f"<tr><th>Scanner</th><td>{h(scanner_name)} {h(scanner_version)}</td></tr>"
        if scanner_name else ""
    )
    db_row = (
        f"<tr><th>CVE DB built</th><td>{h(db_built)}</td></tr>"
        if db_built else ""
    )

    # ── Byproduct hashes + attestation verify ─────────────────────────────────
    provenance_section = ""
    if provenance_data:
        byproducts = (
            provenance_data.get("predicate", {})
            .get("runDetails", {})
            .get("byproducts", [])
        )
        # Extract repo owner for the gh attestation verify command
        workflow_repo = (
            provenance_data.get("predicate", {})
            .get("buildDefinition", {})
            .get("externalParameters", {})
            .get("workflow", {})
            .get("repository", "")
        )
        owner = workflow_repo.rstrip("/").split("/")[-2] if "/" in workflow_repo else ""

        byproduct_rows = "".join(
            f"<tr><td>{h(bp.get('name',''))}</td>"
            f"<td class='hash'>{h(bp.get('digest',{}).get('sha256',''))}</td></tr>"
            for bp in byproducts
        )
        byproduct_table = (
            "<table><thead><tr><th>Artifact</th><th>SHA-256</th></tr></thead><tbody>"
            + byproduct_rows
            + "</tbody></table>"
        ) if byproduct_rows else "<p class='unknown'>No byproducts recorded.</p>"

        verify_cmd = (
            f"gh attestation verify themonolith-{h(tag)}.iso \\\n"
            f"  --owner {h(owner)} \\\n"
            f"  --predicate-type https://slsa.dev/provenance/v1"
        ) if owner else (
            f"gh attestation verify themonolith-{h(tag)}.iso \\\n"
            f"  --predicate-type https://slsa.dev/provenance/v1"
        )

        provenance_section = f"""
<div class="section">
  <h2>Provenance — Byproduct Digests</h2>
  <p>These SHA-256 hashes are pinned inside the signed SLSA provenance statement.
     Download any artifact and verify with <code>sha256sum</code> to confirm it
     matches what was attested.</p>
  {byproduct_table}
  <h2>Verify Attestation</h2>
  <p>Requires the <a href="https://cli.github.com/">GitHub CLI</a> with
     <code>gh extension install github/gh-attestation</code> (or
     <code>cosign verify-blob-attestation</code> with the Rekor bundle).</p>
  <pre>{verify_cmd}</pre>
</div>"""

    # ── Unowned files section ─────────────────────────────────────────────────
    if unowned_report:
        u_sum = unowned_report.get("summary", {})
        u_files = unowned_report.get("unowned_files", [])
        u_count = u_sum.get("unowned", len(u_files))
        u_total = u_sum.get("total_files", "?")
        u_owned = u_sum.get("owned", "?")
        u_allowed = u_sum.get("allowlisted", "?")
        if u_count == 0:
            unowned_section = (
                f"<p class='pass'>PASS — {h(u_total)} files: "
                f"{h(u_owned)} owned by Portage, {h(u_allowed)} allowlisted, 0 unowned.</p>"
            )
        else:
            file_rows = "".join(f"<tr><td>{h(p)}</td></tr>" for p in sorted(u_files))
            unowned_section = (
                f"<p class='fail'>FAIL — {h(u_count)} unowned file(s) "
                f"(of {h(u_total)} total: {h(u_owned)} owned, {h(u_allowed)} allowlisted)</p>"
                "<table><thead><tr><th>Path</th></tr></thead><tbody>"
                + file_rows
                + "</tbody></table>"
            )
    else:
        unowned_section = "<p class='unknown'>Unowned files report not available.</p>"

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>The Monolith — Build {h(tag)}</title>
<style>{STYLE}</style>
</head>
<body>
<a href="../index.html" class="back">&larr; Back to dashboard</a>
<h1><span class="sq">&#9632;</span> Build: {h(tag)}</h1>

<table style="width:auto">
  <tr><th>Build Tag</th><td>{h(tag)}</td></tr>
  <tr><th>Timestamp</th><td>{h(ts)}</td></tr>
  <tr><th>Packages</th><td>{h(pkg_count)}</td></tr>
  <tr><th>Unmapped CPEs</th><td>{h(unmapped)}</td></tr>
  <tr><th>ISO SHA-256</th><td class="hash">{h(iso_sha)}</td></tr>
  {download_rows}
  <tr><th>SBOM</th><td>{status_badge(sbom_check)}</td></tr>
  <tr><th>Licenses</th><td>{status_badge(lic_status)}</td></tr>
  <tr><th>CVEs (sysroot)</th><td>{status_badge(cve_status)}</td></tr>
  <tr><th>Unowned Files</th><td>{status_badge(unowned_status)}</td></tr>
  {"<tr><th>Builder CVEs</th><td>" + status_badge(builder_info.get("cve_check","not_run")) + "</td></tr>" if builder_info.get("attested") else ""}
  {scanner_row}
  {db_row}
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

<div class="section">
  <h2>Packages Without CPE (unscanned)</h2>
  {no_cpe_section}
</div>

<div class="section">
  <h2>Unowned Files (Pillar 4)</h2>
  {unowned_section}
</div>

{provenance_section}

{builder_section}

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
    parser.add_argument(
        "--base-url", metavar="URL", default="",
        help="Public base URL for artifact downloads (e.g. https://assets.example.com). "
             "When set, build detail pages will include download links for the ISO and SBOM."
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
        page_html = render_build_page(s, source_dir, base_url=args.base_url)
        page_path = os.path.join(args.output_dir, "builds", f"{tag}.html")
        write_html(page_path, page_html)
        print(f"[dashboard] Wrote builds/{tag}.html")

    print(f"[dashboard] Dashboard complete: {args.output_dir}/index.html")


if __name__ == "__main__":
    main()
