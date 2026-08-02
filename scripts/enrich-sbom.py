#!/usr/bin/env python3
"""
enrich-sbom.py — CPE enrichment and SBOM quality fixes for Syft CycloneDX SBOM output.

Reads a CycloneDX JSON SBOM (as produced by Syft from a Portage sysroot),
applies a battery of fixes that Syft cannot handle for Gentoo/Portage:

  1. metadata.component — populate with product name, version, supplier
  2. CPE corrections — apply overrides; strip synthetic Portage-slug CPEs
  3. CPE versions — strip Gentoo revision suffix (-r<N>) before NVD matching
  4. Dependency graph — build from RDEPEND/DEPEND in the Portage vdb
  5. License normalization — map raw Gentoo names to SPDX identifiers
  6. Supplier — add supplier field to all components
  7. Component types — classify by Portage category (app-* → application, etc.)
  8. PURL qualifiers — add ?arch=...&distro=gentoo to pkg:ebuild/ PURLs
  9. Metadata — add authors, lifecycles, externalReferences
 10. Tools — record Syft, Grype (with DB metadata), build toolchain, and this script in metadata.tools
 11. Noise reduction — strip syft:cpe23 property duplicates

Usage:
    enrich-sbom.py --sbom PATH --overrides PATH --output PATH [options]

The overrides file (config/cpe-overrides.yaml) is an EXCEPTION LIST — only
packages where Syft's automatic CPE detection is wrong or absent. Packages
that Syft handles correctly should NOT appear in the overrides file.

After enrichment, reports to stderr any packages that still have no CPE
(neither Syft nor the overrides file provided one). These are attestation
gaps — Grype cannot scan them for CVEs.

Exit code: always 0. Gaps are informational, not failures.
"""

import argparse
import hashlib
import json
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
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


def strip_gentoo_suffixes(version: str) -> str:
    """
    Strip Gentoo-specific version suffixes before substituting into a CPE.

    Two suffixes are stripped:
      -r<N>   Gentoo revision — bumps the ebuild without changing the upstream
              version. NVD never includes it.
              "1.0.8-r5"    → "1.0.8"

      _p<N>   Upstream patch level as Portage encodes it. Gentoo applies
              official upstream patches and appends _pN to track them, but NVD
              CPEs reference the base release, not individual patch bundles.
              "5.3_p9-r1"   → "5.3"
              "6.5_p20251220" → "6.5"   (snapshot date suffix)

    Note: for packages where _p IS semantically part of the upstream version
    string (e.g. OpenSSH 9.8p1), add a full CPE template to cpe-overrides.yaml
    that hard-codes the correct NVD version rather than relying on auto-substitution.
    """
    v = re.sub(r"-r\d+$", "", version)   # strip Gentoo revision
    v = re.sub(r"_p\d+$", "", v)         # strip upstream patch-level suffix
    v = re.sub(r"_pre\d*$", "", v)       # strip Portage pre-release suffix (_pre1 → "")
    return v


# Keep old name as an alias so existing call-sites (unit tests etc.) still work
strip_gentoo_revision = strip_gentoo_suffixes


def apply_version_to_cpe(template: str, version: str) -> str:
    """
    Substitute the actual package version into a CPE 2.3 template string.

    CPE 2.3 format: cpe:2.3:<type>:<vendor>:<product>:<version>:<rest...>
    The version is field index 5 (0-indexed) when splitting on ':'.
    Templates in cpe-overrides.yaml use '*' as the version placeholder.

    Example:
      template = "cpe:2.3:a:haxx:curl:*:*:*:*:*:*:*:*"
      version  = "8.5.0-r1"
      result   = "cpe:2.3:a:haxx:curl:8.5.0:*:*:*:*:*:*:*"
    """
    parts = template.split(":")
    if len(parts) >= 6 and parts[5] == "*":
        # Strip Gentoo revision before substituting — NVD doesn't know about -rN
        clean_version = strip_gentoo_revision(version)
        # Sanitize version: CPE doesn't allow spaces; replace _ with . (Portage convention)
        safe_version = clean_version.replace("_", ".").replace(" ", "")
        parts[5] = safe_version
    return ":".join(parts)


def is_synthetic_cpe(cpe: str) -> bool:
    """
    Return True if this CPE is a Syft-generated Portage slug rather than an NVD-registered CPE.

    Syft builds CPEs for Portage packages by using the category/package atom as
    both vendor and product, e.g.:
      cpe:2.3:a:acct-group/sshd:acct-group/sshd:0:*:*:*:*:*:*:*
      cpe:2.3:a:app-editors/vim:app-editors/vim:9.1:*:*:*:*:*:*:*

    These will never match NVD and must be stripped.
    """
    if not cpe:
        return False
    parts = cpe.split(":")
    if len(parts) < 5:
        return False
    vendor = parts[3]
    product = parts[4]
    return "/" in vendor or "/" in product


# Maps Portage category prefix → CycloneDX component type.
# Order matters: first match wins.
_CATEGORY_TYPE_RULES = [
    ("acct-", "data"),          # acct-group/*, acct-user/* — provisioning stubs, not real software
    ("virtual/", "library"),    # Portage virtual packages
    ("dev-", "library"),        # dev-libs/*, dev-lang/*, etc.
    ("lib-", "library"),        # lib-* (rare, but exists)
    ("app-", "application"),
    ("net-", "application"),    # net-misc/curl, net-analyzer/tcpdump
    ("sys-", "application"),    # sys-apps/util-linux, sys-process/procps
    ("www-", "application"),
    ("mail-", "application"),
    ("x11-", "application"),
    ("media-", "application"),
    ("games-", "application"),
]


def get_component_type(name: str) -> str:
    """Map a Portage package name (with optional category) to a CycloneDX component type."""
    for prefix, ctype in _CATEGORY_TYPE_RULES:
        if name.startswith(prefix):
            return ctype
    return "library"  # safe default


