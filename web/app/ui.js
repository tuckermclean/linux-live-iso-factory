// UI helpers — small DOM primitives + common renderers
function h(tag, attrs = {}, children = []) {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v == null || v === false) continue;
    if (k === "class") e.className = v;
    else if (k === "style" && typeof v === "object") Object.assign(e.style, v);
    else if (k === "html") e.innerHTML = v;
    else if (k.startsWith("on") && typeof v === "function") e.addEventListener(k.slice(2).toLowerCase(), v);
    else if (k === "data" && typeof v === "object") {
      for (const [dk, dv] of Object.entries(v)) e.dataset[dk] = dv;
    } else e.setAttribute(k, v === true ? "" : v);
  }
  for (const c of (Array.isArray(children) ? children : [children])) {
    if (c == null || c === false) continue;
    if (typeof c === "string" || typeof c === "number") e.appendChild(document.createTextNode(String(c)));
    else e.appendChild(c);
  }
  return e;
}

function statusChip(label, kind) {
  const k = (kind || MonolithData.normStatus(label));
  return h("span", { class: `chip ${k}` }, label || "—");
}

function hashCell(val, { short = true } = {}) {
  if (!val) return h("span", { class: "mutedm mono tiny" }, "—");
  const display = short && val.length > 20 ? val.slice(0, 10) + "…" + val.slice(-6) : val;
  const wrap = h("span", { class: "hash" }, [
    h("span", { class: "val", title: val }, display),
    h("span", { class: "copy", title: "Copy", onclick: (e) => {
      e.stopPropagation();
      navigator.clipboard.writeText(val).catch(()=>{});
      wrap.classList.add("copied");
      setTimeout(() => wrap.classList.remove("copied"), 900);
    }}, "⎘"),
  ]);
  return wrap;
}

function copyBtn(text, label = "COPY") {
  const b = h("button", { class: "copybtn", onclick: (e) => {
    e.stopPropagation();
    navigator.clipboard.writeText(text).catch(()=>{});
    b.classList.add("copied"); b.textContent = "COPIED";
    setTimeout(() => { b.classList.remove("copied"); b.textContent = label; }, 1100);
  }}, label);
  return b;
}

function deltaCell(n) {
  const cls = n > 0 ? "pos" : n < 0 ? "neg" : "zero";
  const s = n > 0 ? `+${n}` : `${n}`;
  return h("span", { class: `delta ${cls}` }, n === 0 ? "0" : s);
}

function card(title, body, { meta, pad0 } = {}) {
  return h("section", { class: "card" }, [
    h("header", { class: "cap" }, [
      h("div", { class: "title" }, [h("span", { class: "sq" }), title]),
      meta ? h("div", { class: "meta" }, meta) : null,
    ]),
    h("div", { class: "body" + (pad0 ? " pad-0" : "") }, body),
  ]);
}

function loadingBlock(label = "LOADING") {
  return h("div", { class: "loading" }, [h("span", { class: "dots" }, label)]);
}

function crumbs(items) {
  const out = [];
  items.forEach((it, i) => {
    if (i > 0) out.push(h("span", { class: "sep" }, "/"));
    if (it.href) out.push(h("a", { href: it.href }, it.label));
    else out.push(h("span", {}, it.label));
  });
  return h("nav", { class: "crumbs" }, out);
}

function tabs(items, active, onPick) {
  return h("div", { class: "tabs" }, items.map(it =>
    h("button", {
      class: "tab" + (it.id === active ? " active" : ""),
      onclick: () => onPick(it.id),
    }, [it.label, it.count != null ? h("span", { class: "count" }, String(it.count)) : null])
  ));
}

function seg(items, active, onPick) {
  return h("div", { class: "seg" }, items.map(it =>
    h("button", {
      class: "s" + (it.id === active ? " on" : ""),
      onclick: () => onPick(it.id),
    }, it.label)
  ));
}

// Simple fuzzy filter on a string
function filterBy(rows, q, keys) {
  if (!q) return rows;
  const needle = q.toLowerCase();
  return rows.filter(r => keys.some(k => String(r[k] ?? "").toLowerCase().includes(needle)));
}

function th(label, extra = "") { return h("th", { class: extra || "" }, label); }
window.MonolithUI = { h, th, statusChip, hashCell, copyBtn, deltaCell, card, loadingBlock, crumbs, tabs, seg, filterBy };
