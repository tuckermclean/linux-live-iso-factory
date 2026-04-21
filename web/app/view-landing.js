(function(){
const { h, statusChip, hashCell, loadingBlock } = MonolithUI;
const { fetchBuildIndex } = MonolithData;

async function renderLanding(root) {
  root.innerHTML = "";
  const wrap = h("div", { class: "page landing" });
  root.appendChild(wrap);

  // ── Hero ──────────────────────────────────────────────────────────────────
  const hero = h("section", { class: "landing-hero" });
  wrap.appendChild(hero);

  hero.appendChild(h("div", { class: "landing-hero-content" }, [
    h("div", { class: "landing-eyebrow" }, [
      h("span", { class: "pill accent" }, [h("span", { class: "dot" }), "i486 · x86-64 · open"]),
    ]),
    h("h1", { class: "landing-h1" }, [
      h("span", { class: "landing-sq" }),
      "THE MONOLITH",
    ]),
    h("p", { class: "landing-tagline" },
      "Fully auditable live Linux ISO that boots identically on a 486 and a modern Intel chip."),
    h("p", { class: "landing-body" },
      "Every binary statically linked. Every package pinned. Every blob vetted and documented. Clean SBOM, clean license inventory, clean build."),
    h("p", { class: "landing-cite" },
      "Built by someone who ran a similar pipeline professionally at Intel scale. This is what "I know what's in my software" actually looks like."),
    h("div", { class: "landing-ctas" }, [
      h("a", { href: "#/boot",      class: "cta-primary"   }, "▶ BOOT IN BROWSER"),
      h("a", { href: "#/downloads", class: "cta-secondary" }, "↓ DOWNLOAD ISO"),
      h("a", { href: "#/builds",    class: "cta-ghost"     }, "→ ATTESTATION"),
    ]),
  ]));

  // ── Feature grid ──────────────────────────────────────────────────────────
  const features = h("div", { class: "landing-features" });
  wrap.appendChild(features);

  const feats = [
    {
      glyph: "■",
      title: "Statically linked",
      body:  "musl libc, not glibc. Every binary carries its own runtime. No ld.so surprises, no shared-library substitution attacks, no ABI drift between boots.",
    },
    {
      glyph: "◈",
      title: "Every input pinned",
      body:  "Stage3 date, portage snapshot, kernel source, toolchain versions — all locked to a single BUILD_EPOCH. The same commit always produces the same ISO.",
    },
    {
      glyph: "◧",
      title: "Full attestation chain",
      body:  "SLSA v1 provenance signed via Sigstore. CycloneDX SBOM for every component. License policy enforced at build time. Grype CVE scan with named CPEs. Unowned-file audit on the live filesystem.",
    },
    {
      glyph: "◉",
      title: "i486 target, any host",
      body:  "The cross-toolchain targets 32-bit i486, so the same image boots on a 25-year-old Pentium and a 2024 Core Ultra without any architecture-specific branching.",
    },
  ];
  feats.forEach(f => {
    features.appendChild(h("div", { class: "feat-card" }, [
      h("div", { class: "feat-glyph" }, f.glyph),
      h("h3", { class: "feat-title" }, f.title),
      h("p",  { class: "feat-body"  }, f.body),
    ]));
  });

  // ── Live build status strip ───────────────────────────────────────────────
  const strip = h("div", { class: "landing-strip" });
  wrap.appendChild(strip);
  strip.appendChild(loadingBlock("FETCHING LATEST BUILD"));

  try {
    const builds = await fetchBuildIndex();
    const latest = builds[0];
    if (!latest) throw new Error("no builds");
    strip.innerHTML = "";
    strip.appendChild(h("div", { class: "strip-inner" }, [
      h("div", { class: "row gap-12" }, [
        h("span", { class: "mono tiny mutedm" }, "LATEST BUILD"),
        h("span", { class: "mono" }, latest.tag),
        statusChip(latest.overall),
      ]),
      h("div", { class: "row gap-12" }, [
        h("span", { class: "mono tiny mutedm" }, "ISO SHA-256"),
        // sha256 is in the summary — fetch it lazily
        buildSha(latest.tag),
      ]),
      h("div", { class: "row gap-8" }, [
        h("a", { href: `#/build/${latest.tag}`, class: "pill accent" }, "→ ATTESTATION"),
        h("a", { href: "#/downloads",           class: "pill"        }, "↓ DOWNLOAD"),
      ]),
    ]));
  } catch (e) {
    strip.innerHTML = "";
    strip.appendChild(h("div", { class: "mono tiny mutedm" }, "Could not reach S3 — " + e.message));
  }
}

// Fetch the sha256 for a build tag asynchronously and render it inline.
function buildSha(tag) {
  const cell = h("span", { class: "mono tiny mutedm" }, "…");
  MonolithData.fetchBuild(tag).then(d => {
    const sha = d.pageMeta?.["ISO SHA-256"];
    if (sha) cell.replaceWith(MonolithUI.hashCell(sha, { short: true }));
    else cell.textContent = "—";
  }).catch(() => { cell.textContent = "—"; });
  return cell;
}

window.MonolithViews = Object.assign(window.MonolithViews || {}, { renderLanding });
})();
