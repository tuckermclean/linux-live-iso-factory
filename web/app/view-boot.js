(function(){
// Boot view — v86 emulator panel, migrated from boot.html
const { h, crumbs } = MonolithUI;

const ISO_URL      = "https://themonolith.s3.us-west-2.amazonaws.com/themonolith.iso";
const V86_CDN      = "https://cdn.jsdelivr.net/npm/v86/";
const V86_BIOS_CDN = "https://cdn.jsdelivr.net/gh/copy/v86@master/";

function renderBoot(root) {
  root.innerHTML = "";
  const wrap = h("div", { class: "page boot-page" });
  root.appendChild(wrap);
  wrap.appendChild(crumbs([{ label: "■ Home", href: "#/" }, { label: "Boot in Browser" }]));

  let emulator    = null;
  let mouseLocked = false;
  let serialOpen  = false;
  let serialBuf   = "";

  // ── Pre-boot panel ────────────────────────────────────────────────────────
  const startPanel = h("div", { class: "boot-start-panel" }, [
    h("div", { class: "boot-intro" }, [
      h("p", {}, [
        "This boots a ", h("strong", {}, "full Linux system"), " using an x86 CPU emulator (v86/WebAssembly) directly in your browser tab — no plugins, no installs, no server-side execution. The ISO is fetched on demand via HTTP range requests, so only sectors the boot sequence actually reads are downloaded.",
      ]),
      h("p", { class: "boot-specs" }, [
        h("span", { class: "chip neutral" }, "~135 MB ISO"),
        h("span", { class: "chip neutral" }, "256 MB emulated RAM"),
        h("span", { class: "chip neutral" }, "i486 kernel"),
      ]),
      h("p", { class: "mutedm tiny" }, "Expect boot to take 1–3 minutes depending on your connection."),
    ]),
    h("button", { class: "boot-btn", id: "btn-start", onclick: startEmulator }, "▶  Power On"),
  ]);
  wrap.appendChild(startPanel);

  // ── Progress ──────────────────────────────────────────────────────────────
  const progressArea = h("div", { class: "boot-progress", id: "boot-progress", style: { display: "none" }}, [
    h("div", { class: "boot-progress-track" }, [h("div", { class: "boot-progress-bar", id: "boot-bar" })]),
    h("div", { class: "mono tiny mutedm", id: "boot-label" }, "Initializing…"),
  ]);
  wrap.appendChild(progressArea);

  // ── Emulator screen ───────────────────────────────────────────────────────
  const screenWrap = h("div", { class: "boot-screen-wrap", id: "screen-wrap" }, [
    h("div", { class: "row gap-8", style: { justifyContent: "center", flexWrap: "wrap" }}, [
      h("button", { class: "pill", onclick: toggleFullscreen }, "⛶ Fullscreen"),
      h("button", { class: "pill", id: "btn-mouse", onclick: toggleMouse }, "🖱 Lock Mouse"),
      h("button", { class: "pill", onclick: sendCtrlAltDel }, "Ctrl+Alt+Del"),
      h("button", { class: "pill", id: "btn-serial", onclick: toggleSerial }, "Serial Log"),
    ]),
    h("div", { id: "screen_container", class: "boot-screen-container" }, [
      h("div"),
      h("canvas"),
    ]),
    h("div", { id: "serial-wrap", style: { display: "none" }}, [
      h("div", { class: "mono tiny mutedm", style: { marginBottom: "4px" }}, "Serial output (ttyS0)"),
      h("div", { id: "serial-log", class: "boot-serial-log" }),
    ]),
  ]);
  wrap.appendChild(screenWrap);

  const errorMsg = h("div", { id: "boot-error", class: "callout fail", style: { display: "none", marginTop: "12px" }});
  wrap.appendChild(errorMsg);

  const corsNotice = h("div", { id: "cors-notice", class: "callout warn", style: { display: "none" }}, [
    h("div", { class: "glyph" }, "!"),
    h("div", {}, [
      h("h4", {}, "CORS error"),
      h("p", {}, "The S3 bucket must allow GET requests with Range headers from this origin."),
    ]),
  ]);
  wrap.appendChild(corsNotice);

  wrap.appendChild(h("div", { class: "callout", style: { marginTop: "12px" }}, [
    h("div", {}, [
      h("p", { class: "mono tiny" }, "Mouse: click inside the screen to capture. Press Escape to release.  Keyboard: works natively once screen is focused."),
    ]),
  ]));

  // ── v86 logic (migrated verbatim from boot.html) ──────────────────────────

  function startEmulator() {
    document.getElementById("btn-start").disabled = true;
    startPanel.style.opacity = "0.4";
    progressArea.style.display = "block";
    setProgress(0, "Fetching emulator resources…");

    try {
      const V86Constructor = window.V86 || window.V86Starter;
      if (!V86Constructor) throw new Error("v86 not loaded — check your network connection");
      emulator = new V86Constructor({
        wasm_path:        V86_CDN + "build/v86.wasm",
        memory_size:      256 * 1024 * 1024,
        vga_memory_size:  8   * 1024 * 1024,
        screen_container: document.getElementById("screen_container"),
        bios:             { url: V86_BIOS_CDN + "bios/seabios.bin" },
        vga_bios:         { url: V86_BIOS_CDN + "bios/vgabios.bin" },
        cdrom:            { url: ISO_URL, async: true },
        boot_order:       0x132,
        autostart:        true,
      });
    } catch (e) {
      showError("Failed to initialize emulator: " + e.message);
      return;
    }

    emulator.add_listener("download-progress", function(e) {
      if (e.total) {
        const pct = Math.round(e.loaded / e.total * 100);
        setProgress(pct, formatBytes(e.loaded) + " / " + formatBytes(e.total) + " — " + e.file_name);
      } else {
        setProgress(-1, "Downloading " + e.file_name + " — " + formatBytes(e.loaded));
      }
    });

    emulator.add_listener("download-error", function(e) {
      showError("Download failed for: " + e.file_name + ". Check the console for CORS or network errors.");
      document.getElementById("cors-notice").style.display = "block";
    });

    emulator.add_listener("emulator-ready", function() {
      progressArea.style.display = "none";
      startPanel.style.display   = "none";
      screenWrap.classList.add("visible");
      document.getElementById("screen_container").focus();
      watchCanvasSize();
    });

    emulator.add_listener("serial0-output-byte", function(byte) {
      serialBuf += String.fromCharCode(byte);
    });

    setInterval(flushSerial, 100);
    document.addEventListener("pointerlockchange",    onPointerLockChange);
    document.addEventListener("mozpointerlockchange", onPointerLockChange);
  }

  function flushSerial() {
    if (!serialBuf) return;
    const log = document.getElementById("serial-log");
    if (!log) return;
    log.textContent += serialBuf;
    serialBuf = "";
    if (log.textContent.length > 5000) log.textContent = log.textContent.slice(-4000);
    log.scrollTop = log.scrollHeight;
  }

  function toggleSerial() {
    serialOpen = !serialOpen;
    const sw = document.getElementById("serial-wrap");
    if (sw) sw.style.display = serialOpen ? "block" : "none";
    const btn = document.getElementById("btn-serial");
    if (btn) btn.textContent = serialOpen ? "Hide Serial" : "Serial Log";
  }

  function toggleFullscreen() {
    const el = document.getElementById("screen_container");
    if (!el) return;
    if (!document.fullscreenElement && !document.webkitFullscreenElement) {
      (el.requestFullscreen || el.webkitRequestFullscreen).call(el);
    } else {
      (document.exitFullscreen || document.webkitExitFullscreen).call(document);
    }
  }

  function toggleMouse() {
    if (!emulator) return;
    const el = document.getElementById("screen_container");
    if (!mouseLocked) {
      (el.requestPointerLock || el.mozRequestPointerLock).call(el);
    } else {
      (document.exitPointerLock || document.mozExitPointerLock).call(document);
    }
  }

  function onPointerLockChange() {
    mouseLocked = !!(document.pointerLockElement || document.mozPointerLockElement);
    const btn = document.getElementById("btn-mouse");
    if (btn) btn.textContent = mouseLocked ? "🖱 Release Mouse" : "🖱 Lock Mouse";
  }

  function sendCtrlAltDel() {
    if (!emulator) return;
    emulator.keyboard_send_scancodes([0x1d, 0x38, 0x53, 0xd3, 0xb8, 0x9d]);
  }

  function applyIntegerScale(canvas) {
    const nw = canvas.width, nh = canvas.height;
    if (!nw || !nh) return;
    const container = canvas.parentElement;
    const maxW = container.clientWidth || window.innerWidth;
    const maxH = window.innerHeight * 0.85;
    const scale = Math.max(1, Math.floor(Math.min(maxW / nw, maxH / nh)));
    canvas.style.width  = (nw * scale) + "px";
    canvas.style.height = (nh * scale) + "px";
  }

  function watchCanvasSize() {
    const canvas = document.querySelector("#screen_container canvas");
    if (!canvas) return;
    applyIntegerScale(canvas);
    new MutationObserver(() => applyIntegerScale(canvas))
      .observe(canvas, { attributes: true, attributeFilter: ["width", "height"] });
    window.addEventListener("resize", () => applyIntegerScale(canvas));
  }

  function setProgress(pct, label) {
    const bar = document.getElementById("boot-bar");
    if (bar) {
      bar.style.width   = pct < 0 ? "100%" : pct + "%";
      bar.style.opacity = pct < 0 ? "0.4" : "1";
    }
    const lbl = document.getElementById("boot-label");
    if (lbl) lbl.textContent = label;
  }

  function formatBytes(n) {
    if (n < 1024)             return n + " B";
    if (n < 1024 * 1024)      return (n / 1024).toFixed(1)         + " KB";
    if (n < 1024 * 1024 * 1024) return (n / 1024 / 1024).toFixed(1) + " MB";
    return (n / 1024 / 1024 / 1024).toFixed(2) + " GB";
  }

  function showError(msg) {
    const el = document.getElementById("boot-error");
    if (!el) return;
    el.style.display = "flex";
    el.innerHTML = "";
    el.appendChild(h("div", { class: "glyph" }, "!"));
    el.appendChild(h("div", {}, [h("h4", {}, "Error"), h("p", {}, msg)]));
    progressArea.style.display = "none";
    const btn = document.getElementById("btn-start");
    if (btn) { btn.disabled = false; }
    startPanel.style.opacity = "1";
  }
}

window.MonolithViews = Object.assign(window.MonolithViews || {}, { renderBoot });
})();