def _to_spdx_expr_tokens(raw: str, gentoo_to_spdx: dict) -> str:
    """
    Map each license token in a compound expression string to its SPDX equivalent,
    leaving boolean operators and parentheses unchanged.

    Syft converts Portage's || ( A B ) syntax to "A OR B" form, so by the time
    this runs the operators are already AND / OR, with parentheses possibly attached
    to adjacent tokens (e.g. "(GPL-2+" or "CC-BY-SA-4.0)").
    """
    _OPERATORS = {"AND", "OR"}
    parts = []
    for token in raw.split():
        # Peel off leading '(' and trailing ')' — keep them glued to the token
        prefix = ""
        while token.startswith("("):
            prefix += "("
            token = token[1:]
        suffix = ""
        while token.endswith(")"):
            suffix = ")" + suffix
            token = token[:-1]
        mapped = token if token in _OPERATORS else gentoo_to_spdx.get(token, token)
        parts.append(f"{prefix}{mapped}{suffix}")
    return " ".join(parts)


def normalize_license_entry(entry: dict, gentoo_to_spdx: dict) -> dict:
    """
    Normalize a single CycloneDX license entry.

    CycloneDX license entries look like:
      {"license": {"id": "MIT"}}                  — already SPDX, leave alone
      {"license": {"name": "GPL-2+"}}             — single Gentoo name → map to id
      {"license": {"name": "MIT AND Apache-2.0"}} — compound → {"expression": "..."}

    Returns the (possibly updated) entry.
    """
    lic = entry.get("license", {})
    name = lic.get("name", "")
    if "id" in lic or not name:
        return entry  # already SPDX id, or no name to normalize

    if " " not in name:
        # Single token: direct SPDX mapping
        mapped = gentoo_to_spdx.get(name)
        if mapped:
            return {"license": {"id": mapped}}
        return entry  # non-SPDX single name (e.g. BZIP2, Toyoda) — keep as-is

    # Compound expression (contains spaces / boolean operators):
    # map each token and emit as a CycloneDX SPDX expression object.
    return {"expression": _to_spdx_expr_tokens(name, gentoo_to_spdx)}


def add_purl_qualifiers(purl: str, arch: str) -> str:
    """Add ?arch=...&distro=gentoo qualifiers to a pkg:ebuild/ PURL if not already present."""
    if not purl or not purl.startswith("pkg:ebuild/"):
        return purl
    if "?" in purl:
        return purl  # already has qualifiers
    return f"{purl}?arch={arch}&distro=gentoo"


def build_dependency_graph(sysroot: str, bom_ref_by_bare: dict) -> list:
    """
    Build a CycloneDX dependencies array by reading Portage RDEPEND files.

    Reads /var/db/pkg/category/package-version/RDEPEND for each installed package
    and extracts bare package atom references.  Matching is best-effort:
    atoms that don't resolve to a component in the SBOM are silently skipped
    (this covers virtuals, build-only deps like sys-devel/gcc, etc.).

    Returns a list of {"ref": bom_ref, "dependsOn": [bom_ref, ...]} dicts.
    """
    vdb = Path(sysroot) / "var" / "db" / "pkg"
    if not vdb.is_dir():
        print(
            f"[enrich-sbom] WARNING: /var/db/pkg not found at {sysroot} — skipping dep graph",
            file=sys.stderr,
        )
        return []

    # Regex to extract bare category/package atoms from RDEPEND content.
    # Matches atoms like: app-shells/bash, dev-libs/openssl, >=sys-libs/musl-1.2
    # Strips leading version operators and comparison characters.
    _ATOM_RE = re.compile(r"(?:>=?|<=?|~|=|!)?([a-z][a-z0-9_-]*/[a-zA-Z0-9_+.-]+)")

    deps = []
    pkg_count = 0
    matched_count = 0
    rdepend_count = 0

    for pkg_dir in sorted(vdb.glob("*/*")):
        if not pkg_dir.is_dir():
            continue
        pkg_count += 1
        category = pkg_dir.parent.name
        pkg_ver = pkg_dir.name  # e.g. "bash-5.2_p21-r1"
        this_bare = bare_name(f"{category}/{pkg_ver}")

        if this_bare not in bom_ref_by_bare:
            continue
        matched_count += 1

        ref = bom_ref_by_bare[this_bare]
        depends_on = []

        for dep_file in ("RDEPEND", "DEPEND"):
            rdep_path = pkg_dir / dep_file
            if not rdep_path.exists():
                continue
            rdepend_count += 1
            try:
                content = rdep_path.read_text(errors="replace")
            except OSError:
                continue

            for match in _ATOM_RE.finditer(content):
                atom = match.group(1)
                # Skip slot/use suffixes (e.g. "bash:0" → "bash")
                atom = atom.split(":")[0]
                dep_bare = bare_name(atom)
                if dep_bare in bom_ref_by_bare and dep_bare != this_bare:
                    dep_ref = bom_ref_by_bare[dep_bare]
                    if dep_ref not in depends_on:
                        depends_on.append(dep_ref)

        deps.append({"ref": ref, "dependsOn": depends_on})

    print(
        f"[enrich-sbom] dep graph: vdb_dirs={pkg_count}, matched_to_sbom={matched_count}, "
        f"dep_files_read={rdepend_count}, entries_built={len(deps)}",
        file=sys.stderr,
    )
    return deps


def sha256_file(path: Path) -> str:
    """Return the SHA-256 hex digest of a file, or '' if it can't be read."""
    try:
        h = hashlib.sha256()
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(65536), b""):
                h.update(chunk)
        return h.hexdigest()
    except OSError:
        return ""


