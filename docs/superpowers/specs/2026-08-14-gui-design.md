# THE MONOLITH — GUI SPEC (X on everything, 486 up)

> Author: project owner (2026-08-14). House rules apply: ground-truth the tree
> first, Manifest-pin, revbump, reports to `.batteries/reports/`, boot-test or
> it didn't happen.

## Ground truth (verified 2026-08-14 against configs/kernel.config)
- Input: `CONFIG_INPUT=y`, `INPUT_MOUSEDEV=y` (+PSAUX; kdrive's /dev/input/mice
  path), `INPUT_KEYBOARD=y`, `KEYBOARD_ATKBD=y`, `INPUT_MOUSE=y`,
  `MOUSE_PS2=m` (Tier-2 load), `INPUT_EVDEV=m`.
- Serial mice: `CONFIG_SERIO=y`, `SERIO_I8042=y`, **`SERIO_SERPORT=y` already
  built-in** (spec §3 assumed =m — it's =y, so no kernel change needed there).
- Framebuffer: `CONFIG_FB=y`, `FB_VESA=y` (vesafb), `FRAMEBUFFER_CONSOLE=y`,
  `CONFIG_VT=y`, `CONFIG_DRM` **not set**. → kdrive Xfbdev inherits vesafb; no
  modesetting of our own.
- Existing: gpm is in world (console mouse — coexistence per §3). No X anywhere yet.

## 0. DOCTRINE
One GUI stack for every machine, sized for the worst one. No Xft, no fontconfig,
no freetype ANYWHERE in v1 — bitmap core fonts only (misc-fixed + terminus).
This is what makes suckless and "late 486" the same answer instead of two: a
de-Xft'd dwm is ~100 KB and identical on a DX2 and a modern laptop. The bitmap
aesthetic is the brand. Session logic: none — same startx everywhere; RAM
differences handled by swap-on-persist, not a second GUI.

## 1. THE X SERVER (the decision; everything else is clients)
Requirement: static, framebuffer-native, ZERO dlopen (no loader on the disc —
full Xorg disqualified on this alone, before size). Target: TinyX / KDrive
Xfbdev lineage. VERIFY FIRST (45-min recon, then commit to a lane):
- Lane A: a maintained tinyx fork (Tiny Core Linux lineage / idunham descendants)
  — check activity, musl status, license.
- Lane B: pinned older xorg-server (1.20-era, last healthy kdrive) built
  kdrive-only, Xfbdev target, patches from Alpine / sabotage / oasis static-linux
  prior art (all three fought this; steal with attribution).
- Lane C (last resort): Xvesa (kdrive VESA server) — BIOS modesetting, no fb
  needed; 32-bit x86 only (fine here), but vesafb already works so C only if A+B fail.
Ship as overlay ebuild `x11-base/monolith-xserver` (house pattern: pinned tarball
+ patches in files/ + report). Built-in kdrive input drivers (kbd + PS/2 mouse
via /dev/input); no input dlopen modules. Resolution: honor vesafb's mode
(800x600x8 default per boot labels); Xfbdev inherits the framebuffer.

## 2. CLIENT STACK
Protocol libs (::gentoo, cross+static under static.conf): `x11-base/xorg-proto`,
`libxcb` (+xcb-proto; python is host BDEPEND — fine), `libX11`, `libXext` — AND
NOTHING ELSE in v1. No Xt/Xaw/Xmu/ICE/SM (nothing below needs them). Static note:
each DISTINCT client binary bakes its own libX11 (~1 MB), no cross-binary page
sharing — fewer distinct resident clients = less RAM.
- WM: `x11-wm/dwm` via ::gentoo `USE=savedconfig`, with config.h + config.mk
  overrides in savedconfig (house mechanism, like busybox): FREETYPEINC/Xft
  stripped, drw fallback to core fonts — dwm ≥6.2 wants Xft, so a real patch (pin
  a suckless "noxft"/bitmap patch into files/). Fonts: "fixed" + terminus XLFD.
- Launcher: `x11-misc/dmenu`, same savedconfig de-Xft treatment.
- Terminal: `x11-terms/st` WITH THE SAME NOXFT TREATMENT, v1 default — Xlib-only,
  lightest resident terminal. Patch pinned in files/ alongside dwm's. (xterm is a
  possible follow-up for compat/nostalgia ONLY — it alone drags Xt/Xaw/Xmu/ICE/SM;
  by demand, not default.)
