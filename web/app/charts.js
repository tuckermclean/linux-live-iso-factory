// Chart primitives — hand-rolled SVG. No deps.
const NS = "http://www.w3.org/2000/svg";

function el(name, attrs = {}, children = []) {
  const e = document.createElementNS(NS, name);
  for (const [k, v] of Object.entries(attrs)) {
    if (v == null) continue;
    e.setAttribute(k, v);
  }
  for (const c of (Array.isArray(children) ? children : [children])) {
    if (c == null) continue;
    if (typeof c === "string") e.appendChild(document.createTextNode(c));
    else e.appendChild(c);
  }
  return e;
}

// Sparkline — numeric series to a tiny area line
function sparkline(values, { w = 120, h = 28, stroke = "currentColor", fill = "currentColor", dotLast = true } = {}) {
  const svg = el("svg", { viewBox: `0 0 ${w} ${h}`, width: w, height: h, class: "spark" });
  if (!values.length) return svg;
  const min = Math.min(...values);
  const max = Math.max(...values);
  const span = max - min || 1;
  const step = values.length > 1 ? (w - 2) / (values.length - 1) : 0;
  const pts = values.map((v, i) => [1 + i * step, h - 2 - ((v - min) / span) * (h - 4)]);
  const d = pts.map((p, i) => (i === 0 ? "M" : "L") + p[0].toFixed(1) + "," + p[1].toFixed(1)).join(" ");
  const fillD = d + ` L${pts[pts.length-1][0].toFixed(1)},${h} L${pts[0][0].toFixed(1)},${h} Z`;
  svg.appendChild(el("path", { d: fillD, fill, "fill-opacity": 0.12 }));
  svg.appendChild(el("path", { d, fill: "none", stroke, "stroke-width": 1.4, "stroke-linejoin": "round", "stroke-linecap": "round" }));
  if (dotLast) {
    svg.appendChild(el("circle", { cx: pts[pts.length-1][0], cy: pts[pts.length-1][1], r: 2, fill: stroke }));
  }
  return svg;
}

// Timeline of statuses — one tick per build
function statusTimeline(builds, { w = 640, h = 44, onPick } = {}) {
  const svg = el("svg", { viewBox: `0 0 ${w} ${h}`, width: "100%", height: h, preserveAspectRatio: "none" });
  const n = builds.length;
  if (!n) return svg;
  const gap = 1;
  const cw = Math.max(2, (w - gap * (n - 1)) / n);
  builds.forEach((b, i) => {
    const x = i * (cw + gap);
    const s = (b.overall || "").toUpperCase();
    const cls = s === "PASS" ? "pass" : s === "FAIL" ? "fail" : "warn";
    const color = cls === "pass" ? "var(--pass)" : cls === "fail" ? "var(--fail)" : "var(--warn)";
    const r = el("rect", {
      x, y: 2, width: cw, height: h - 4, rx: 1,
      fill: color, "fill-opacity": 0.85, style: "cursor:pointer",
      "data-tag": b.tag, "data-status": s,
    });
    r.addEventListener("click", () => onPick && onPick(b));
    r.addEventListener("mouseenter", () => {
      r.setAttribute("fill-opacity", "1");
      svg.dispatchEvent(new CustomEvent("hover", { detail: b }));
    });
    r.addEventListener("mouseleave", () => {
      r.setAttribute("fill-opacity", "0.85");
    });
    svg.appendChild(r);
  });
  return svg;
}

function donut(segments, { size = 120, thickness = 18 } = {}) {
  const svg = el("svg", { viewBox: `0 0 ${size} ${size}`, width: size, height: size });
  const cx = size / 2, cy = size / 2, r = size / 2 - thickness / 2;
  const total = segments.reduce((s, x) => s + x.value, 0) || 1;
  let a0 = -Math.PI / 2;
  for (const seg of segments) {
    const frac = seg.value / total;
    const a1 = a0 + frac * Math.PI * 2;
    if (frac > 0) {
      const large = a1 - a0 > Math.PI ? 1 : 0;
      const x0 = cx + Math.cos(a0) * r, y0 = cy + Math.sin(a0) * r;
      const x1 = cx + Math.cos(a1) * r, y1 = cy + Math.sin(a1) * r;
      if (frac >= 0.9999) {
        svg.appendChild(el("circle", { cx, cy, r, fill: "none", stroke: seg.color, "stroke-width": thickness }));
      } else {
        const d = `M${x0.toFixed(2)},${y0.toFixed(2)} A${r},${r} 0 ${large} 1 ${x1.toFixed(2)},${y1.toFixed(2)}`;
        svg.appendChild(el("path", { d, fill: "none", stroke: seg.color, "stroke-width": thickness, "stroke-linecap": "butt" }));
      }
    }
    a0 = a1;
  }
  return svg;
}

// Horizontal bar list
function barList(rows, { w = 320, rowH = 22, max } = {}) {
  const h = rows.length * rowH;
  const svg = el("svg", { viewBox: `0 0 ${w} ${h}`, width: w, height: h });
  const m = max || Math.max(...rows.map(r => r.value), 1);
  const labelW = 110;
  rows.forEach((r, i) => {
    const y = i * rowH;
    const barW = ((w - labelW - 40) * r.value) / m;
    svg.appendChild(el("text", {
      x: labelW, y: y + rowH / 2 + 4, "text-anchor": "end",
      "font-family": "var(--mono)", "font-size": 11, fill: "var(--fg-1)",
    }, r.label));
    svg.appendChild(el("rect", {
      x: labelW + 8, y: y + 4, width: Math.max(1, barW), height: rowH - 8,
      fill: r.color || "var(--accent)", "fill-opacity": 0.8, rx: 1,
    }));
    svg.appendChild(el("text", {
      x: labelW + 12 + barW, y: y + rowH / 2 + 4,
      "font-family": "var(--mono)", "font-size": 11, fill: "var(--fg-2)",
    }, String(r.value)));
  });
  return svg;
}

window.MonolithCharts = { sparkline, statusTimeline, donut, barList, el };