def extract_dist_sha512(manifest_path: Path, name_prefix: str, version_hint: str = "") -> tuple:
    """
    Extract a distfile SHA-512 from a Portage Manifest file.

    Portage "thin" Manifests contain lines of the form:
        DIST <filename> <size> BLAKE2B <hex> SHA512 <hex>

    Returns (filename, sha512_hex) for the first DIST entry whose filename starts
    with name_prefix and (if version_hint given) contains that substring. Returns
    ("", "") if the file is missing, unreadable, or no matching entry is found —
    never fabricates a hash.
    """
    try:
        content = manifest_path.read_text(errors="replace")
    except OSError:
        return "", ""
    pattern = re.compile(
        rf"DIST\s+({re.escape(name_prefix)}\S+)\s+\d+\s+BLAKE2B\s+\S+\s+SHA512\s+(\S+)"
    )
    for m in pattern.finditer(content):
        fname, sha512 = m.group(1), m.group(2)
        if not version_hint or version_hint in fname:
            return fname, sha512
    return "", ""


def parse_upstream_maintainers(metadata_xml_path: Path) -> list:
    """
    Parse a Portage metadata.xml and return the upstream project's maintainer(s)
    (the <upstream><maintainer> block — the people who author the software
    upstream) as CycloneDX organizationalContact entries.

    Deliberately distinct from the top-level <maintainer> element, which
    identifies the Gentoo packager/proxy-maintainer, not the upstream author.

    Returns [] if the file is missing, unparsable, or has no <upstream> block —
    never fabricates authorship.
    """
    try:
        tree = ET.parse(metadata_xml_path)
    except (ET.ParseError, OSError):
        return []
    authors = []
    for upstream in tree.getroot().findall("upstream"):
        for maint in upstream.findall("maintainer"):
            name_el = maint.find("name")
            email_el = maint.find("email")
            name = (name_el.text or "").strip() if name_el is not None else ""
            email = (email_el.text or "").strip() if email_el is not None else ""
            if not name and not email:
                continue
            contact = {}
            if name:
                contact["name"] = name
            if email:
                contact["email"] = email
            if contact not in authors:
                authors.append(contact)
    return authors


def read_vdb_homepage(vdb_pkg_dir: Path) -> str:
    """
    Read the first URL from a Portage vdb package directory's HOMEPAGE file.

    HOMEPAGE may list multiple space-separated URLs; only the first is used.
    Returns '' if the file is absent/empty — never fabricates a URL.
    """
    homepage_file = vdb_pkg_dir / "HOMEPAGE"
    try:
        content = homepage_file.read_text(errors="replace").strip()
    except OSError:
        return ""
    if not content:
        return ""
    return content.split()[0]


def _run_version(cmd: list[str]) -> str:
    """Run a command and return its first output line, or '' on any failure."""
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
        return (r.stdout or r.stderr or "").splitlines()[0].strip()
    except Exception:
        return ""


def _extract_version(raw: str) -> str:
    """Pull the first X.Y[.Z…] version number out of a raw version string."""
    m = re.search(r"(\d+\.\d+[\d.]*)", raw or "")
    return m.group(1) if m else raw


