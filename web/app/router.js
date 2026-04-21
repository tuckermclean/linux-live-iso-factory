(function(){
const { h } = MonolithUI;

function mount() {
  const root  = document.getElementById("app");
  const route = (location.hash || "#/").replace(/^#/, "").split("?")[0];
  const parts = route.split("/").filter(Boolean);

  if      (parts.length === 0)                        return MonolithViews.renderLanding(root);
  if      (parts[0] === "boot")                       return MonolithViews.renderBoot(root);
  if      (parts[0] === "downloads")                  return MonolithViews.renderDownloads(root);
  if      (parts[0] === "builds")                     return MonolithViews.renderIndex(root);
  if      (parts[0] === "build"  && parts[1])         return MonolithViews.renderBuild(root, parts[1]);
  if      (parts[0] === "compare" && parts[1] && parts[2]) return MonolithViews.renderCompare(root, parts[1], parts[2]);
  if      (parts[0] === "package" && parts[1])        return MonolithViews.renderPackage(root, parts[1]);
  MonolithViews.renderLanding(root);
}
window.addEventListener("hashchange", mount);

// Active nav helper
function isActive(href) {
  const route = (location.hash || "#/").replace(/^#/, "").split("?")[0];
  const h2 = href.replace(/^#/, "");
  if (h2 === "/") return route === "/" || route === "";
  return route.startsWith(h2);
}

function topbar() {
  function navLink(label, href) {
    const active = isActive(href);
    return h("a", { href, class: "nav-link" + (active ? " active" : "") }, label);
  }

  const bar = h("header", { class: "topbar", id: "topbar" }, [
    h("a", { href: "#/", class: "brand" }, [
      h("span", { class: "glyph" }),
      h("span", { class: "t1" }, "THE MONOLITH"),
    ]),
    h("nav", { class: "topnav" }, [
      navLink("Home",        "#/"),
      navLink("▶ Boot",      "#/boot"),
      navLink("Downloads",   "#/downloads"),
      navLink("Attestation", "#/builds"),
    ]),
    h("div", { class: "spacer" }),
    (() => {
      const i = h("input", { type: "search", placeholder: "jump to build tag…", id: "global-search" });
      i.addEventListener("keydown", (e) => {
        if (e.key === "Enter" && i.value.trim()) { location.hash = `#/build/${i.value.trim()}`; i.value = ""; }
      });
      return h("div", { class: "search" }, [h("span", { class: "mono tiny mutedm" }, "▸"), i, h("span", { class: "kbd" }, "/")]);
    })(),
    h("button", { class: "iconbtn", title: "Toggle theme", onclick: toggleTheme, id: "theme-btn" }, "◐"),
  ]);
  document.body.prepend(bar);

  // Re-render nav active state on route change
  window.addEventListener("hashchange", () => {
    bar.querySelectorAll(".nav-link").forEach(a => {
      a.classList.toggle("active", isActive(a.getAttribute("href")));
    });
  });
}

function toggleTheme() {
  const r   = document.documentElement;
  const cur = r.getAttribute("data-theme") || "dark";
  const next = cur === "dark" ? "light" : "dark";
  r.setAttribute("data-theme", next);
  localStorage.setItem("monolith.theme", next);
}

const TWEAKS = {
  theme: "dark", density: "comfortable", accent: "cyan", showBuilderCard: true
};

function applyTweaks(t) {
  document.documentElement.setAttribute("data-theme", t.theme);
  document.documentElement.style.setProperty("--row-pad", t.density === "compact" ? "5px" : "9px");
  const accentMap = { cyan: "oklch(0.78 0.11 220)", amber: "oklch(0.80 0.15 75)", green: "oklch(0.76 0.14 155)", violet: "oklch(0.72 0.13 300)" };
  if (accentMap[t.accent]) document.documentElement.style.setProperty("--accent", accentMap[t.accent]);
}

function tweaksPanel() {
  const t = { ...TWEAKS };
  const saved = localStorage.getItem("monolith.theme");
  if (saved) t.theme = saved;
  applyTweaks(t);

  const panel = h("aside", { class: "tweaks", id: "tweaks" }, [
    h("div", { class: "head", onclick: () => panel.classList.toggle("open") }, [
      h("span", {}, "■ Tweaks"),
      h("span", { class: "mutedm" }, "▴"),
    ]),
    h("div", { class: "body" }, [
      rowSel("Theme",   ["dark","light"],                   t.theme,   v => { t.theme   = v; apply(); persist(); }),
      rowSel("Density", ["comfortable","compact"],          t.density, v => { t.density = v; apply(); persist(); }),
      rowSel("Accent",  ["cyan","amber","green","violet"],  t.accent,  v => { t.accent  = v; apply(); persist(); }),
    ]),
  ]);
  document.body.appendChild(panel);
  function apply()   { applyTweaks(t); localStorage.setItem("monolith.theme", t.theme); }
  function persist() {
    try { window.parent?.postMessage({ type: "__edit_mode_set_keys", edits: t }, "*"); } catch {}
  }
  window.addEventListener("message", (e) => {
    if (e.data?.type === "__activate_edit_mode")   panel.classList.add("open");
    if (e.data?.type === "__deactivate_edit_mode") panel.classList.remove("open");
  });
  try { window.parent?.postMessage({ type: "__edit_mode_available" }, "*"); } catch {}
}
function rowSel(label, opts, active, onPick) {
  return h("div", { class: "row" }, [
    h("label", { style: { flex: 1 }}, label),
    MonolithUI.seg(opts.map(o => ({ id: o, label: o })), active, onPick),
  ]);
}

window.addEventListener("keydown", (e) => {
  if (e.target.matches("input, textarea")) return;
  if (e.key === "/") { e.preventDefault(); document.getElementById("global-search")?.focus(); }
  if (e.key === "g") { location.hash = "#/"; }
  if (e.key === "t") toggleTheme();
});

document.addEventListener("DOMContentLoaded", () => {
  topbar();
  tweaksPanel();
  mount();
});
})();
