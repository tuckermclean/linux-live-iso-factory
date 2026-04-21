(function(){
// Index view — build history, trends, hero KPIs, keyboard search
const { h, th, statusChip, deltaCell, card, loadingBlock, seg, filterBy } = MonolithUI;
const { sparkline, statusTimeline, donut, barList } = MonolithCharts;
const { fetchBuildIndex, normStatus } = MonolithData;

async function renderIndex(root) {
  root.innerHTML = "";
  const wrap = h("div", { class: "page" });
  root.appendChild(wrap);

  const heroEl = h("section", { class: "hero" });
  wrap.appendChild(heroEl);
  heroEl.appendChild(h("div", {}, loadingBlock("SYNCING WITH S3")));

  let builds;
  try {
    builds = await fetchBuildIndex();
  } catch (e) {
    heroEl.innerHTML = "";
    heroEl.appendChild(h("div", {}, [
      h("h1", {}, [h("span", { class: "sq" }), "Could not reach attestation data"]),
      h("p", { class: "sub" }, String(e.message)),
    ]));
    return;
  }

  const latest    = builds[0];
  const passCount = builds.filter(b => (b.overall||"").toUpperCase() === "PASS").length;
  const failCount = builds.length - passCount;
  const passRate  = builds.length ? Math.round((passCount / builds.length) * 100) : 0;

  const chrono    = [...builds].reverse();
  const pkgSeries = chrono.map(b => b.packages);
  const cpeSeries = chrono.map(b => b.unmappedCPEs);

  heroEl.innerHTML = "";
  heroEl.appendChild(h("div", {}, [
    h("div", { class: "row gap-8", style: { marginBottom: "4px" } }, [
      h("span", { class: "pill accent" }, [h("span", { class: "dot" }), "LIVE · S3"]),
      h("span", { class: "pill" }, `${builds.length} builds tracked`),
      h("span", { class: "pill " + (failCount ? "warn" : "pass") }, `${passRate}% pass rate`),
    ]),
    h("h1", {}, [h("span", { class: "sq" }), "Attestation · Build History"]),
    h("p", { class: "sub" }, "Signed SLSA provenance, CycloneDX SBOMs, license policy checks, CVE scans, and unowned-file audits — every build, every byproduct, every hash, end to end."),
    h("div", { class: "row gap-8 mt-16" }, [
      h("a", { href: `#/build/${latest.tag}`, class: "pill accent" }, `▸ OPEN LATEST · ${latest.tag}`),
      h("a", { href: `#/compare/${builds[1]?.tag || latest.tag}/${latest.tag}`, class: "pill" }, "⇄ COMPARE BUILDS…"),
    ]),
    h("div", { class: "kpis" }, [
      kpi("LATEST BUILD",   latest.tag,            latest.date, null),
      kpi("PACKAGES",       String(latest.packages), null,       sparkline(pkgSeries, { w: 90, h: 26, stroke: "var(--accent)", fill: "var(--accent)" })),
      kpi("UNMAPPED CPES",  String(latest.unmappedCPEs), `${latest.excludedCPEs} excl`, sparkline(cpeSeries, { w: 90, h: 26, stroke: "var(--warn)", fill: "var(--warn)" })),
      kpi("STATUS",         latest.overall,         null,        statusDots(builds.slice(0, 18).reverse())),
    ]),
  ]));

  heroEl.appendChild(h("div", { class: "status-card" }, [
    h("div", { class: "row between" }, [
      h("div", { class: "mono tiny mutedm" }, "LATEST PILLARS"),
      statusChip(latest.overall),
    ]),
    pillarRow("SBOM", "PASS"),
    pillarRow("License policy", latest.licenses),
    pillarRow("CVE scan",       latest.cves),
    pillarRow("Unowned files",  latest.unowned),
    h("div", { class: "row between", style: { paddingTop: "6px" } }, [
      h("span", { class: "label mutedm" }, "CPE delta"),
      deltaCell(latest.cpeDelta),
    ]),
    h("a", {
      class: "pill accent",
      href:  `#/build/${latest.tag}`,
      style: { alignSelf: "flex-end", marginTop: "4px" },
    }, "→ OPEN FULL ATTESTATION"),
  ]));

  // ── Trends row
  const trendsGrid = h("div", { class: "grid cols-3 mt-16" });
  wrap.appendChild(trendsGrid);

  const tl = h("div");
  const tlSvg = statusTimeline(chrono, { h: 44, onPick: (b) => { location.hash = `#/build/${b.tag}`; } });
  const hoverLabel = h("div", { class: "row between mono tiny mutedm", style: { marginTop: "8px" } }, [
    h("span", {}, "◂ oldest"),
    h("span", { id: "tl-hover" }, "hover a bar"),
    h("span", {}, "newest ▸"),
  ]);
  tlSvg.addEventListener("hover", (e) => {
    const b = e.detail;
    hoverLabel.querySelector("#tl-hover").textContent = `${b.tag} · ${b.date} · ${b.overall}`;
  });
  tl.appendChild(tlSvg);
  tl.appendChild(hoverLabel);
  trendsGrid.appendChild(card("PASS / FAIL TIMELINE", tl, { meta: `${builds.length} builds` }));

  const cpeTrend = h("div");
  cpeTrend.appendChild(sparkline(cpeSeries, { w: 420, h: 76, stroke: "var(--warn)", fill: "var(--warn)" }));
  cpeTrend.appendChild(h("div", { class: "row between mono tiny mutedm mt-8" }, [
    h("span", {}, `min ${Math.min(...cpeSeries)}`),
    h("span", {}, `max ${Math.max(...cpeSeries)}`),
    h("span", {}, `now ${cpeSeries.at(-1)}`),
  ]));
  trendsGrid.appendChild(card("UNMAPPED CPEs (ATTESTATION GAPS)", cpeTrend, { meta: "lower is better" }));

  const tallies = [
    { value: passCount, color: "var(--pass)", label: "PASS" },
    { value: failCount, color: "var(--fail)", label: "FAIL" },
  ];
  const dWrap = h("div", { class: "donut" }, [
    donut(tallies, { size: 110, thickness: 16 }),
    h("div", { class: "legend" }, [
      h("div", { class: "i" }, [h("span", { class: "sw", style: { background: "var(--pass)" }}), `PASS · ${passCount}`]),
      h("div", { class: "i" }, [h("span", { class: "sw", style: { background: "var(--fail)" }}), `FAIL · ${failCount}`]),
      h("div", { class: "i mutedm mt-8" }, [h("span", { style: { fontSize: "18px", color: "var(--fg)" }}, `${passRate}%`), " overall"]),
    ]),
  ]);
  trendsGrid.appendChild(card("OVERALL DISTRIBUTION", dWrap, { meta: "across all builds" }));

  // ── Builds table
  const tableCard = card("BUILD HISTORY", null, { meta: `${builds.length} entries · click to open`, pad0: true });
  wrap.appendChild(tableCard);

  const controls = h("div", { class: "row between", style: { padding: "12px 14px", borderBottom: "1px solid var(--line)" }}, [
    h("div", { class: "row gap-12" }, [
      (() => {
        const input = h("input", { type: "search", placeholder: "filter tags, dates…", id: "tbl-filter" });
        return h("div", { class: "search", style: { minWidth: "280px" }}, [h("span", { class: "mutedm mono tiny" }, "▸"), input]);
      })(),
      seg([
        { id: "all",  label: "All" },
        { id: "fail", label: "Fails only" },
        { id: "pass", label: "Passes only" },
      ], "all", (id) => { state.filter = id; renderRows(); }),
      h("button", { class: "pill", id: "compare-toggle", onclick: () => {
        state.compareMode = !state.compareMode;
        state.picked = [];
        document.getElementById("compare-toggle").classList.toggle("accent", state.compareMode);
        document.getElementById("compare-toggle").textContent = state.compareMode ? "⇄ Compare: pick 2" : "⇄ Compare mode";
        document.getElementById("compare-toolbar").classList.toggle("hidden", !state.compareMode);
        renderRows();
      }}, "⇄ Compare mode"),
    ]),
    h("div", { class: "mono tiny mutedm" }, "click a row to open"),
  ]);
  tableCard.querySelector(".body").appendChild(controls);

  const cmpBar = h("div", { class: "compare-toolbar hidden", id: "compare-toolbar" }, [
    h("div", { class: "slots" }, [
      h("span", { class: "mono tiny mutedm" }, "PICK 2 →"),
      h("div", { class: "slot", id: "slot-a" }, [h("span", { class: "lbl" }, "A"), h("span", { class: "val" }, "—")]),
      h("div", { class: "slot", id: "slot-b" }, [h("span", { class: "lbl" }, "B"), h("span", { class: "val" }, "—")]),
    ]),
    h("div", { class: "row gap-8" }, [
      h("button", { class: "pill", onclick: () => { state.picked = []; renderRows(); updateSlots(); } }, "Clear"),
      h("button", { class: "pill accent", id: "do-diff", onclick: () => {
        if (state.picked.length === 2) location.hash = `#/compare/${state.picked[0]}/${state.picked[1]}`;
      }}, "▸ Diff A ↔ B"),
    ]),
  ]);
  tableCard.querySelector(".body").appendChild(cmpBar);

  function updateSlots() {
    const [a, b] = state.picked;
    const sa = document.getElementById("slot-a");
    const sb = document.getElementById("slot-b");
    if (sa) { sa.classList.toggle("filled", !!a); sa.querySelector(".val").textContent = a || "—"; }
    if (sb) { sb.classList.toggle("filled", !!b); sb.querySelector(".val").textContent = b || "—"; }
    const btn = document.getElementById("do-diff");
    if (btn) btn.disabled = state.picked.length !== 2;
  }

  const scroller = h("div", { class: "table-wrap", style: { maxHeight: "620px" }});
  tableCard.querySelector(".body").appendChild(scroller);
  const table = h("table", { class: "t" }, [
    h("thead", {}, [
      h("tr", {}, [
        th("Tag"), th("Date"), th("Pkgs", "num"), th("Unmapped CPE", "num"), th("Δ", "num"),
        th("License"), th("CVE"), th("Unowned"), th("Overall"), th(""),
      ]),
    ]),
    h("tbody", { id: "tbl-body" }),
  ]);
  scroller.appendChild(table);
  const tbody = table.querySelector("tbody");

  const state = { q: "", filter: "all", cursor: 0, compareMode: false, picked: [] };
  function filteredRows() {
    let rows = builds;
    if (state.q)                    rows = filterBy(rows, state.q, ["tag", "date", "overall"]);
    if (state.filter === "fail")    rows = rows.filter(b => b.overall.toUpperCase() !== "PASS");
    if (state.filter === "pass")    rows = rows.filter(b => b.overall.toUpperCase() === "PASS");
    return rows;
  }
  function renderRows() {
    const rows = filteredRows();
    tbody.innerHTML = "";
    rows.forEach((b) => {
      const isPicked = state.picked.includes(b.tag);
      const tr = h("tr", {
        class: "clickable" + (isPicked ? " compare-picked" : ""),
        "data-tag": b.tag,
        onclick: (e) => {
          if (state.compareMode) {
            e.preventDefault();
            const idx = state.picked.indexOf(b.tag);
            if (idx >= 0) state.picked.splice(idx, 1);
            else if (state.picked.length < 2) state.picked.push(b.tag);
            else state.picked = [state.picked[1], b.tag];
            renderRows();
            updateSlots();
          } else {
            location.hash = `#/build/${b.tag}`;
          }
        },
      }, [
        h("td", { class: "tag mono" }, [h("a", { href: state.compareMode ? "#" : `#/build/${b.tag}`, onclick: state.compareMode ? (e) => e.preventDefault() : null }, b.tag)]),
        h("td", { class: "mono mutedm" }, b.date),
        h("td", { class: "num" }, String(b.packages)),
        h("td", { class: "num" }, [String(b.unmappedCPEs), b.excludedCPEs ? h("span", { class: "mutedm tiny" }, ` +${b.excludedCPEs}`) : null]),
        h("td", { class: "num" }, deltaCell(b.cpeDelta)),
        h("td", {}, statusChip(b.licenses)),
        h("td", {}, statusChip(b.cves)),
        h("td", {}, statusChip(b.unowned)),
        h("td", {}, statusChip(b.overall)),
        h("td", { class: "mono mutedm tiny", style: { textAlign: "right" }}, "→"),
      ]);
      tbody.appendChild(tr);
    });
    if (!rows.length) {
      tbody.appendChild(h("tr", {}, h("td", { colspan: 10, class: "mutedm", style: { padding: "40px", textAlign: "center" }}, "No builds match that filter.")));
    }
  }
  renderRows();
  controls.querySelector("#tbl-filter").addEventListener("input", (e) => { state.q = e.target.value; renderRows(); });

  wrap.appendChild(h("div", { class: "pagefoot" }, [
    "■ The Monolith · attestation data mirrored live from ",
    h("a", { href: `${MonolithData.S3_ROOT}/builds-index.json`, target: "_blank" }, "S3"),
  ]));
}

function kpi(k, v, d, extra) {
  return h("div", { class: "kpi" }, [
    h("div", { class: "k" }, k),
    h("div", { class: "row between" }, [h("div", { class: "v" }, v), extra || null]),
    d ? h("div", { class: "d" }, d) : null,
  ]);
}
function pillarRow(label, status) {
  return h("div", { class: "row" }, [
    h("span", { class: "label", style: { flex: 1 }}, label),
    statusChip(status),
  ]);
}
function statusDots(builds) {
  const w = h("div", { class: "statusdots" });
  builds.forEach(b => {
    const cls = (b.overall || "").toUpperCase() === "PASS" ? "pass" : "fail";
    w.appendChild(h("div", { class: `d ${cls}`, title: `${b.tag} · ${b.overall}` }));
  });
  return w;
}

window.MonolithViews = Object.assign(window.MonolithViews || {}, { renderIndex });
})();
