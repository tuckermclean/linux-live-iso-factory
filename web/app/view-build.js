(function(){
// Build view — the deep dive. Tabs: Overview, SBOM, CVEs, Licenses, Unowned, Provenance, Builder, Verify
const { h, th, statusChip, hashCell, copyBtn, card, loadingBlock, tabs, seg, filterBy, crumbs } = MonolithUI;
const { sparkline, donut, barList } = MonolithCharts;
const { fetchBuild, extractPackages, extractVulns, extractLicense, licenseFamilyCounts, normStatus } = MonolithData;

async function renderBuild(root, tag) {
  root.innerHTML = "";
  const wrap = h("div", { class: "page" });
  root.appendChild(wrap);

  wrap.appendChild(crumbs([
    { label: "■ Dashboard", href: "#/" },
    { label: `Build ${tag}` },
  ]));

  const shell = h("div", { style: { marginTop: "12px" } });
  wrap.appendChild(shell);
  shell.appendChild(loadingBlock("DOWNLOADING SBOM + CVE + LICENSE REPORTS"));

  let data;
  try {
    data = await fetchBuild(tag);
  } catch (e) {
    shell.innerHTML = "";
    shell.appendChild(h("div", { class: "callout fail" }, [
      h("div", { class: "glyph" }, "!"),
      h("div", {}, [h("h4", {}, "Fetch error"), h("p", {}, String(e.message))]),
    ]));
    return;
  }

  shell.innerHTML = "";

  const pm = data.pageMeta || {};
  const overall = pm["Overall"] || "—";
  const licSum = extractLicense(data.license);
  const vulns = extractVulns(data.cve);
  const builderVulns = extractVulns(data.builderCve);
  const pkgs = extractPackages(data.bom).filter(c => !c.name.startsWith("var/") && !c.name.includes("/"));
  // Portage packages include slashes (category/name); filter: real portage entries
  const portagePkgs = extractPackages(data.bom).filter(c =>
    (c.purl && c.purl.startsWith("pkg:ebuild/")) || /^[a-z-]+\/[a-z0-9._+-]+$/i.test(c.name)
  );
  const unmappedCount = pm["Unmapped CPEs"] ? parseInt(pm["Unmapped CPEs"], 10) : (portagePkgs.filter(p => !p.cpe).length);

  // ── Hero
  const hero = h("section", { class: "hero" });
  shell.appendChild(hero);
  hero.appendChild(h("div", {}, [
    h("div", { class: "row gap-8", style: { marginBottom: "4px" } }, [
      statusChip(overall),
      h("span", { class: "pill" }, pm["Build Type"] || "build"),
      h("span", { class: "pill" }, pm["Timestamp"] || ""),
    ]),
    h("h1", {}, [h("span", { class: "sq" }), tag]),
    h("p", { class: "sub" },
      `${pm["Packages"] || portagePkgs.length} packages · ${unmappedCount} unmapped CPEs · ${licSum.summary.total} license checks · ${vulns.length} CVE findings · Scanner ${pm["Scanner"] || "grype"}`),
    h("div", { class: "row gap-8 mt-16 wrap" }, [
      h("a", { class: "pill accent", href: pm["ISO Download"] || pm.__urls?.["ISO Download"] || `https://themonolith.s3.amazonaws.com/themonolith-${tag}.iso`, target: "_blank", download: `themonolith-${tag}.iso` }, "◇ DOWNLOAD ISO"),
      h("button", { class: "pill", onclick: () => switchTab("verify") }, "⎘ VERIFY ATTESTATION"),
      h("a", { class: "pill", href: `#/compare/_prev/${tag}` }, "⇄ COMPARE WITH PREV"),
    ]),
  ]));

  // Right: pillar grid
  hero.appendChild(h("div", { class: "status-card" }, [
    h("div", { class: "row between" }, [
      h("div", { class: "mono tiny mutedm" }, "ATTESTATION PILLARS"),
      statusChip(overall),
    ]),
    pillar("SBOM (target)", pm["SBOM"] || "PASS"),
    pillar("Licenses", pm["Licenses"] || (licSum.summary.fail ? "FAIL" : "PASS")),
    pillar("CVEs (sysroot)", pm["CVEs (sysroot)"] || (vulns.length ? "FAIL" : "PASS")),
    pillar("Unowned files", pm["Unowned Files"] || "PASS"),
    pillar("Builder CVEs", pm["Builder CVEs"] || (builderVulns.length ? "FAIL" : "PASS")),
    h("div", { class: "row between", style: { paddingTop: "4px" }}, [
      h("span", { class: "mutedm mono tiny" }, `grype · CVE DB ${pm["CVE DB built"] || ""}`),
    ]),
  ]));

  // ── Tabs
  const tabIds = ["overview", "sbom", "cves", "licenses", "unowned", "provenance", "builder", "verify"];
  const labels = {
    overview: "Overview", sbom: "SBOM", cves: "CVEs", licenses: "Licenses",
    unowned: "Unowned", provenance: "Provenance", builder: "Builder Env", verify: "Verify",
  };
  const counts = {
    sbom: portagePkgs.length,
    cves: vulns.length,
    licenses: licSum.summary.total,
    unowned: data.unowned?.summary?.unowned ?? 0,
    builder: (data.builderBom?.components || []).filter(c => c.type !== "file" && c.name).length,
  };

  let currentTab = (location.hash.split("?")[1] || "").match(/tab=(\w+)/)?.[1] || "overview";
  if (!tabIds.includes(currentTab)) currentTab = "overview";

  const tabBar = h("div", {});
  const bodyWrap = h("div", { style: { marginTop: "16px" }});
  shell.appendChild(tabBar);
  shell.appendChild(bodyWrap);

  function switchTab(id) {
    currentTab = id;
    tabBar.innerHTML = "";
    tabBar.appendChild(tabs(tabIds.map(x => ({ id: x, label: labels[x], count: counts[x] })), currentTab, switchTab));
    bodyWrap.innerHTML = "";
    renderTab(bodyWrap, id, { tag, data, pm, licSum, vulns, builderVulns, portagePkgs });
    history.replaceState({}, "", `#/build/${tag}?tab=${id}`);
    window.scrollTo({ top: tabBar.offsetTop - 16, behavior: "instant" in window ? "instant" : "auto" });
  }
  window.__ctxSwitch = switchTab;
  switchTab(currentTab);
}

function pillar(label, status) {
  return h("div", { class: "row", style: { padding: "6px 0", borderBottom: "1px dashed var(--line)" }}, [
    h("span", { style: { flex: 1 }, class: "mono tiny" }, label),
    statusChip(status),
  ]);
}

function renderTab(root, id, ctx) {
  switch (id) {
    case "overview": return renderOverview(root, ctx);
    case "sbom": return renderSbom(root, ctx);
    case "cves": return renderCves(root, ctx);
    case "licenses": return renderLicenses(root, ctx);
    case "unowned": return renderUnowned(root, ctx);
    case "provenance": return renderProvenance(root, ctx);
    case "builder": return renderBuilder(root, ctx);
    case "verify": return renderVerify(root, ctx);
  }
}

function renderOverview(root, { tag, pm, licSum, vulns, portagePkgs, data }) {
  const grid = h("div", { class: "grid cols-3" });
  root.appendChild(grid);

  // Build facts
  const facts = h("dl", { class: "kv" });
  const factKeys = [
    "Build Type", "Timestamp", "Packages", "Unmapped CPEs",
    "Scanner", "CVE DB built",
  ];
  factKeys.forEach(k => {
    if (pm[k]) { facts.appendChild(h("dt", {}, k)); facts.appendChild(h("dd", {}, pm[k])); }
  });
  if (pm["ISO SHA-256"]) {
    facts.appendChild(h("dt", {}, "ISO SHA-256"));
    facts.appendChild(h("dd", {}, hashCell(pm["ISO SHA-256"], { short: false })));
  }
  grid.appendChild(card("BUILD FACTS", facts));

  // License donut + fam bars
  const licComps = licSum.components || [];
  const famCounts = licenseFamilyCounts(licComps).slice(0, 8);
  const palette = ["var(--accent)", "var(--pass)", "var(--warn)", "var(--revoked)", "var(--fg-2)", "var(--fail)", "var(--line-2)", "var(--bg-3)"];
  const donutSeg = [
    { value: licSum.summary.pass, color: "var(--pass)", label: "PASS" },
    { value: licSum.summary.unknown, color: "var(--warn)", label: "UNKNOWN" },
    { value: licSum.summary.fail, color: "var(--fail)", label: "FAIL" },
  ];
  const licBody = h("div", {}, [
    h("div", { class: "donut" }, [
      donut(donutSeg, { size: 120, thickness: 16 }),
      h("div", { class: "legend" }, [
        h("div", { class: "i" }, [h("span", { class: "sw", style: { background: "var(--pass)" }}), `PASS · ${licSum.summary.pass}`]),
        h("div", { class: "i" }, [h("span", { class: "sw", style: { background: "var(--warn)" }}), `UNKNOWN · ${licSum.summary.unknown}`]),
        h("div", { class: "i" }, [h("span", { class: "sw", style: { background: "var(--fail)" }}), `FAIL · ${licSum.summary.fail}`]),
      ]),
    ]),
    h("div", { class: "mono tiny mutedm mt-16", style: { marginBottom: "4px" }}, "TOP LICENSE FAMILIES"),
    barList(famCounts.map(([k, v], i) => ({ label: k, value: v, color: palette[i % palette.length] })), { w: 360 }),
  ]);
  grid.appendChild(card("LICENSE COMPLIANCE", licBody, { meta: `${licSum.summary.total} components` }));

  // CVEs summary
  let cveBody;
  if (!vulns.length) {
    cveBody = h("div", { class: "callout pass" }, [
      h("div", { class: "glyph" }, "✓"),
      h("div", {}, [
        h("h4", {}, "No CVE findings"),
        h("p", {}, `Grype matched ${pm["Packages"] || portagePkgs.length} packages against the NVD snapshot and found nothing.`),
      ]),
    ]);
  } else {
    const sev = groupBySeverity(vulns);
    cveBody = h("div", { class: "col" }, [
      h("div", { class: "row gap-8 wrap" }, Object.entries(sev).map(([k, n]) => h("div", { class: `chip ${sevKind(k)}` }, `${k} · ${n}`))),
      h("div", { class: "callout fail mt-8" }, [
        h("div", { class: "glyph" }, "!"),
        h("div", {}, [h("h4", {}, `${vulns.length} vulnerabilities require review`), h("p", {}, "Open the CVEs tab for details, affected components, and suggested fixes.")]),
      ]),
    ]);
  }
  grid.appendChild(card("CVE POSTURE", cveBody, { meta: pm["Scanner"] || "grype" }));

  // Unowned
  const u = data.unowned?.summary;
  if (u) {
    const owned = u.owned || 0, allow = u.allowlisted || 0, un = u.unowned || 0;
    const total = u.total_files || (owned + allow + un) || 1;
    const ownedBody = h("div", {}, [
      barList([
        { label: "Owned", value: owned, color: "var(--pass)" },
        { label: "Allowlisted", value: allow, color: "var(--accent)" },
        { label: "Unowned", value: un, color: "var(--fail)" },
      ], { w: 360, max: total }),
      h("div", { class: "mono tiny mutedm mt-8" }, `${total.toLocaleString()} files scanned · Pillar 4`),
    ]);
    grid.appendChild(card("UNOWNED FILES", ownedBody, { meta: un === 0 ? "clean" : `${un} unowned` }));
  }

  // Byproduct digests — clickable download links
  const urls = pm.__urls || {};
  const digestRows = [
    ["bom.cdx.json", pm["Target SBOM (CycloneDX)"], urls["Target SBOM (CycloneDX)"] || `${MonolithData.ATTEST_ROOT}/${tag}/bom.cdx.json`],
    ["builder-bom.cdx.json", pm["Builder SBOM (CycloneDX)"], urls["Builder SBOM (CycloneDX)"] || `${MonolithData.ATTEST_ROOT}/${tag}/builder-bom.cdx.json`],
    ["cve-report.cdx.json", pm["CVE Report"], urls["CVE Report"] || `${MonolithData.ATTEST_ROOT}/${tag}/cve-report.cdx.json`],
    ["license-report.json", pm["License Report"], urls["License Report"] || `${MonolithData.ATTEST_ROOT}/${tag}/license-report.json`],
    ["unowned-report.json", pm["Unowned Report"], urls["Unowned Report"] || `${MonolithData.ATTEST_ROOT}/${tag}/unowned-report.json`],
  ].filter(([, v]) => v);
  const prov = h("div", { class: "col" }, [
    h("div", { class: "mutedm tiny" }, "SHA-256 hashes pinned inside the signed SLSA provenance statement. Click to download."),
    ...digestRows.map(([name, , href]) => h("a", {
      href, target: "_blank", download: name,
      class: "row between digest-row",
      style: { padding: "6px 8px", borderBottom: "1px dashed var(--line)", textDecoration: "none", color: "inherit", borderRadius: "3px" },
    }, [
      h("span", { class: "row gap-8" }, [
        h("span", { class: "mono tiny mutedm" }, "↓"),
        h("span", { class: "mono tiny" }, name),
      ]),
      h("span", { class: "chip neutral" }, "PINNED"),
    ])),
    h("button", { class: "pill mt-8", onclick: () => window.__ctxSwitch?.("provenance") }, "→ OPEN PROVENANCE TAB"),
  ]);
  grid.appendChild(card("PROVENANCE", prov));

  // Recent activity placeholder - swap for real diff tooling
  grid.appendChild(card("VERIFY (QUICK)", h("div", {}, [
    h("div", { class: "codeblock" }, [
      copyBtn(`gh attestation verify themonolith-${tag}.iso \\\n  --owner tuckermclean \\\n  --predicate-type https://slsa.dev/provenance/v1`),
      `gh attestation verify themonolith-${tag}.iso \\\n  --owner tuckermclean \\\n  --predicate-type https://slsa.dev/provenance/v1`,
    ]),
    h("p", { class: "mutedm tiny mt-8" }, "Requires the GitHub CLI with gh-attestation installed, or cosign verify-blob-attestation with the Rekor bundle."),
  ])));
}

function renderSbom(root, { portagePkgs, data, pm }) {
  const cpeMap = new Map(portagePkgs.map(p => [p.name, p.cpe]));

  const head = h("div", { class: "row between gap-12", style: { marginBottom: "12px" }}, [
    h("div", { class: "row gap-12" }, [
      (()=>{ const i = h("input", { type: "search", placeholder: "filter package, version, license…", style: { width: "320px" }});
        i.addEventListener("input", (e)=>{ state.q = e.target.value; render(); });
        return h("div", { class: "search" }, [h("span", { class: "mutedm mono tiny" }, "▸"), i]);
      })(),
      seg([
        { id: "all", label: `All · ${portagePkgs.length}` },
        { id: "mapped", label: "CPE mapped" },
        { id: "unmapped", label: "Unmapped" },
        { id: "unlicensed", label: "No license" },
      ], "all", (id) => { state.filter = id; render(); }),
    ]),
    h("div", { class: "mono tiny mutedm" }, pm["Timestamp"] || ""),
  ]);
  root.appendChild(head);

  const tableCard = card("PACKAGE INVENTORY", h("div", { class: "table-wrap", style: { maxHeight: "680px" }}, [
    h("table", { class: "t", id: "sbom-tbl" }, [
      h("thead", {}, h("tr", {}, [
        th("Package"), th("Version"), th("License"), th("CPE"), th("Scope"),
      ])),
      h("tbody", {}),
    ])
  ]), { pad0: true });
  root.appendChild(tableCard);

  const state = { q: "", filter: "all", expanded: new Set() };
  const tbody = tableCard.querySelector("tbody");
  function render() {
    let rows = portagePkgs;
    if (state.filter === "mapped") rows = rows.filter(p => !!p.cpe);
    else if (state.filter === "unmapped") rows = rows.filter(p => !p.cpe);
    else if (state.filter === "unlicensed") rows = rows.filter(p => !extractPkgLicense(p));
    if (state.q) {
      const q = state.q.toLowerCase();
      rows = rows.filter(p => p.name.toLowerCase().includes(q) || (p.version||"").toLowerCase().includes(q) || (extractPkgLicense(p)||"").toLowerCase().includes(q) || (p.cpe||"").toLowerCase().includes(q));
    }
    tbody.innerHTML = "";
    rows.slice(0, 2000).forEach(p => {
      const lic = extractPkgLicense(p);
      const tr = h("tr", { class: "clickable" }, [
        h("td", { class: "mono" }, p.name),
        h("td", { class: "mono mutedm" }, p.version || "—"),
        h("td", { class: "mono tiny" }, lic ? truncate(lic, 60) : h("span", { class: "chip warn" }, "UNKNOWN")),
        h("td", {}, p.cpe ? h("span", { class: "mono tiny mutedm", title: p.cpe }, truncate(p.cpe.replace("cpe:2.3:", ""), 42)) : h("span", { class: "chip warn" }, "UNMAPPED")),
        h("td", {}, h("a", { href: `#/package/${encodeURIComponent(p.name)}`, class: "mono tiny" }, "▸ history")),
      ]);
      tbody.appendChild(tr);
    });
    if (rows.length > 2000) {
      tbody.appendChild(h("tr", {}, h("td", { colspan: 5, class: "mutedm", style: { padding: "12px", textAlign: "center" }}, `…and ${rows.length - 2000} more. Use the filter to narrow.`)));
    }
    if (!rows.length) tbody.appendChild(h("tr", {}, h("td", { colspan: 5, class: "mutedm", style: { padding: "40px", textAlign: "center" }}, "No packages match.")));
  }
  render();
}
function extractPkgLicense(p) {
  if (!p.licenses) return "";
  return p.licenses.map(l => l.license?.name || l.license?.id || l.expression).filter(Boolean).join(" AND ");
}
function truncate(s, n) { return s.length > n ? s.slice(0, n - 1) + "…" : s; }

function renderCves(root, { vulns, builderVulns, pm }) {
  const all = vulns.map(v => ({ ...v, _scope: "target" })).concat(builderVulns.map(v => ({ ...v, _scope: "builder" })));
  if (!all.length) {
    root.appendChild(h("div", { class: "callout pass" }, [
      h("div", { class: "glyph" }, "✓"),
      h("div", {}, [
        h("h4", {}, "No CVE findings"),
        h("p", {}, `Grype ${pm["Scanner"] ? "(" + pm["Scanner"] + ") " : ""}matched all mapped CPEs against the current NVD snapshot and returned zero vulnerabilities.`),
      ]),
    ]));
    root.appendChild(h("div", { class: "codeblock mt-16" }, [
      copyBtn(`grype sbom:bom.cdx.json --output cyclonedx-json > cve-report.cdx.json`),
      `grype sbom:bom.cdx.json --output cyclonedx-json > cve-report.cdx.json`,
    ]));
    return;
  }
  // If vulns exist, render table
  const head = h("div", { class: "row between mb-12" }, [
    h("div", { class: "row gap-8 wrap" }, Object.entries(groupBySeverity(all)).map(([k, n]) =>
      h("span", { class: `chip ${sevKind(k)}` }, `${k} · ${n}`))),
    h("div", { class: "mono tiny mutedm" }, `${all.length} findings`),
  ]);
  root.appendChild(head);

  const tableCard = card("CVE FINDINGS", h("div", { class: "table-wrap", style: { maxHeight: "640px" }}, [
    h("table", { class: "t" }, [
      h("thead", {}, h("tr", {}, [th("CVE"), th("Severity"), th("Component"), th("Scope"), th("Fix")])),
      h("tbody", {}, all.map(v => h("tr", {}, [
        h("td", { class: "mono" }, h("a", { href: v.source?.url || "#", target: "_blank" }, v.id || "—")),
        h("td", {}, h("span", { class: `chip ${sevKind(v.ratings?.[0]?.severity || "info")}` }, (v.ratings?.[0]?.severity || "info").toUpperCase())),
        h("td", { class: "mono tiny" }, (v.affects?.[0]?.ref || "—").replace(/^pkg:[^\/]+\//, "")),
        h("td", {}, h("span", { class: "chip neutral" }, v._scope.toUpperCase())),
        h("td", { class: "mono tiny mutedm" }, v.analysis?.response?.[0] || "—"),
      ])))
    ])
  ]), { pad0: true });
  root.appendChild(tableCard);
}

function groupBySeverity(vulns) {
  const g = {};
  vulns.forEach(v => {
    const s = (v.ratings?.[0]?.severity || "info").toLowerCase();
    const k = s.charAt(0).toUpperCase() + s.slice(1);
    g[k] = (g[k] || 0) + 1;
  });
  return g;
}
function sevKind(s) {
  const u = (s||"").toLowerCase();
  if (u === "critical" || u === "high" || u === "fail") return "fail";
  if (u === "medium" || u === "warn") return "warn";
  if (u === "low" || u === "info") return "neutral";
  return "neutral";
}

function renderLicenses(root, { licSum }) {
  const rows = licSum.components || [];
  const head = h("div", { class: "row between", style: { marginBottom: "12px" }}, [
    h("div", { class: "row gap-8" }, [
      h("span", { class: "chip pass" }, `PASS · ${licSum.summary.pass}`),
      h("span", { class: "chip warn" }, `UNKNOWN · ${licSum.summary.unknown}`),
      h("span", { class: "chip fail" }, `FAIL · ${licSum.summary.fail}`),
    ]),
    (()=>{ const i = h("input", { type: "search", placeholder: "filter…", style: { width: "280px" }});
      i.addEventListener("input", (e)=>{ state.q = e.target.value; render(); });
      return h("div", { class: "search" }, [h("span", { class: "mutedm mono tiny" }, "▸"), i]);
    })(),
  ]);
  root.appendChild(head);

  const tc = card("LICENSE DECISIONS", h("div", { class: "table-wrap", style: { maxHeight: "640px" }}, [
    h("table", { class: "t" }, [
      h("thead", {}, h("tr", {}, [th("Package"), th("Version"), th("License"), th("Status"), th("Reason")])),
      h("tbody", {}),
    ])
  ]), { pad0: true });
  root.appendChild(tc);
  const tbody = tc.querySelector("tbody");
  const state = { q: "" };
  function render() {
    let list = rows;
    if (state.q) list = filterBy(list, state.q, ["name", "version", "raw_license", "reason"]);
    tbody.innerHTML = "";
    list.forEach(c => tbody.appendChild(h("tr", {}, [
      h("td", { class: "mono" }, c.name),
      h("td", { class: "mono mutedm" }, c.version || "—"),
      h("td", { class: "mono tiny" }, truncate(c.raw_license || "—", 80)),
      h("td", {}, h("span", { class: `chip ${normStatus(c.status)}` }, (c.status || "—").toUpperCase())),
      h("td", { class: "mutedm tiny" }, truncate(c.reason || "", 80)),
    ])));
    if (!list.length) tbody.appendChild(h("tr", {}, h("td", { colspan: 5, class: "mutedm", style: { padding: "40px", textAlign: "center" }}, "No matches.")));
  }
  render();
}

function renderUnowned(root, { data }) {
  const u = data.unowned;
  if (!u) { root.appendChild(h("div", { class: "callout warn" }, h("div", {}, "No unowned report."))); return; }
  const s = u.summary || {};
  root.appendChild(card("SUMMARY", h("div", {}, [
    h("dl", { class: "kv" }, [
      h("dt", {}, "Total files"), h("dd", {}, (s.total_files ?? 0).toLocaleString()),
      h("dt", {}, "Owned by Portage"), h("dd", {}, (s.owned ?? 0).toLocaleString()),
      h("dt", {}, "Allowlisted"), h("dd", {}, (s.allowlisted ?? 0).toLocaleString()),
      h("dt", {}, "Unowned"), h("dd", {}, h("span", { class: `chip ${s.unowned ? "fail" : "pass"}` }, String(s.unowned ?? 0))),
      h("dt", {}, "Sysroot"), h("dd", {}, h("span", { class: "mono tiny" }, u.sysroot || "—")),
      h("dt", {}, "Syft schema"), h("dd", {}, h("span", { class: "mono tiny mutedm" }, u.syft_schema || "—")),
      h("dt", {}, "Timestamp"), h("dd", {}, h("span", { class: "mono tiny mutedm" }, u.timestamp || "—")),
    ]),
  ])));
  const files = u.unowned_files || [];
  if (files.length) {
    root.appendChild(card("UNOWNED PATHS", h("div", { class: "codeblock" }, files.slice(0, 1000).join("\n")), { meta: `${files.length} paths` }));
  } else {
    root.appendChild(h("div", { class: "callout pass mt-16" }, [
      h("div", { class: "glyph" }, "✓"),
      h("div", {}, [h("h4", {}, "No unowned files"), h("p", {}, "Every file on the image root is accounted for by Portage or the allowlist.")]),
    ]));
  }
}

function renderProvenance(root, { pm, tag }) {
  const urls = pm.__urls || {};
  const atRoot = `${MonolithData.ATTEST_ROOT}/${tag}`;
  const digestRows = [
    ["bom.cdx.json", pm["Target SBOM (CycloneDX)"], urls["Target SBOM (CycloneDX)"] || `${atRoot}/bom.cdx.json`],
    ["builder-bom.cdx.json", pm["Builder SBOM (CycloneDX)"], urls["Builder SBOM (CycloneDX)"] || `${atRoot}/builder-bom.cdx.json`],
    ["cve-report.cdx.json", pm["CVE Report"], urls["CVE Report"] || `${atRoot}/cve-report.cdx.json`],
    ["license-report.json", pm["License Report"], urls["License Report"] || `${atRoot}/license-report.json`],
    ["unowned-report.json", pm["Unowned Report"], urls["Unowned Report"] || `${atRoot}/unowned-report.json`],
  ].filter(([, v]) => v);
  const iso = pm["ISO SHA-256"];
  const isoUrl = pm["ISO Download"] || urls["ISO Download"] || `https://themonolith.s3.amazonaws.com/themonolith-${tag}.iso`;
  root.appendChild(card("ISO ARTIFACT", h("div", {}, [
    h("div", { class: "row between gap-12 wrap" }, [
      h("div", {}, [
        h("div", { class: "mono tiny mutedm" }, "SHA-256"),
        hashCell(iso || "—", { short: false }),
      ]),
      h("a", { href: isoUrl, class: "pill accent", download: `themonolith-${tag}.iso` }, `◇ DOWNLOAD themonolith-${tag}.iso`),
    ]),
    h("p", { class: "mutedm tiny mt-8" }, "The ISO hash is recorded inside the signed SLSA provenance statement; verifying a downloaded ISO's SHA-256 against this value is the strongest possible byte-for-byte attestation."),
  ])));

  root.appendChild(card("BYPRODUCT DIGESTS", h("div", { class: "table-wrap" }, [
    h("table", { class: "t" }, [
      h("thead", {}, h("tr", {}, [th("Artifact"), th("Download"), th("Status")])),
      h("tbody", {}, digestRows.map(([name, , href]) => h("tr", {}, [
        h("td", { class: "mono" }, name),
        h("td", {}, h("a", { href, target: "_blank", download: name, class: "mono tiny" }, "↓ download")),
        h("td", {}, h("span", { class: "chip pass" }, "PINNED")),
      ]))),
    ]),
  ]), { pad0: true }));

  root.appendChild(card("SLSA PROVENANCE", h("div", {}, [
    h("p", { class: "mutedm tiny" }, "Each build emits a SLSA v1 provenance statement signed and witnessed via Sigstore (Rekor)."),
    h("div", { class: "codeblock mt-8" }, [
      copyBtn(`gh attestation verify themonolith-${tag}.iso --owner tuckermclean --predicate-type https://slsa.dev/provenance/v1`),
      `gh attestation verify themonolith-${tag}.iso \\\n  --owner tuckermclean \\\n  --predicate-type https://slsa.dev/provenance/v1`,
    ]),
  ])));
}

function renderBuilder(root, { pm, data, builderVulns }) {
  const b = data.builderBom?.components || [];
  const real = b.filter(c => c.type !== "file" && c.name && (c.purl || c.cpe || true)).filter(c => /^[a-z-]+\/[a-z0-9._+-]+$/i.test(c.name));
  root.appendChild(card("BUILDER ENVIRONMENT (Pillar 5)", h("dl", { class: "kv" }, [
    ...["BUILD_EPOCH","Cross target","stage3 digest","Portage snapshot SHA-256","Kernel source SHA-512","Builder packages","Unmapped CPEs","Builder SBOM","Builder CVEs"]
      .filter(k => pm[k]).flatMap(k => [
        h("dt", {}, k),
        /SHA|digest/i.test(k) ? h("dd", {}, hashCell(pm[k], { short: false })) : h("dd", {}, pm[k]),
      ]),
  ])));

  root.appendChild(card("BUILDER PACKAGES", h("div", { class: "table-wrap", style: { maxHeight: "560px" }}, [
    h("table", { class: "t" }, [
      h("thead", {}, h("tr", {}, [th("Package"), th("Version"), th("CPE")])),
      h("tbody", {}, real.slice(0, 1000).map(c => h("tr", {}, [
        h("td", { class: "mono" }, c.name),
        h("td", { class: "mono mutedm" }, c.version || "—"),
        h("td", {}, c.cpe ? h("span", { class: "mono tiny mutedm", title: c.cpe }, truncate(c.cpe.replace("cpe:2.3:", ""), 42)) : h("span", { class: "chip warn" }, "UNMAPPED")),
      ]))),
    ]),
  ]), { meta: `${real.length} packages`, pad0: true }));

  if (builderVulns.length) {
    root.appendChild(card("BUILDER CVE FINDINGS", h("div", { class: "mono tiny" }, builderVulns.length + " findings"), { meta: "details in CVEs tab" }));
  }
}

function renderVerify(root, { tag, pm }) {
  const iso = pm["ISO SHA-256"];
  const steps = [
    {
      n: 1, title: "Download the artifact",
      body: h("div", { class: "codeblock" }, [
        copyBtn(`curl -LO ${pm["ISO Download"] || "https://themonolith.s3.amazonaws.com/themonolith-" + tag + ".iso"}`),
        `curl -LO ${pm["ISO Download"] || "https://themonolith.s3.amazonaws.com/themonolith-" + tag + ".iso"}`,
      ]),
    },
    {
      n: 2, title: "Verify the SHA-256 matches the attested digest",
      body: h("div", {}, [
        h("div", { class: "row gap-12", style: { marginBottom: "8px" }}, [
          h("span", { class: "mono tiny mutedm" }, "EXPECTED"),
          hashCell(iso || "—", { short: false }),
        ]),
        h("div", { class: "codeblock" }, [
          copyBtn(`sha256sum themonolith-${tag}.iso`),
          `sha256sum themonolith-${tag}.iso`,
        ]),
      ]),
    },
    {
      n: 3, title: "Verify the SLSA provenance attestation",
      body: h("div", {}, [
        h("p", { class: "mutedm tiny" }, "Requires the GitHub CLI with the gh-attestation extension."),
        h("div", { class: "codeblock" }, [
          copyBtn(`gh extension install github/gh-attestation\ngh attestation verify themonolith-${tag}.iso --owner tuckermclean --predicate-type https://slsa.dev/provenance/v1`),
          `gh extension install github/gh-attestation\ngh attestation verify themonolith-${tag}.iso \\\n  --owner tuckermclean \\\n  --predicate-type https://slsa.dev/provenance/v1`,
        ]),
      ]),
    },
    {
      n: 4, title: "Alternative: cosign + Rekor bundle",
      body: h("div", { class: "codeblock" }, [
        copyBtn(`cosign verify-blob-attestation --bundle ${tag}.rekor.json --type slsaprovenance themonolith-${tag}.iso`),
        `cosign verify-blob-attestation \\\n  --bundle ${tag}.rekor.json \\\n  --type slsaprovenance \\\n  themonolith-${tag}.iso`,
      ]),
    },
  ];
  const grid = h("div", { class: "col gap-16" });
  root.appendChild(grid);
  steps.forEach(s => grid.appendChild(card(`STEP ${String(s.n).padStart(2,"0")} · ${s.title}`, s.body)));
}

window.MonolithViews = Object.assign(window.MonolithViews || {}, { renderBuild });

})();
