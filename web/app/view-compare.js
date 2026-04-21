(function(){
// Compare two builds side by side
const { h, th, statusChip, deltaCell, card, loadingBlock, crumbs } = MonolithUI;
const { fetchBuildIndex, fetchBuild, extractPackages, extractLicense, extractVulns } = MonolithData;

async function renderCompare(root, a, b) {
  root.innerHTML = "";
  const wrap = h("div", { class: "page" });
  root.appendChild(wrap);
  wrap.appendChild(crumbs([{ label: "■ Dashboard", href: "#/" }, { label: `Compare ${a} ↔ ${b}` }]));
  const shell = h("div", { style: { marginTop: "12px" }});
  wrap.appendChild(shell);
  shell.appendChild(loadingBlock("DIFFING BUILDS"));

  let builds;
  try { builds = await fetchBuildIndex(); } catch (e) { shell.innerHTML = ""; shell.appendChild(h("div", { class: "callout fail" }, String(e.message))); return; }

  let aTag = a, bTag = b;
  if (aTag === "_prev") {
    const i = builds.findIndex(x => x.tag === bTag);
    aTag = builds[i + 1]?.tag || builds[1]?.tag || builds[0].tag;
  }
  if (bTag === "_prev") bTag = builds[1]?.tag || builds[0].tag;

  const [dA, dB] = await Promise.all([fetchBuild(aTag), fetchBuild(bTag)]);
  shell.innerHTML = "";

  // ————— build picker: A and B dropdowns + swap
  const picker = h("div", { class: "compare-picker" }, [
    h("div", { class: "cp-col" }, [
      h("label", { class: "mono tiny mutedm" }, "BASE (A)"),
      buildSelect(builds, aTag, (t) => { location.hash = `#/compare/${t}/${bTag}`; }),
    ]),
    h("button", {
      class: "cp-swap",
      title: "Swap A and B",
      onclick: () => { location.hash = `#/compare/${bTag}/${aTag}`; },
    }, "⇄"),
    h("div", { class: "cp-col" }, [
      h("label", { class: "mono tiny mutedm" }, "COMPARE (B)"),
      buildSelect(builds, bTag, (t) => { location.hash = `#/compare/${aTag}/${t}`; }),
    ]),
    h("div", { class: "cp-shortcuts" }, [
      h("span", { class: "mono tiny mutedm" }, "QUICK:"),
      h("a", { class: "pill tiny", href: `#/compare/${builds[1]?.tag || aTag}/${builds[0].tag}` }, "latest ↔ prev"),
      h("a", { class: "pill tiny", href: `#/compare/${builds[builds.length-1].tag}/${builds[0].tag}` }, "oldest ↔ latest"),
    ]),
  ]);
  shell.appendChild(picker);

  const pkgA = new Map(extractPackages(dA.bom).filter(c => /^[a-z-]+\/[a-z0-9._+-]+$/i.test(c.name)).map(p => [p.name, p]));
  const pkgB = new Map(extractPackages(dB.bom).filter(c => /^[a-z-]+\/[a-z0-9._+-]+$/i.test(c.name)).map(p => [p.name, p]));
  const keys = new Set([...pkgA.keys(), ...pkgB.keys()]);
  const added = [], removed = [], changed = [], same = [];
  for (const k of keys) {
    const pa = pkgA.get(k), pb = pkgB.get(k);
    if (!pa) added.push(pb);
    else if (!pb) removed.push(pa);
    else if (pa.version !== pb.version) changed.push({ name: k, from: pa.version, to: pb.version });
    else same.push(pa);
  }

  const bidx = (t) => builds.find(x => x.tag === t);
  const bA = bidx(aTag), bB = bidx(bTag);

  const hero = h("section", { class: "hero" }, [
    h("div", {}, [
      h("div", { class: "row gap-8", style: { marginBottom: "4px" }}, [
        h("span", { class: "pill accent" }, "◧ COMPARE"),
        h("span", { class: "pill" }, `${added.length} added`),
        h("span", { class: "pill" }, `${removed.length} removed`),
        h("span", { class: "pill" }, `${changed.length} changed`),
      ]),
      h("h1", {}, [h("span", { class: "sq" }), "Build Δ"]),
      h("p", { class: "sub" }, `Diffing ${aTag} against ${bTag} — SBOM, CVEs, licenses, and pillar status side by side.`),
      h("div", { class: "grid cols-2 mt-16" }, [
        sideCard("A", bA, dA),
        sideCard("B", bB, dB),
      ]),
    ]),
    h("div", { class: "status-card" }, [
      h("div", { class: "mono tiny mutedm" }, "DELTA"),
      pillDiff("Packages", (bA?.packages||0), (bB?.packages||0)),
      pillDiff("Unmapped CPEs", (bA?.unmappedCPEs||0), (bB?.unmappedCPEs||0), true),
      pillDiff("CVE findings", extractVulns(dA.cve).length, extractVulns(dB.cve).length, true),
      pillDiff("License FAIL", extractLicense(dA.license).summary.fail||0, extractLicense(dB.license).summary.fail||0, true),
      pillDiff("License UNKNOWN", extractLicense(dA.license).summary.unknown||0, extractLicense(dB.license).summary.unknown||0, true),
    ]),
  ]);
  shell.appendChild(hero);

  const diffs = h("div", { class: "grid cols-3 mt-16" });
  shell.appendChild(diffs);
  diffs.appendChild(diffList("ADDED PACKAGES", added.map(p => ({ name: p.name, version: p.version })), "diff-added", "+"));
  diffs.appendChild(diffList("REMOVED PACKAGES", removed.map(p => ({ name: p.name, version: p.version })), "diff-removed", "−"));
  diffs.appendChild(diffList("VERSION CHANGES", changed.map(c => ({ name: c.name, version: `${c.from} → ${c.to}` })), "diff-changed", "~"));
}

function buildSelect(builds, current, onChange) {
  const sel = h("select", { class: "cp-select mono", onchange: (e) => onChange(e.target.value) },
    builds.map(b => h("option", { value: b.tag, selected: b.tag === current }, `${b.tag}  ·  ${b.date}  ·  ${(b.overall||"").toUpperCase()}`))
  );
  return sel;
}

function sideCard(label, b, d) {
  return h("div", { style: { padding: "10px", background: "var(--bg)", border: "1px solid var(--line)", borderRadius: "4px" }}, [
    h("div", { class: "row between" }, [
      h("span", { class: "mono tiny mutedm" }, `SIDE ${label}`),
      statusChip(b?.overall || "—"),
    ]),
    h("div", { class: "mono", style: { marginTop: "6px", fontSize: "14px" }}, b?.tag || "—"),
    h("div", { class: "mono tiny mutedm" }, b?.date || ""),
  ]);
}
function pillDiff(label, av, bv, lowerBetter = false) {
  const d = bv - av;
  const cls = d === 0 ? "zero" : (lowerBetter ? (d < 0 ? "neg" : "pos") : (d > 0 ? "neg" : "pos"));
  return h("div", { class: "row between", style: { padding: "6px 0", borderBottom: "1px dashed var(--line)" }}, [
    h("span", { class: "mono tiny" }, label),
    h("span", { class: "row gap-8" }, [
      h("span", { class: "mono tiny mutedm" }, `${av} → ${bv}`),
      h("span", { class: `delta ${cls}` }, d > 0 ? `+${d}` : String(d)),
    ]),
  ]);
}
function diffList(title, rows, cls, glyph) {
  const body = h("div", { class: "col", style: { maxHeight: "420px", overflow: "auto" }},
    rows.length ? rows.map(r => h("div", { class: `row mono tiny ${cls}`, style: { padding: "4px 0", borderBottom: "1px dashed var(--line)" }}, [
      h("span", { style: { width: "12px" }}, glyph),
      h("span", { style: { flex: 1 }}, r.name),
      h("span", { class: "mutedm" }, r.version || ""),
    ])) : [h("div", { class: "mutedm tiny" }, "— none —")]
  );
  return card(`${title} · ${rows.length}`, body);
}

window.MonolithViews = Object.assign(window.MonolithViews || {}, { renderCompare });

})();
