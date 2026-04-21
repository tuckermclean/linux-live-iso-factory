(function(){
// Package-centric view: one package across every build
const { h, th, statusChip, card, loadingBlock, crumbs } = MonolithUI;
const { sparkline } = MonolithCharts;
const { fetchBuildIndex, fetchBuild } = MonolithData;

async function renderPackage(root, name) {
  root.innerHTML = "";
  const wrap = h("div", { class: "page" });
  root.appendChild(wrap);
  const decoded = decodeURIComponent(name);
  wrap.appendChild(crumbs([{ label: "■ Dashboard", href: "#/" }, { label: `Package · ${decoded}` }]));
  const shell = h("div", { style: { marginTop: "12px" }});
  wrap.appendChild(shell);
  shell.appendChild(loadingBlock("SCANNING BUILD HISTORY"));

  const builds = await fetchBuildIndex();
  // Look up this package in up to most recent 6 builds (avoids 36 * 7MB fetches)
  const slice = builds.slice(0, 8);
  const results = await Promise.all(slice.map(async b => {
    try {
      const d = await fetchBuild(b.tag);
      const p = (d.bom?.components || []).find(c => c.name === decoded);
      return { build: b, pkg: p };
    } catch { return { build: b, pkg: null }; }
  }));
  shell.innerHTML = "";

  const versions = results.filter(r => r.pkg).map(r => r.pkg.version);
  const cpes = new Set(results.map(r => r.pkg?.cpe).filter(Boolean));
  shell.appendChild(h("section", { class: "hero" }, [
    h("div", {}, [
      h("div", { class: "row gap-8", style: { marginBottom: "4px" }}, [
        h("span", { class: "pill accent" }, "◨ PACKAGE"),
        h("span", { class: "pill" }, `${[...new Set(versions)].length} distinct versions`),
        h("span", { class: "pill " + (cpes.size ? "pass" : "warn") }, cpes.size ? "CPE MAPPED" : "UNMAPPED"),
      ]),
      h("h1", {}, [h("span", { class: "sq" }), decoded]),
      h("p", { class: "sub" }, `Version and attestation history for ${decoded} across the ${slice.length} most recent builds.`),
    ]),
    h("div", { class: "status-card" }, [
      h("div", { class: "mono tiny mutedm" }, "LATEST"),
      results[0]?.pkg ? h("div", { class: "mono", style: { fontSize: "16px" }}, results[0].pkg.version) : h("span", { class: "chip warn" }, "NOT PRESENT"),
      results[0]?.pkg?.cpe ? h("div", { class: "mono tiny mutedm", title: results[0].pkg.cpe }, truncate(results[0].pkg.cpe, 48)) : null,
    ]),
  ]));

  const table = h("table", { class: "t" }, [
    h("thead", {}, h("tr", {}, [th("Build"), th("Date"), th("Version"), th("License"), th("CPE"), th("Build status")])),
    h("tbody", {}, results.map(r => h("tr", {}, [
      h("td", { class: "mono" }, h("a", { href: `#/build/${r.build.tag}` }, r.build.tag)),
      h("td", { class: "mono mutedm" }, r.build.date),
      h("td", { class: "mono" }, r.pkg ? r.pkg.version : h("span", { class: "mutedm" }, "—")),
      h("td", { class: "mono tiny mutedm" }, r.pkg ? truncate(extractLicense(r.pkg) || "—", 40) : ""),
      h("td", {}, r.pkg?.cpe ? h("span", { class: "mono tiny mutedm", title: r.pkg.cpe }, truncate(r.pkg.cpe.replace("cpe:2.3:",""), 36)) : h("span", { class: "chip warn" }, "UNMAPPED")),
      h("td", {}, statusChip(r.build.overall)),
    ]))),
  ]);
  shell.appendChild(card("VERSION HISTORY", h("div", { class: "table-wrap" }, table), { pad0: true }));
}
function truncate(s,n){ return s && s.length > n ? s.slice(0, n-1)+"…" : (s||""); }
function extractLicense(p){ if (!p.licenses) return ""; return p.licenses.map(l => l.license?.name || l.license?.id || l.expression).filter(Boolean).join(" AND "); }

window.MonolithViews = Object.assign(window.MonolithViews || {}, { renderPackage });

})();
