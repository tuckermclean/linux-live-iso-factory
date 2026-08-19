# Monolith UX Pass — Implementation Plan

> **For agentic workers:** use superpowers:subagent-driven-development or
> superpowers:executing-plans, task-by-task, checkboxes tracked. Ground-truth
> every "currently" claim below against the tree before changing it.

**Goal:** One ergonomic pass over the whole disc UX: discoverability (a front
door for the helpers that already exist), continuity (persist-aware dotfiles),
one landmine (clock vs TLS), and boot/console polish. Solid, not Red Hat: no
wizards, no daemons, no menus — text files, tiny POSIX-sh scripts in
monolith-base, and hints that print once in the right place.

**Doctrine constraints:** nothing autostarts that listens; hints are one-shot
and quiet on subsequent logins where feasible; every new script is unit-tested
standalone like monolith-net; profile must stay FAST on a 486 (budget: no
network calls, no subprocess storms — measure `time bash -lc true` before and
after, keep the delta under ~200ms at -cpu 486).

## Task 1: `monolith` — the front door (the biggest gap)

The disc has helpers (monolith-router, monolith-net, monolith-console,
startx, guestbook.cgi) and rich tools (perl, sqlite3, dnsmasq, pppd, gdb,
irssi, mutt, w3m, nethack...) but nothing that LISTS them. New
monolith-base file: `/usr/bin/monolith` (POSIX sh):

- [ ] `monolith` / `monolith help` — one screen: the disc in five lines,
  then "topics: network, web, persist, gui, dev, games, verify" and
  "tools" / "help <topic>" usage. Deadpan register, no box-drawing art.
- [ ] `monolith tools` — grouped one-line inventory (name — what it is),
  generated from a static text file in monolith-base (NOT from scanning
  PATH — curated beats complete).
- [ ] `monolith help <topic>` — cats /usr/share/monolith/<topic>.txt through
  $PAGER. Write the topics from existing canon: network (router lecture
  pointer, monolith-net ISA liturgy, dhcpcd one-liner, ppp chat example),
  persist (label + mkfs + swap), gui (startx, serial mouse inputattach
  line), verify (the gh attestation command + sha256 cross-check), web
  (browser lineup incl. w3m/lynx + proxy note), dev (perl+sqlite+CGI
  guestbook walk-through), games.
- [ ] Unit test: every topic file referenced exists; help output under 25
  lines; script passes shellcheck like monolith-net.

## Task 2: THE CLOCK LANDMINE (blocks https on real old iron)

No NTP/rdate/chrony in world. A dead-RTC machine boots at the Unix epoch
and openssl rejects every certificate — TLS-by-delegation dies on the
flagship machine.