def enrich(sbom: dict, overrides: dict, args: argparse.Namespace) -> tuple:
    """
    Apply all SBOM enrichments.

    Returns:
        (enriched_sbom, enriched_names, no_cpe_names)
    """
    enriched_names = []
    no_cpe_names = []

    metadata = sbom.setdefault("metadata", {})

    # ── specVersion floor ──────────────────────────────────────────────────────
    # formulation and externalReference.hashes need CycloneDX 1.5+; per-component
    # `authors` (plural, array of organizationalContact — used for upstream
    # authorship below) is 1.6+. Bump the spec version if Syft emitted something
    # older; never downgrade a newer version Syft may already be emitting.
    try:
        _spec_ver = float(sbom.get("specVersion", "0") or "0")
    except ValueError:
        _spec_ver = 0.0
    if _spec_ver < 1.6:
        sbom["specVersion"] = "1.6"

    # Captured here so the dependency-graph section (below) can attach a root
    # entry — {"ref": product_bom_ref, "dependsOn": [...world packages...]} —
    # to the same bom-ref used for metadata.component.
    product_bom_ref = None

    # ── Fix metadata.component ─────────────────────────────────────────────────
    if args.product_name:
        build_tag = args.build_tag or "unknown"
        product_bom_ref = f"{args.product_name}-{build_tag}"
        component_entry = {
            "type": "operating-system",
            "bom-ref": product_bom_ref,
            "name": args.product_name,
            "version": build_tag,
            "supplier": {"name": "Tucker McLean"},
            "description": "The Monolith — statically-linked musl/Gentoo live ISO",
            # Declare the project's own license so the top-level component is
            # not reported as UNKNOWN by downstream SBOM consumers.
            "licenses": [{"license": {"id": "MIT"}}],
        }

        iso_sha = getattr(args, "iso_sha256", "")
        has_iso_sha = bool(iso_sha) and iso_sha != "(not computed)"
        repo_url = args.repo_url.rstrip("/") if args.repo_url else ""

        # externalReferences: vcs (exact commit), build-system (CI run that
        # produced this SBOM), distribution (where the ISO artifact lives).
        ext_refs = []
        if args.git_sha and repo_url:
            ext_refs.append({
                "type": "vcs",
                "url": f"{repo_url}/commit/{args.git_sha}",
            })
        if repo_url and args.run_id:
            ext_refs.append({
                "type": "build-system",
                "url": f"{repo_url}/actions/runs/{args.run_id}",
            })
        if args.distribution_url:
            dist_ref = {"type": "distribution", "url": args.distribution_url}
            if has_iso_sha:
                dist_ref["hashes"] = [{"alg": "SHA-256", "content": iso_sha}]
            ext_refs.append(dist_ref)
        # A second "distribution" reference pointing at the GitHub Release asset.
        # CycloneDX permits repeated externalReferences of the same type, so this
        # sits alongside (not instead of) the S3 --distribution-url entry above —
        # both point at byte-identical copies of the same ISO, so both carry the
        # same --iso-sha256 hash. The URL is computed by the caller (scripts/
        # attestation.sh) from the tag name BEFORE the release is created — GitHub
        # release asset download URLs are deterministic
        # (.../releases/download/<tag>/<asset-name>), so no ordering dependency
        # on the actual `gh release create` call is introduced, and the digest
        # this SBOM embeds is never at risk of drifting from the asset it names.
        if args.release_url:
            release_ref = {"type": "distribution", "url": args.release_url}
            if has_iso_sha:
                release_ref["hashes"] = [{"alg": "SHA-256", "content": iso_sha}]
            ext_refs.append(release_ref)
        if ext_refs:
            component_entry["externalReferences"] = ext_refs

        if has_iso_sha:
            component_entry["hashes"] = [{"alg": "SHA-256", "content": iso_sha}]
        metadata["component"] = component_entry
        # Remove Syft's auto-detected OS distro component — identified by its
        # syft:distro:* properties, which appear when Syft reads /etc/os-release.
        # This component is superseded by the explicit metadata.component above.
        sbom["components"] = [
            c for c in sbom.get("components", [])
            if not any(
                p.get("name", "").startswith("syft:distro:")
                for p in (c.get("properties") or [])
            )
        ]

    # ── metadata.authors and lifecycles ───────────────────────────────────────
    metadata["authors"] = [{"name": "Tucker McLean"}]
    metadata["lifecycles"] = [{"phase": "build"}]

    # ── Load Gentoo→SPDX license mapping ──────────────────────────────────────
    gentoo_to_spdx = {}
    if args.license_policy:
        policy_path = Path(args.license_policy)
        if policy_path.exists():
            policy_data = load_yaml_simple(args.license_policy)
            gentoo_to_spdx = policy_data.get("gentoo_to_spdx", {})
        else:
            print(
                f"[enrich-sbom] WARNING: license policy not found at {args.license_policy} — "
                "skipping license normalization",
                file=sys.stderr,
            )

    # ── Remove binary-cataloger duplicates of portage-cataloger entries ──────
    # Syft's binary-cataloger emits bare-name entries (no "/" in name) for ELF
    # binaries it finds on disk — e.g. "busybox 1.36.1" alongside the authoritative
    # "sys-apps/busybox 1.36.1-r4" from the portage-cataloger. Keep the portage
    # entry; it has the correct category, purl, licenses, and version.
    # Also drop components with shell-quoted names — Syft's portage cataloger
    # occasionally emits parse artifacts like "'gentoo'" / "'2.18'" from metadata files.
    portage_bare = {
        bare_name(c.get("name", ""))
        for c in sbom.get("components", [])
        if "/" in c.get("name", "")
        and not c.get("name", "").startswith(("'", '"'))
    }
    sbom["components"] = [
        c for c in sbom.get("components", [])
        if not c.get("name", "").startswith(("'", '"'))
        and ("/" in c.get("name", "") or bare_name(c.get("name", "")) not in portage_bare)
    ]

    # ── Ensure every component has a bom-ref (required for dep graph) ─────────
    seen_refs = set()
    for i, component in enumerate(sbom.get("components", [])):
        if not component.get("bom-ref"):
            name = component.get("name", f"component-{i}")
            ver = component.get("version", "")
            candidate = f"{name}-{ver}" if ver else name
            # De-duplicate if needed
            ref = candidate
            suffix = 1
            while ref in seen_refs:
                ref = f"{candidate}-{suffix}"
                suffix += 1
            component["bom-ref"] = ref
        seen_refs.add(component["bom-ref"])

    # Build bare_name → bom-ref lookup for dependency resolution
    bom_ref_by_bare = {}
    for component in sbom.get("components", []):
        if component.get("type") != "file":
            key = bare_name(component.get("name", ""))
            if key and key not in bom_ref_by_bare:
                bom_ref_by_bare[key] = component["bom-ref"]

    # Categories that are Portage-internal stubs with no upstream NVD presence.
    # Must be checked BEFORE override lookup because bare_name() strips the
    # category — "app-alternatives/bzip2" → "bzip2" would otherwise hit the
    # real bzip2 CPE override and produce a nonsense version-1 CPE.
    # acct-group/shadow bare_name → "shadow" hits the shadow override and
    # produces shadow-utils:0 (version "0" is Portage's revision counter).
    _NO_CPE_CATEGORIES = ("acct-group/", "acct-user/", "app-alternatives/", "virtual/")

    # ── Process each package component ────────────────────────────────────────
    components = [c for c in sbom.get("components", []) if c.get("type") != "file"]
    for component in components:
        name = component.get("name", "")
        version = component.get("version", "")
        key = bare_name(name)

        # ── CPE override or synthetic CPE removal ─────────────────────────────
        if any(name.startswith(cat) for cat in _NO_CPE_CATEGORIES):
            # Portage-internal virtual/alternatives stubs — no NVD entry exists.
            # Strip any Syft-generated CPE and skip the override table entirely.
            component.pop("cpe", None)
        elif key in overrides:
            template = overrides[key]
            cpe = apply_version_to_cpe(template, version)
            component["cpe"] = cpe
            enriched_names.append(name)
        elif component.get("cpe") and is_synthetic_cpe(component["cpe"]):
            # Syft generated a bad Portage-slug CPE — strip it so Grype doesn't
            # try (and fail) to match it against NVD
            del component["cpe"]

        # ── Track CPE gaps ────────────────────────────────────────────────────
        if not component.get("cpe"):
            no_cpe_names.append((name, version))

        # ── Strip noisy syft:cpe23 property duplicates ────────────────────────
        if "properties" in component:
            filtered = [
                p for p in component["properties"]
                if not p.get("name", "").startswith("syft:cpe23")
            ]
            if filtered:
                component["properties"] = filtered
            else:
                del component["properties"]

        # ── Supplier ──────────────────────────────────────────────────────────
        # supplier stays "Gentoo Linux" — the distributor that packaged and
        # patched this build. publisher/author (below) is the upstream project,
        # kept distinct so downstream consumers don't lose upstream authorship
        # just because every package flows through the same distributor.
        component.setdefault("supplier", {"name": "Gentoo Linux"})

        # ── Publisher/author split (upstream project, best-effort) ───────────
        # metadata.xml's <upstream><maintainer> names the upstream project's
        # author(s) — distinct from the top-level <maintainer>, which is the
        # Gentoo packager. HOMEPAGE (from the vdb) is recorded as a "website"
        # externalReference. Both are best-effort: left absent when the
        # Portage tree/vdb doesn't provide them. Never fabricated.
        if "/" in name:
            category, pkg_short = name.split("/", 1)

            if args.portage_tree:
                upstream_authors = parse_upstream_maintainers(
                    Path(args.portage_tree) / category / pkg_short / "metadata.xml"
                )
                if upstream_authors:
                    component["authors"] = upstream_authors

            if args.sysroot and version:
                vdb_pkg_dir = Path(args.sysroot) / "var" / "db" / "pkg" / category / f"{pkg_short}-{version}"
                homepage = read_vdb_homepage(vdb_pkg_dir)
                if homepage:
                    ext = component.setdefault("externalReferences", [])
                    if not any(r.get("url") == homepage for r in ext):
                        ext.append({"type": "website", "url": homepage})

        # ── Component type reclassification ───────────────────────────────────
        # Syft defaults all Portage packages to "library" — reclassify by category
        if component.get("type") == "library":
            component["type"] = get_component_type(name)

        # ── PURL arch/distro qualifiers ───────────────────────────────────────
        if args.arch and component.get("purl"):
            component["purl"] = add_purl_qualifiers(component["purl"], args.arch)

        # ── License normalization ─────────────────────────────────────────────
        if gentoo_to_spdx and component.get("licenses"):
            component["licenses"] = [
                normalize_license_entry(le, gentoo_to_spdx)
                for le in component["licenses"]
            ]

    # ── Dependency graph ───────────────────────────────────────────────────────
    if args.sysroot:
        print("[enrich-sbom] Building dependency graph from Portage vdb...", file=sys.stderr)
        deps = build_dependency_graph(args.sysroot, bom_ref_by_bare)

        # Root the graph at the product component: dependsOn = the packages the
        # world file names directly (configs/portage/world) as opposed to the
        # transitive deps RDEPEND/DEPEND already captured above. Without this,
        # the graph is a forest with no single root a consumer can walk from
        # the ISO itself. Best-effort: only added when both the product
        # bom-ref and world atoms are available and resolve to real components.
        if product_bom_ref and args.world:
            world_path = Path(args.world)
            if world_path.exists():
                root_deps = []
                for line in world_path.read_text().splitlines():
                    atom = line.split("#", 1)[0].strip()
                    if not atom:
                        continue
                    atom = re.sub(r"^[><=~!]+", "", atom).split(":")[0]
                    ref = bom_ref_by_bare.get(bare_name(atom))
                    if ref and ref not in root_deps:
                        root_deps.append(ref)
                if root_deps:
                    deps.insert(0, {"ref": product_bom_ref, "dependsOn": root_deps})
                    print(
                        f"[enrich-sbom] Dependency graph: rooted at {product_bom_ref} "
                        f"with {len(root_deps)} world package(s).",
                        file=sys.stderr,
                    )

        if deps:
            sbom["dependencies"] = deps
            print(
                f"[enrich-sbom] Dependency graph: {len(deps)} entries built.",
                file=sys.stderr,
            )
        else:
            print("[enrich-sbom] WARNING: No dependency entries built.", file=sys.stderr)

    # ── Propagate builder components embedded in the ISO ─────────────────────
    # musl is statically linked into every target binary; GRUB and syslinux/isolinux
    # have binary bits embedded in the ISO boot area. None appear in the sysroot
    # portage DB, but all need to be in the target SBOM for license and CVE coverage.
    if args.host_vdb:
        _PROPAGATE = [
            ("cross-i486-linux-musl", "musl"),    # static libc
            ("sys-boot",              "grub"),     # GRUB EFI/BIOS core
            ("sys-boot",              "syslinux"), # isolinux.bin
        ]
        _existing_names = {c.get("name", "") for c in components}
        _host_vdb = Path(args.host_vdb)
        for _cat, _pkg in _PROPAGATE:
            if _pkg in _existing_names:
                continue
            # Filter to dirs where the version field starts with a digit — this
            # excludes sibling packages like grub-themes-gentoo that share the prefix.
            _matches = sorted(
                d for d in _host_vdb.glob(f"{_cat}/{_pkg}-*/")
                if re.match(rf"{re.escape(_pkg)}-\d", d.name)
            )
            if not _matches:
                continue
            _pkg_dir = _matches[-1]
            _pvr_file = _pkg_dir / "PVR"
            _ver_raw = _pvr_file.read_text().strip() if _pvr_file.exists() else _pkg_dir.name
            _ver_raw = re.sub(rf"^{re.escape(_pkg)}-", "", _ver_raw)
            _version = strip_gentoo_suffixes(_ver_raw)
            if not _version:
                continue
            _cpe_template = overrides.get(_pkg, "")
            _license_file = _pkg_dir / "LICENSE"
            _license_raw = _license_file.read_text().strip() if _license_file.exists() else ""
            _comp: dict = {
                "type": "library",
                "name": _pkg,
                "version": _version,
                "bom-ref": f"propagated-{_pkg}-{_version}",
                "supplier": {"name": "Gentoo"},
                "properties": [
                    {"name": "syft:package:foundBy",    "value": "host-vdb-propagate"},
                    {"name": "syft:monolith:source",    "value": "builder"},
                    {"name": "syft:package:type",       "value": "portage"},
                ],
            }
            if _license_raw:
                _comp["licenses"] = [{"expression": _license_raw}]
            if _cpe_template:
                _comp["cpe"] = apply_version_to_cpe(_cpe_template, _version)
            else:
                no_cpe_names.append((_pkg, _version))
            sbom["components"].append(_comp)
            print(f"[enrich-sbom] Propagated from builder: {_pkg} {_version}", file=sys.stderr)

    # ── Formulation: build inputs (CycloneDX 1.5+) ────────────────────────────
    # Captures the external inputs that determined the ISO's contents, as
    # transient pseudo-components under formulation[0].components, plus a
    # pointer to the exact workflow file/commit/run under formulation[0].properties.
    # Everything here is either read directly from a file in the repo/build
    # context or passed in from a value the caller (attestation.sh) already
    # computed on the host — nothing is guessed or fabricated. Any input that
    # can't be resolved is silently omitted rather than filled with a placeholder.
    _formula_components: list[dict] = []

    # Docker base image (Gentoo stage3) — the toolchain bootstrap layer.
    if args.stage3_epoch:
        _stage3_entry: dict = {
            "type": "container",
            "name": "gentoo/stage3",
            "version": f"amd64-openrc-{args.stage3_epoch}",
            "purl": f"pkg:docker/gentoo/stage3@amd64-openrc-{args.stage3_epoch}",
        }
        if args.stage3_digest:
            _stage3_entry["hashes"] = [{
                "alg": "SHA-256",
                "content": args.stage3_digest.removeprefix("sha256:"),
            }]
        _formula_components.append(_stage3_entry)

    # versions.lock — pins every world package's exact version; hashed directly
    # since it's a file already present in this checkout.
    if args.versions_lock:
        _vl_path = Path(args.versions_lock)
        if _vl_path.exists():
            _vl_digest = sha256_file(_vl_path)
            if _vl_digest:
                _formula_components.append({
                    "type": "data",
                    "name": "versions.lock",
                    "hashes": [{"alg": "SHA-256", "content": _vl_digest}],
                })

    # Kernel source tarball — digest read from the overlay ebuild's Manifest
    # (Gentoo Manifests are Gemini/GPG-signed at sync time), matched to the
    # actual installed kernel version so the recorded hash is never stale.
    if args.kernel_manifest:
        _kernel_component = next(
            (c for c in components if bare_name(c.get("name", "")) == "monolith-kernel"),
            None,
        )
        if _kernel_component:
            _kver = strip_gentoo_suffixes(_kernel_component.get("version", ""))
            _kfname, _ksha512 = extract_dist_sha512(Path(args.kernel_manifest), "linux-", _kver)
            if _kfname and _ksha512:
                _formula_components.append({
                    "type": "file",
                    "name": _kfname,
                    "hashes": [{"alg": "SHA-512", "content": _ksha512}],
                })

    # BusyBox source tarball — same approach, read from the main Gentoo tree's
    # Manifest (not the overlay; BusyBox is a stock Gentoo ebuild).
    if args.portage_tree:
        _busybox_component = next(
            (c for c in components if bare_name(c.get("name", "")) == "busybox"),
            None,
        )
        if _busybox_component:
            _bver = strip_gentoo_suffixes(_busybox_component.get("version", ""))
            _bb_manifest = Path(args.portage_tree) / "sys-apps" / "busybox" / "Manifest"
            _bfname, _bsha512 = extract_dist_sha512(_bb_manifest, "busybox-", _bver)
            if _bfname and _bsha512:
                _formula_components.append({
                    "type": "file",
                    "name": _bfname,
                    "hashes": [{"alg": "SHA-512", "content": _bsha512}],
                })

    _formula_properties: list[dict] = []
    if args.workflow_path:
        _formula_properties.append({"name": "monolith:workflow:path", "value": args.workflow_path})
    if args.git_sha:
        _formula_properties.append({"name": "monolith:workflow:commit", "value": args.git_sha})
    if args.run_id:
        _formula_properties.append({"name": "monolith:workflow:run_id", "value": args.run_id})

    if _formula_components or _formula_properties:
        _formula: dict = {"bom-ref": "monolith-build-formula"}
        if _formula_components:
            _formula["components"] = _formula_components
        if _formula_properties:
            _formula["properties"] = _formula_properties
        sbom["formulation"] = [_formula]
        print(
            f"[enrich-sbom] Formulation: {len(_formula_components)} build input(s) recorded.",
            file=sys.stderr,
        )

    # ── Populate metadata.tools (CycloneDX 1.5+ dict form) ───────────────────
    # Normalise whatever Syft wrote (array in 1.4, dict in 1.5+) into the
    # canonical 1.6 shape: {"components": [...]}.
    tools_raw = metadata.get("tools")
    if isinstance(tools_raw, list):
        existing = tools_raw          # CycloneDX 1.4: plain array
    elif isinstance(tools_raw, dict):
        existing = tools_raw.get("components", [])
    else:
        existing = []
    _MANAGED_TOOLS = {
        "syft", "grype", "enrich-sbom.py",
        "i486-linux-musl-gcc", "i486-linux-musl-ld",
        "gcc", "portage", "crossdev",
    }
    existing = [t for t in existing if t.get("name") not in _MANAGED_TOOLS]

    # ── Capture build toolchain versions (fail-silent for each) ──────────────
    toolchain: list[dict] = []

    _xgcc_raw = _run_version(["i486-linux-musl-gcc", "--version"])
    if _xgcc_raw:
        toolchain.append({
            "type": "application",
            "name": "i486-linux-musl-gcc",
            "version": _extract_version(_xgcc_raw),
            "description": _xgcc_raw,
        })

    _xld_raw = _run_version(["i486-linux-musl-ld", "--version"])
    if _xld_raw:
        toolchain.append({
            "type": "application",
            "name": "i486-linux-musl-ld",
            "version": _extract_version(_xld_raw),
            "description": _xld_raw,
        })

    _gcc_raw = _run_version(["gcc", "--version"])
    if _gcc_raw:
        toolchain.append({
            "type": "application",
            "name": "gcc",
            "version": _extract_version(_gcc_raw),
            "description": _gcc_raw,
        })

    _portage_raw = _run_version(["portageq", "--version"]) or _run_version(["emerge", "--version"])
    if _portage_raw:
        toolchain.append({
            "type": "application",
            "name": "portage",
            "version": _extract_version(_portage_raw),
            "description": _portage_raw,
        })

    _crossdev_raw = _run_version(["crossdev", "--version"])
    if _crossdev_raw:
        toolchain.append({
            "type": "application",
            "name": "crossdev",
            "version": _extract_version(_crossdev_raw),
            "description": _crossdev_raw,
        })

    new_tools: list[dict] = []
    if args.syft_version:
        new_tools.append({
            "type": "application",
            "name": "syft",
            "version": args.syft_version,
            "supplier": {"name": "Anchore"},
            "externalReferences": [{"type": "website",
                                    "url": "https://github.com/anchore/syft"}],
        })
    if args.grype_version:
        grype_props = []
        if args.grype_db_built:
            grype_props.append({"name": "cdx:tool:db:built",
                                "value": args.grype_db_built})
        if args.grype_db_schema:
            grype_props.append({"name": "cdx:tool:db:schema",
                                "value": args.grype_db_schema})
        if args.grype_db_checksum:
            grype_props.append({"name": "cdx:tool:db:checksum",
                                "value": args.grype_db_checksum})
        grype_entry: dict = {
            "type": "application",
            "name": "grype",
            "version": args.grype_version,
            "supplier": {"name": "Anchore"},
            "externalReferences": [{"type": "website",
                                    "url": "https://github.com/anchore/grype"}],
        }
        if grype_props:
            grype_entry["properties"] = grype_props
        new_tools.append(grype_entry)
    new_tools.append({
        "type": "application",
        "name": "enrich-sbom.py",
        "version": "2.0",
        "supplier": {"name": "Tucker McLean"},
    })
    metadata["tools"] = {"components": existing + toolchain + new_tools}

    return sbom, enriched_names, no_cpe_names