- Fonts: `media-fonts/font-misc-misc` + `terminus-font` (PCF bitmap; verify
  mkfontdir/fonts.dir lands in the image — kdrive reads the classic font path; NO
  font server, NO fontconfig).

## 3. INPUT (real hardware tests this first)
Kernel (coordinate with module tiers): Tier 0 (=y, confirmed): INPUT,
INPUT_MOUSEDEV, i8042+atkbd. PS/2 mouse: MOUSE_PS2=m (Tier 2, load it). Serial
mice (the 1996 DX2 case): SERIO_SERPORT already =y + `inputattach` (from
linuxconsoletools; small, static-clean; add to world) + a documented one-liner:
`inputattach --microsoft /dev/ttyS0 &` (or --mouseman etc.). startx does NOT
auto-run inputattach (protocol guessing is the user's call; the doc teaches the
liturgy). gpm coexistence: gpm owns the console mouse; either `gpm -R` repeater
or stop gpm before X in startx (choose simplest, note).

## 4. SESSION & INTEGRATION
`/usr/bin/startx` (ours, tiny shell, not xinit's): stop gpm if running, exec
Xfbdev on vt from fbdev, launch dwm + one st via .xinitrc default
(user-overridable). Nothing X in rcS; nothing at boot (the rock does not draw
until asked). `startx` on 8 MB expects the swap-on-persist parameter documented
beside it. RAM budget (record actuals): Xfbdev ~2-3 MB + dwm <0.5 MB + st ~0.5-1
MB on 8 MB total = tight-but-1995 with swap; comfortable at 16 MB+.

## 5. CI (X becomes an invariant, no display required)
New boot-test variant `gui` (full-system QEMU, -vga std, 32 MB): boot → login
(serial) → `startx &` → settle → QEMU monitor `screendump` (PPM) → assert: (a)
not uniformly black, (b) golden-image compare vs a blessed reference render of
dwm bar + st at 800x600 (blessing discipline per house TDD; reviewer countersigns
goldens). Second assertion in-guest: `DISPLAY=:0 xdpyinfo` (or a 20-line Xlib
probe if xdpyinfo drags deps) exits 0. 486 GUI check stays MANUAL/testimonial
(QEMU -cpu 486 -m 8 + swap runnable locally, journal entry); gate CI on the 32 MB
variant; the world proves the 8 MB hardware.

## 6. MILESTONES
- G1 Recon + monolith-xserver lane decision (A/B/C) + Xfbdev boots against a
  fixture fb in QEMU, BARE (just X + xsetroot color change, screendumped — proves
  server before any client).
- G2 Proto/lib stack + st-noxft: X + st, screendump golden.
- G3 dwm + dmenu de-Xft'd via savedconfig; fonts package; the real golden (bar +
  st). startx script. CI variant lands.
- G4 Serial-mouse path: inputattach in world + doc; PS/2 verified in QEMU, serial
  verified by operator on iron.
- G5 Report (`.batteries/reports/gui.md`): sizes, RAM actuals at 8/16/32, the lane
  chosen and why, what xterm would drag in, three worst fights. Update
  RELEASE-READINESS GUI line.
Follow-ups (not v1): xterm (drags Xt/Xaw) · Worker file manager (Xlib, static) ·
Window Maker second-act eval · Stele x11 backend rendezvous (Stele speaks raw
wire protocol, needs none of this stack except the running server — note the interface).

## 7. WHAT NOT TO DO
No Xorg. No Xft/fontconfig/freetype (v1 hard line; a follow-up may relitigate for
Pentium-up ONLY if bitmap fonts are ever truly insufficient — operator doubts it).
No display manager, ever. No compositor, ever. No autostarting X. No second GUI
stack for the 486 — if it doesn't fit in 8 MB with swap, it gets lighter or it
waits; it does not fork the stack.