**INVARIANT (write it at the top of the script): The Monolith never
assumes what year it is. It's a rock. Rocks are patient.** The trigger is
NEVER date plausibility — a 486 booted in 1996 has a CORRECT clock, and a
plausibility check would declare a true date broken and phone the future
to "fix" it. The only detectable condition is IGNORANCE: a dead RTC
reports the epoch (or the RTC's own reset date), and clock-at-epoch is no
machine's true present in any decade this disc serves.

- [ ] monolith-base: `monolith-time` — sets the clock from an HTTP Date
  header (curl -sI over plain http to a configurable URL, parse Date,
  `date -s`, then `hwclock -w` if an RTC exists). No new packages, no
  daemon, ~1s accuracy (plenty for cert validity). Legible failure if
  offline. The tool has NO opinion about which decade it lands in: run
  in 1996, it believes 1996's servers — it reports what the network
  says, it never "corrects" toward any assumed present.
- [ ] Boot integration, gated and quiet: run ONLY when (a) an interface
  is up AND (b) the clock reads within a small window of the epoch /
  known RTC-reset dates (document the exact window + reset dates
  checked). Fires on the battery-dead machine; silent on every machine
  that has an opinion — including a correct 1996 clock. Never a
  boot-time network wait otherwise. Never overrule a clock that claims
  to know something.
- [ ] Login hint (profile.d, interactive, only in the ignorance case),
  in the machine's-ignorance register with BOTH remedies at equal
  billing: "This machine does not know what time it is. TLS
  certificates require a date. Set it:  date MMDDhhmmYYYY   — or ask
  the network:  monolith-time". Typing the date by hand is the
  period-correct answer and gets first position.
- [ ] Boot-tests, BOTH directions: (a) QEMU RTC at epoch + fixture HTTP
  server → monolith-time corrects the date; (b) **QEMU RTC set to
  1996 → assert NO clock warning, NO network call, date left exactly
  as the machine believes it.** The disc must pass CI in the year it
  was built for.

## Task 3: Persist continuity (the disc remembers you, when asked)

- [ ] profile.d/20-persist.sh: if /mnt/persist (verify actual mountpoint in
  rootfs/init) is mounted: export HISTFILE to persist, symlink-or-source
  ~/.vimrc, ~/.inputrc, /etc/profile.local from persist/home/ if present.
  One-line login status: "persist: mounted (N MB free)" vs a single quiet
  "persist: none (see monolith help persist)".
- [ ] monolith-base: `monolith-persist init <dev>` — the mkfs.ext4 + label
  MONOLITH_PERSIST liturgy as a script with one confirmation (it names
  the device and its current contents' fate; then it obeys — informs,
  doesn't obstruct). Optional `--swap N` creates the swapfile the 8MB GUI
  doctrine expects. Verify the `swap` boot param's current state in init
  first; wire or note.
- [ ] Boot-test persist variant extends: HISTFILE lands on persist; a
  command typed pre-reboot is in history post-reboot.

## Task 4: Boot menu literacy

- [ ] Locate boot menu generation (build-iso.sh writes isolinux.cfg/grub
  — verify). Add one-line descriptions per label (fb800 vs vga vs serial
  vs toram vs rescue vs persist/swap params) via ISOLINUX F1 help text
  (DISPLAY/F-key files) and matching GRUB menu comments. The labels are
  currently tribal knowledge; make F1 the tribe.
- [ ] Keep default label + timeout as-is; this task adds words, not
  behavior.

## Task 5: Console comfort (cheap, visible)

- [ ] Terminus on the CONSOLE too: ship the PSF console font + setfont in
  rcS (verify kbd/console-tools presence in world; if absent, weigh the
  package cost vs skip — note the decision). The kid's font, everywhere.
- [ ] fortune on interactive login (fortune-mod is in world): profile.d,
  interactive+once-per-boot guard (flag in /run), AFTER the useful hints
  so wisdom never buries status.
- [ ] bash command_not_found_handle (bash ships it): "not on the disc.
  'monolith tools' lists what is." — 5 lines in the profile, gated to
  interactive.
- [ ] Non-US keyboards: document `loadkeys`-equivalent status honestly in
  monolith help gui — if no keymap tooling is aboard, say so there and
  file it as a future world decision rather than pretending.

## Task 6: Hint hygiene (make the good manners consistent)

- [ ] Audit all profile.d hints (dropbear, new persist, clock-ignorance,
  fortune) into one ordering contract: status lines first (persist,
  clock), actionable hints second (dropbear), fortune last, total budget
  ≤ 10 lines on a clean boot. Hints that repeat every login get /run
  flags where annoyance > value (dropbear: keep every login — it's a
  security posture reminder; that one repeats on purpose. Say so in a
  comment.)
- [ ] motd stays: slab + version. issue stays: the no-password warning is
  correct and honest; do not soften it.

## Task 7: Verify docs land + report

- [ ] All topic files installed by monolith-base ebuild (revbump; note the
  binpkg purge trap in the PR if savedconfig-adjacent anything changes).
- [ ] Boot-test smoke additions: `monolith help` exits 0; `monolith tools`
  lists monolith-router; command_not_found handler fires.
- [ ] .batteries/reports/ux-pass.md in house style: before/after login
  transcript (clean boot, persist boot, dead-clock boot), the profile
  timing measurement, decisions taken.

## Explicitly NOT doing (solid, not Red Hat)

No display manager, no first-boot wizard, no config TUI, no colorized
everything, no MOTD news system, no telemetry-shaped "welcome" flows, no
auto-starting anything that listens. The disc's manners: state facts once,
offer the next command, get out of the way.