def main():
    parser = argparse.ArgumentParser(
        description="Apply CPE overrides and SBOM quality fixes to a Syft CycloneDX SBOM.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s --sbom attestation/sbom.cdx.json \\
           --overrides config/cpe-overrides.yaml \\
           --output attestation/bom.cdx.json \\
           --product-name themonolith \\
           --build-tag YYYYMMDD-<sha> \\
           --git-sha <sha> \\
           --arch x86_64 \\
           --sysroot /output/sysroot \\
           --license-policy config/license-policy.yaml

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
    # ── New optional enrichment args ─────────────────────────────────────────
    parser.add_argument(
        "--iso-sha256",
        metavar="HEX",
        default="",
        help="SHA-256 digest of the ISO artifact — written to metadata.component.hashes",
    )
    parser.add_argument(
        "--product-name",
        metavar="STR",
        default="",
        help="Product name for metadata.component (e.g. 'themonolith')",
    )
    parser.add_argument(
        "--build-tag",
        metavar="STR",
        default="",
        help="Build version string for metadata.component (e.g. '20260406-9a8504e')",
    )
    parser.add_argument(
        "--git-sha",
        metavar="SHA",
        default="",
        help="Git commit SHA for metadata.component.externalReferences VCS link",
    )
    parser.add_argument(
        "--repo-url",
        metavar="URL",
        default="",
        help="Repository base URL (e.g. 'https://github.com/user/repo') for VCS externalReference",
    )
    parser.add_argument(
        "--arch",
        metavar="STR",
        default="",
        help="Target architecture for PURL qualifiers (e.g. 'x86_64')",
    )
    parser.add_argument(
        "--sysroot",
        metavar="PATH",
        default="",
        help="Path to extracted sysroot containing /var/db/pkg (for dependency graph)",
    )
    parser.add_argument(
        "--license-policy",
        metavar="PATH",
        default="",
        help="Path to license-policy.yaml (for Gentoo→SPDX license normalization)",
    )
    # ── Scanner tool metadata (written into metadata.tools) ──────────────────
    parser.add_argument("--syft-version",       metavar="VER", default="",
                        help="Syft version string for metadata.tools")
    parser.add_argument("--grype-version",      metavar="VER", default="",
                        help="Grype version string for metadata.tools")
    parser.add_argument("--grype-db-built",     metavar="TS",  default="",
                        help="Grype vulnerability DB build timestamp")
    parser.add_argument("--grype-db-schema",    metavar="VER", default="",
                        help="Grype vulnerability DB schema version")
    parser.add_argument("--grype-db-checksum",  metavar="SUM", default="",
                        help="Grype vulnerability DB checksum")
    parser.add_argument(
        "--host-vdb",
        metavar="PATH",
        default="",
        help="Path to host Portage VDB (e.g. /var/db/pkg) for propagating builder components "
             "that are embedded in the ISO but absent from the sysroot portage DB",
    )
    parser.add_argument(
        "--cpe-exclusions",
        metavar="PATH",
        default="",
        help="YAML file declaring package patterns excluded from CPE/CVE scanning "
             "(e.g. acct-group/*, virtual/*); excluded packages are not counted as gaps",
    )
    # ── SBOM completeness: CI pointer, distribution, formulation, authorship ──
    parser.add_argument(
        "--run-id",
        metavar="ID",
        default="",
        help="GitHub Actions run ID ($GITHUB_RUN_ID) — used to build the "
             "build-system externalReference and recorded in formulation.properties",
    )
    parser.add_argument(
        "--distribution-url",
        metavar="URL",
        default="",
        help="URL where the ISO artifact is published (e.g. an s3:// URI) — "
             "written as a 'distribution' externalReference on metadata.component, "
             "with the ISO's SHA-256 attached via --iso-sha256",
    )
    parser.add_argument(
        "--release-url",
        metavar="URL",
        default="",
        help="URL of the GitHub Release asset for this ISO (e.g. "
             "https://github.com/<owner>/<repo>/releases/download/<tag>/<name>.iso) — "
             "written as a second 'distribution' externalReference alongside "
             "--distribution-url, with the same --iso-sha256 hash attached. Only "
             "set on tag builds; omitted (not fabricated) otherwise.",
    )
    parser.add_argument(
        "--world",
        metavar="PATH",
        default="",
        help="Path to configs/portage/world — used to root the dependency graph "
             "at metadata.component, with dependsOn = the world-file packages",
    )
    parser.add_argument(
        "--portage-tree",
        metavar="PATH",
        default="",
        help="Path to the main Gentoo portage tree (e.g. /var/db/repos/gentoo) — "
             "used to read metadata.xml (upstream author) and the BusyBox Manifest "
             "(formulation build input) for each package",
    )
    parser.add_argument(
        "--versions-lock",
        metavar="PATH",
        default="",
        help="Path to configs/portage/versions.lock — hashed and recorded as a "
             "formulation build input",
    )
    parser.add_argument(
        "--kernel-manifest",
        metavar="PATH",
        default="",
        help="Path to the monolith-kernel overlay ebuild's Manifest — the kernel "
             "source tarball's SHA-512 is read from here for formulation",
    )
    parser.add_argument(
        "--stage3-epoch",
        metavar="EPOCH",
        default="",
        help="BUILD_EPOCH used for the gentoo/stage3 Docker base image (formulation)",
    )
    parser.add_argument(
        "--stage3-digest",
        metavar="SHA256",
        default="",
        help="Docker manifest digest of the stage3 base image (formulation)",
    )
    parser.add_argument(
        "--workflow-path",
        metavar="PATH",
        default=".github/workflows/build.yml",
        help="Repo-relative path to the CI workflow file (formulation.properties)",
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

    cpe_exclusions = []
    if args.cpe_exclusions and Path(args.cpe_exclusions).exists():
        cpe_exclusions = load_yaml_simple(args.cpe_exclusions).get("exclusions", [])

    with open(sbom_path) as f:
        sbom = json.load(f)

    # Enrich
    enriched_sbom, enriched_names, no_cpe_names = enrich(sbom, overrides, args)

    total_components = len(sbom.get("components", []))
    total_packages = sum(1 for c in sbom.get("components", []) if c.get("type") != "file")
    print(
        f"[enrich-sbom] Processed {total_packages} packages "
        f"({total_components - total_packages} file-type components skipped); "
        f"applied {len(enriched_names)} CPE override(s).",
        file=sys.stderr,
    )

    # Split gaps into policy-excluded (informational) vs genuine (need attention)
    import fnmatch as _fnmatch
    excluded_gaps = []  # (name, version, rule)
    genuine_gaps  = []  # (name, version)
    for _name, _ver in no_cpe_names:
        _rule = next(
            (r for r in cpe_exclusions if _fnmatch.fnmatch(_name, r["pattern"])),
            None,
        )
        if _rule:
            excluded_gaps.append((_name, _ver, _rule))
        else:
            genuine_gaps.append((_name, _ver))

    if genuine_gaps:
        print(
            f"[enrich-sbom] CPE GAPS ({len(genuine_gaps)} packages with no CPE — "
            "Grype cannot scan these):",
            file=sys.stderr,
        )
        for _name, _ver in sorted(genuine_gaps):
            _ver_str = f" ({_ver})" if _ver else ""
            print(f"  - {_name}{_ver_str}", file=sys.stderr)
    else:
        print("[enrich-sbom] No CPE gaps — all packages have CPE mappings.", file=sys.stderr)

    if excluded_gaps:
        print(
            f"[enrich-sbom] CPE EXCLUSIONS ({len(excluded_gaps)} packages excluded by policy — "
            "not counted as gaps):",
            file=sys.stderr,
        )
        for _name, _ver, _ in sorted(excluded_gaps):
            print(f"  - {_name}", file=sys.stderr)

    # Write enriched SBOM
    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with open(out_path, "w") as f:
        json.dump(enriched_sbom, f, indent=2)
        f.write("\n")

    print(f"[enrich-sbom] Enriched SBOM written to {args.output}", file=sys.stderr)

    # Genuine gap count — used by attestation.sh for the summary
    (out_path.parent / "cpe-gap-count.txt").write_text(str(len(genuine_gaps)) + "\n")

    # Excluded count and structured report — read by attestation.sh and dashboard
    (out_path.parent / "cpe-exclusions-count.txt").write_text(str(len(excluded_gaps)) + "\n")

    from datetime import datetime, timezone as _tz
    _excl_report = {
        "build_tag": getattr(args, "build_tag", ""),
        "timestamp": datetime.now(_tz.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "excluded_count": len(excluded_gaps),
        "genuine_gap_count": len(genuine_gaps),
        "exclusions": [
            {
                "name": n, "version": v,
                "pattern": r["pattern"],
                "justification": r["justification"],
                "detail": r.get("detail", ""),
            }
            for n, v, r in sorted(excluded_gaps)
        ],
    }
    with open(out_path.parent / "cpe-exclusions.json", "w") as _f:
        json.dump(_excl_report, _f, indent=2)
        _f.write("\n")

    sys.exit(0)


if __name__ == "__main__":
    main()
