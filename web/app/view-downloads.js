(function(){
const { h, th, statusChip, hashCell, card, loadingBlock, crumbs } = MonolithUI;
const { fetchBuildIndex, fetchBuild } = MonolithData;

async function renderDownloads(root) {
  root.innerHTML = "";
  const wrap = h("div", { class: "page" });
  root.appendChild(wrap);
  wrap.appendChild(crumbs([{ label: "■ Home", href: "#/" }, { label: "Downloads" }]));

  const shell = h("div", { style: { marginTop: "16px" }});
  wrap.appendChild(shell);
  shell.appendChild(loadingBlock("FETCHING BUILD INDEX"));

  let builds;
  try {
    builds = await fetchBuildIndex();
  } catch (e) {
    shell.innerHTML = "";
    shell.appendChild(h("div", { class: "callout fail" }, [
      h("div", { class: "glyph" }, "!"),
      h("div", {}, [h("h4", {}, "Fetch error"), h("p", {}, String(e.message))]),
    ]));
    return;
  }

  shell.innerHTML = "";
  const latest = builds[0];

  // ── Latest release hero ───────────────────────────────────────────────────
  const latestCard = h("section", { class: "hero", style: { marginBottom: "20px" }});
  shell.appendChild(latestCard);

  const isoUrl = `${MonolithData.ISO_BASE}/themonolith-${latest.tag}.iso`;

  const heroLeft = h("div", {}, [
    h("div", { class: "row gap-8", style: { marginBottom: "6px" }}, [
      h("span", { class: "pill accent" }, "LATEST RELEASE"),
      statusChip(latest.overall),
    ]),
    h("h1", {}, [h("span", { class: "sq" }), `themonolith-${latest.tag}.iso`]),
    h("p", { class: "sub" }, `${latest.packages} packages · ${latest.date}`),
    h("div", { class: "row gap-8 mt-16" }, [
      h("a", {
        href: isoUrl, class: "pill accent", target: "_blank", download: `themonolith-${latest.tag}.iso`,
        style: { fontSize: "13px", padding: "8px 16px" },
      }, "◇ DOWNLOAD ISO"),
      h("a", { href: `#/build/${latest.tag}`, class: "pill" }, "→ ATTESTATION"),
    ]),
  ]);
  latestCard.appendChild(heroLeft);

  // Right: SHA-256 + attestation summary — load from summary.json
  const hashPanel = h("div", { class: "status-card" }, [
    h("div", { class: "mono tiny mutedm" }, "INTEGRITY"),
    h("div", { id: "latest-hash", class: "loading dots" }, "LOADING"),
  ]);
  latestCard.appendChild(hashPanel);

  fetchSummary(latest.tag).then(d => {
    const sha = d?.iso_sha256;
    const el = document.getElementById("latest-hash");
    if (!el) return;
    el.className = "col gap-8";
    el.innerHTML = "";
    el.appendChild(h("div", {}, [
      h("div", { class: "mono tiny mutedm" }, "SHA-256"),
      hashCell(sha || "—", { short: false }),
    ]));
    el.appendChild(h("div", { class: "mono tiny mutedm mt-8" }, "Verify:"));
    el.appendChild(h("div", { class: "codeblock", style: { fontSize: "11px", padding: "8px 10px" }}, [
      h("code", {}, `sha256sum themonolith-${latest.tag}.iso`),
    ]));
  }).catch(() => {
    const el = document.getElementById("latest-hash");
    if (el) el.textContent = "—";
  });

  // ── All releases table ────────────────────────────────────────────────────
  const tableCard = card("ALL RELEASES", null, { meta: `${builds.length} builds`, pad0: true });
  shell.appendChild(tableCard);

  const tbody = h("tbody");
  tableCard.querySelector(".body").appendChild(h("div", { class: "table-wrap" }, [
    h("table", { class: "t" }, [
      h("thead", {}, h("tr", {}, [
        th("Tag"), th("Date"), th("Status"), th("SHA-256"), th(""), th(""),
      ])),
      tbody,
    ]),
  ]));

  builds.forEach(b => {
    const url = `${MonolithData.ISO_BASE}/themonolith-${b.tag}.iso`;
    const shaCell = h("td", { class: "mono tiny" }, h("span", { class: "mutedm" }, "…"));
    const tr = h("tr", {}, [
      h("td", { class: "mono" }, h("a", { href: `#/build/${b.tag}` }, b.tag)),
      h("td", { class: "mono mutedm" }, b.date),
      h("td", {}, statusChip(b.overall)),
      shaCell,
      h("td", {}, h("a", { href: url, class: "mono tiny accent", target: "_blank", download: `themonolith-${b.tag}.iso` }, "↓ ISO")),
      h("td", {}, h("a", { href: `#/build/${b.tag}`, class: "mono tiny mutedm" }, "attestation →")),
    ]);
    tbody.appendChild(tr);

    // Lazy-load SHA-256 from attestation summary only (avoids fetching large SBOMs)
    fetchSummary(b.tag).then(d => {
      const sha = d?.iso_sha256;
      shaCell.innerHTML = "";
      shaCell.appendChild(sha ? hashCell(sha, { short: true }) : h("span", { class: "mutedm" }, "—"));
    }).catch(() => {
      shaCell.innerHTML = "";
      shaCell.appendChild(h("span", { class: "mutedm" }, "—"));
    });
  });
}

window.MonolithViews = Object.assign(window.MonolithViews || {}, { renderDownloads });
})();
