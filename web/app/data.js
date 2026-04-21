// Data layer — fetches live from The Monolith S3 bucket.
// All JSON is cached in-memory for the session.

const S3_ROOT    = "https://themonolith.s3.us-west-2.amazonaws.com";
const ATTEST_ROOT = "https://themonolith.s3.us-west-2.amazonaws.com/attestation";
const ISO_BASE   = "https://themonolith.s3.us-west-2.amazonaws.com";

const _cache = new Map();
async function getJSON(url) {
  if (_cache.has(url)) return _cache.get(url);
  const p = fetch(url, { cache: "no-store" }).then(r => {
    if (!r.ok) throw new Error(`${url} → ${r.status}`);
    return r.json();
  });
  _cache.set(url, p);
  try { return await p; } catch (e) { _cache.delete(url); throw e; }
}

// Fetch the builds index from the generated JSON (written each CI run).
async function fetchBuildIndex() {
  return getJSON(`${S3_ROOT}/builds-index.json`);
}

// Lightweight fetch of just the attestation-summary.json for a build.
// Use this when you only need metadata (SHA-256, status) without the full SBOMs.
async function fetchSummary(tag) {
  return getJSON(`${ATTEST_ROOT}/${tag}/attestation-summary.json`);
}

// Per-build: fetch the attestation JSONs + summary for metadata.
async function fetchBuild(tag) {
  const base = `${ATTEST_ROOT}/${tag}`;
  const [bom, cve, license, unowned, builderBom, builderCve, summary] = await Promise.allSettled([
    getJSON(`${base}/bom.cdx.json`),
    getJSON(`${base}/cve-report.cdx.json`),
    getJSON(`${base}/license-report.json`),
    getJSON(`${base}/unowned-report.json`),
    getJSON(`${base}/builder-bom.cdx.json`),
    getJSON(`${base}/builder-cve-report.cdx.json`),
    getJSON(`${base}/attestation-summary.json`),
  ]);

  const s = summary.status === "fulfilled" ? summary.value : null;
  const pageMeta = s ? summaryToPageMeta(s, tag) : {};

  return {
    tag,
    pageMeta,
    bom:        bom.status        === "fulfilled" ? bom.value        : null,
    bomErr:     bom.status        === "rejected"  ? bom.reason.message : null,
    cve:        cve.status        === "fulfilled" ? cve.value        : null,
    license:    license.status    === "fulfilled" ? license.value    : null,
    unowned:    unowned.status    === "fulfilled" ? unowned.value    : null,
    builderBom: builderBom.status === "fulfilled" ? builderBom.value : null,
    builderCve: builderCve.status === "fulfilled" ? builderCve.value : null,
  };
}

// Map attestation-summary.json fields to the pageMeta shape expected by view-build.js.
function summaryToPageMeta(s, tag) {
  const atBase = `${ATTEST_ROOT}/${tag}`;
  const urls = {
    "Target SBOM (CycloneDX)":  `${atBase}/bom.cdx.json`,
    "Builder SBOM (CycloneDX)": `${atBase}/builder-bom.cdx.json`,
    "CVE Report":               `${atBase}/cve-report.cdx.json`,
    "License Report":           `${atBase}/license-report.json`,
    "Unowned Report":           `${atBase}/unowned-report.json`,
  };
  const unmapped = s.unmapped_cpe_count != null
    ? String(s.unmapped_cpe_count) + (s.excluded_cpe_count ? ` +${s.excluded_cpe_count} excl.` : "")
    : "";
  return {
    "Build Type":           tag.includes("-") ? "CI build (master)" : "tagged release",
    "Timestamp":            s.timestamp || "",
    "Packages":             s.package_count != null ? String(s.package_count) : "",
    "Unmapped CPEs":        unmapped,
    "Scanner":              "grype",
    "ISO SHA-256":          s.iso_sha256 || "",
    "ISO Download":         `${ISO_BASE}/themonolith-${tag}.iso`,
    "SBOM":                 (s.sbom_check      || "").toUpperCase(),
    "Licenses":             (s.license_check   || "").toUpperCase(),
    "CVEs (sysroot)":       (s.cve_check       || "").toUpperCase(),
    "Unowned Files":        (s.unowned_check   || "").toUpperCase(),
    "Builder CVEs":         (s.builder?.cve_check || "").toUpperCase(),
    "Overall":              (s.overall         || "").toUpperCase(),
    "BUILD_EPOCH":          s.builder?.epoch   || "",
    "Cross target":         s.builder?.cross_target || "",
    "Builder packages":     s.builder?.package_count != null ? String(s.builder.package_count) : "",
    "Unmapped CPEs (builder)": s.builder?.unmapped_cpe_count != null ? String(s.builder.unmapped_cpe_count) : "",
    ...urls,
    __urls: urls,
  };
}

// Derive "real" packages from the SBOM — portage-type, excluding file entries.
function extractPackages(bom) {
  if (!bom || !bom.components) return [];
  return bom.components.filter(c => c.type !== "file" && c.name);
}

function pkgKeyFromComponent(c) {
  return `${c.name}@${c.version || ""}`;
}

function extractCPEs(bom) {
  const map = new Map();
  if (!bom || !bom.components) return map;
  for (const c of bom.components) {
    if (c.cpe) map.set(c.name, c.cpe);
  }
  return map;
}

function extractVulns(cve) {
  if (!cve) return [];
  return cve.vulnerabilities || [];
}

function extractLicense(lic) {
  if (!lic) return { summary: { total: 0, pass: 0, fail: 0, unknown: 0 }, components: [] };
  return {
    summary:    lic.summary    || { total: 0, pass: 0, fail: 0, unknown: 0 },
    components: lic.components || [],
    policyPath: lic.policy_path,
    policySha:  lic.policy_sha256,
    timestamp:  lic.timestamp,
  };
}

function licenseFamilyCounts(components) {
  const counts = new Map();
  for (const c of components) {
    const norm = (c.normalized && c.normalized.length) ? c.normalized : [];
    const fam  = (norm[0] || c.raw_license || "unknown").toString();
    const key  = (fam.split(/[-_]/)[0] || "UNKNOWN").toUpperCase();
    counts.set(key, (counts.get(key) || 0) + 1);
  }
  return [...counts.entries()].sort((a, b) => b[1] - a[1]);
}

function normStatus(s) {
  if (!s) return "neutral";
  const u = s.toString().toUpperCase();
  if (u === "PASS")    return "pass";
  if (u === "FAIL")    return "fail";
  if (u === "REVOKED") return "revoked";
  if (u === "UNKNOWN") return "warn";
  return "neutral";
}

window.MonolithData = {
  S3_ROOT, ATTEST_ROOT, ISO_BASE,
  fetchBuildIndex, fetchBuild, fetchSummary,
  extractPackages, extractCPEs, extractVulns, extractLicense,
  licenseFamilyCounts, normStatus, pkgKeyFromComponent,
};
