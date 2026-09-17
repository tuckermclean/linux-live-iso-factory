# Legacy fbdev drivers as Tier-2 modules — implementation plan

*Spec: `docs/superpowers/specs/2026-09-17-legacy-fbdev-design.md`. Tracking: DCX-43 (child of DCX-42).*
*Branch: `dcx-43-legacy-fbdev`.*

Read the spec first — it holds the driver list, the exclusion rationale, and
the two traps (empty-at-default chip sub-options, and the DDC → `CONFIG_I2C=y`
escalation) that this plan encodes. Work the tasks in order; each one is
independently reviewable.

---

## Task 1 — enable the driver set in `configs/kernel.config`

Edit `configs/kernel.config` directly. `olddefconfig` preserves valid symbols
and only erases comments, which is why the policy lives in the spec and the doc
rather than in the file.

- [ ] Flip these 24 from `# CONFIG_X is not set` to `CONFIG_X=m`:
      `FB_CIRRUS`, `FB_PM2`, `FB_PM3`, `FB_CYBER2000`, `FB_VGA16`, `FB_HGA`,
      `FB_NVIDIA`, `FB_RIVA`, `FB_I740`, `FB_MATROX`, `FB_RADEON`, `FB_ATY128`,
      `FB_ATY`, `FB_S3`, `FB_SAVAGE`, `FB_SIS`, `FB_NEOMAGIC`, `FB_KYRO`,
      `FB_3DFX`, `FB_VOODOO1`, `FB_VT8623`, `FB_TRIDENT`, `FB_ARK`, `FB_SM712`.
- [ ] Set `CONFIG_FB_GEODE=y` (bool menu gate, no object file — see the spec on
      why this is not a Tier-0 addition) and add `CONFIG_FB_GEODE_LX=m`,
      `CONFIG_FB_GEODE_GX=m`, `CONFIG_FB_GEODE_GX1=m`.
- [ ] Add the chip sub-options that the drivers are useless without:
      `CONFIG_FB_MATROX_MILLENIUM=y`, `CONFIG_FB_MATROX_MYSTIQUE=y`,
      `CONFIG_FB_MATROX_G=y`, `CONFIG_FB_MATROX_I2C=m`, `CONFIG_FB_ATY_CT=y`,
      `CONFIG_FB_ATY_GX=y`, `CONFIG_FB_SIS_300=y`, `CONFIG_FB_SIS_315=y`.
- [ ] Force the DDC traps off — these are `bool`s whose `y` would escalate
      `FB_DDC` to `y` and drag `CONFIG_I2C` into `bzImage`:
      `# CONFIG_FB_RADEON_I2C is not set`, `# CONFIG_FB_3DFX_I2C is not set`,
      `# CONFIG_FB_CYBER2000_DDC is not set`,
      `# CONFIG_FB_NVIDIA_I2C is not set`, `# CONFIG_FB_SAVAGE_I2C is not set`.
- [ ] Do **not** hand-write the symbols `olddefconfig` is expected to derive
      (`VGASTATE`, `FB_SVGALIB`, `FB_DDC`, `I2C`, `I2C_ALGOBIT`,
      `FB_TILEBLITTING`, `FB_BACKLIGHT`, `BACKLIGHT_CLASS_DEVICE`). Letting the
      build produce them is what makes Task 4's assertion meaningful.
- [ ] Leave every excluded symbol at `# … is not set`. Do not touch
      `FB_VESA`/`FB_EFI`/`FB_SIMPLE`/`FB_HYPERV`.

**Done when:** `git diff configs/kernel.config` touches only the lines above,
and no line in the diff sets an excluded symbol.

---

## Task 2 — revbump the kernel so CI actually rebuilds it

An unchanged ebuild version under `--usepkg` reuses the stale S3 binpkg, and the
new config never gets compiled.

- [ ] `git mv configs/overlay/sys-kernel/monolith-kernel/monolith-kernel-6.12.80-r6.ebuild`
      → `…-r7.ebuild` (content unchanged) and regenerate/adjust `Manifest` if
      the repo's flow requires it.
- [ ] Bump `configs/portage/versions.lock`:
      `sys-kernel/monolith-kernel:6.12.80-r6:0` → `…-r7:0`.
- [ ] Sanity-check the consumers of that pin that strip `-rN`: the
      `expected-kernel` job in `.github/workflows/boot-test.yml` and the NIC
      assertion step in `build.yml` both do
      `sed -E 's/-r[0-9]+$//'`, so `uname -r` is unaffected. Confirm, don't
      assume.
- [ ] Check the "Purge stale savedconfig binpkgs" step in `build.yml` — if it
      already forces a kernel rebuild on a `kernel.config` change, say so in the
      PR and keep the revbump anyway for cache hygiene.

**Done when:** the pinned version, the ebuild filename, and any manifest agree,
and nothing else references `-r6`.

---

## Task 3 — intent check: `scripts/tests/verify-legacy-fbdev-config.sh`

Model it on `scripts/tests/verify-nic-zoo-config.sh` — same shape, same
`ALL PASS` / `exit 1` contract. `pr-validate.yml` already loops over
`scripts/tests/*.sh`, so no workflow edit is needed to run it, and
`shellcheck --severity=error` already covers the directory.

- [ ] Assert each of the 24 driver symbols is exactly `^CONFIG_<sym>=m$`.
- [ ] Assert `CONFIG_FB_GEODE=y` and the three `FB_GEODE_*=m`.
- [ ] Assert the eight chip sub-options at their required values.
- [ ] Assert the five DDC sub-options are `# … is not set`, with a comment
      naming the reason (`bool=y` → `FB_DDC=y` → `CONFIG_I2C=y`), so a future
      reader doesn't "fix" the test by turning them on.
- [ ] Assert `CONFIG_I2C` is **not** `=y` — the actual invariant those five
      lines exist to protect. `=m` is fine and expected; `=y` is the failure.
- [ ] Assert every excluded symbol from the spec is still `# … is not set`,
      including `FB_ASILIANT`, `FB_IMSTT`, `FB_VIRTUAL`.
- [ ] Re-assert the covenant: `CONFIG_EXTRA_FIRMWARE` must not be set.
- [ ] `sh scripts/tests/verify-legacy-fbdev-config.sh` prints `ALL PASS` and
      `shellcheck --severity=error` is clean.

**Done when:** the script passes on the Task-1 tree and *fails* if you flip any
one asserted symbol — verify both directions before moving on.

---

## Task 4 — build-time proof in `.github/workflows/build.yml`

Add a step **"Assert legacy fbdev kernel modules built and shipped"**
immediately after the existing "Assert NIC kernel modules built and shipped"
step, reusing its `KVER`/`LOCALVERSION`/`MODDIR` derivation verbatim.

- [ ] Assert all 27 `.ko` files exist under `$MODDIR`:
      `cirrusfb pm2fb pm3fb cyber2000fb vga16fb hgafb nvidiafb rivafb i740fb
      matroxfb_base radeonfb aty128fb atyfb s3fb savagefb sisfb neofb kyrofb
      tdfxfb sstfb vt8623fb tridentfb arkfb sm712fb lxfb gxfb gx1fb`
      (module names resolved from the per-driver `Makefile`s at `v6.12.80` —
      note `matroxfb_base`, not `matroxfb`; `neofb`, not `neomagicfb`;
      `sstfb` for `FB_VOODOO1`). Collect all misses and report them together,
      as the NIC step does.
- [ ] Enforce the firmware doctrine: for each module, `modinfo -F firmware` must
      print nothing. Fail loudly listing any module that declares one. Guard for
      `modinfo` availability on the runner and install `kmod` if absent.
- [ ] Echo the count on success, matching the NIC step's output style.

**Done when:** the step is a faithful sibling of the NIC step and `actionlint`
is clean.

---

## Task 5 — runtime proof: `cirrusfb` coldplug boot test

In `scripts/boot-test.py`, add a mode that is to `build_nic_cmd` what the NIC
matrix is to the BIOS path.

- [ ] Add `build_vga_cmd(args)`: `build_bios_cmd(args)` plus
      `["-vga", args.vga_model]`. Raise `BootTestError` if `--vga-model` is
      missing, mirroring `build_nic_cmd`'s guard.
- [ ] Add `--vga-model` (default `None`) to the argument parser and register the
      new mode in `MODE_RUNNERS`.
- [ ] Add `VGA_MODEL_MODULE = {"cirrus": r"^cirrusfb\b"}` and
      `smoke_vga_model_is_module(child, model)` asserting `lsmod` matches,
      modelled on `smoke_nic_model_is_module`.
- [ ] Runner: boot the `serial vga=788` ISOLINUX label as the other BIOS modes
      do, run the reduced smoke suite, then append the `cirrusfb` check.
- [ ] Write the docstring to say *why* this proves something: `-vga cirrus` is a
      real PCI GD5446 with a real modalias, so a `cirrusfb` in `lsmod` proves
      coldplug matched a **graphics** device and the Tier-2 pipeline delivered
      the driver.
- [ ] Wire a job into `.github/workflows/boot-test.yml` alongside the NIC matrix
      job, restoring the ISO from the in-run cache the same way.

**Expected-behaviour note for whoever implements this:** with `vga=788`, vesafb
owns `/dev/fb0` first and `cirrusfb` will call
`remove_conflicting_pci_framebuffers` on probe. The console here is serial, so a
handover does not disturb pexpect — and the assertion is deliberately "the
module is resident," not "it owns `fb0`", because residency is what proves the
coldplug mechanism. If `cirrusfb` turns out to load *and* fail probe, that is
still a pass. If it does not appear in `lsmod` at all, that is a real failure:
debug it, don't relax the assertion. **Capture stderr / the full serial log
before theorising** — that discipline is in `AGENTS.md` for a reason.

---

## Task 6 — document the tier membership

- [ ] Add the set to `docs/kernel-tiers.md` under Tier 2, in the style of the
      existing Phase-1 table: symbol, `=m`, driver, and a one-line note that
      these are native framebuffers layered over the vesafb/efifb console
      rather than replacing it.
- [ ] Note the two mechanism-excluded symbols (`FB_ASILIANT`, `FB_IMSTT`) so
      nobody re-proposes them without arguing the Tier-0 case.
- [ ] Record the `FB_TILEBLITTING=y` core addition as the one deliberate
      `bzImage` growth.
- [ ] Add a line to `AGENTS.md`'s traps section for the DDC → `CONFIG_I2C=y`
      escalation. It is a genuine "cost real debugging time" trap: a `bool=y`
      sub-option silently promoting a `tristate` it `select`s, and through it a
      whole subsystem, into the built-in kernel.

---

## Task 7 — measure, then hand off

- [ ] Record in the PR description, per `docs/kernel-tiers.md`:
      `bzImage` before/after, rootfs squashfs before/after, ISO before/after,
      and **initrd before/after — which must be unchanged.** A changed initrd
      means something landed in Tier 1 by mistake; stop and fix it.
- [ ] Open the PR against `master` from `dcx-43-legacy-fbdev`. Do not push
      `.github/workflows/*` without a `workflow`-scoped token (see `AGENTS.md`);
      `GITHUB_WORKFLOW_TOKEN` in the run environment carries that scope. Use it
      transiently — never write it into `.git/config` or `gh auth`.
- [ ] Get CI green: `pr-validate` (shellcheck + actionlint + the new Task-3
      test), `build`, and the full boot matrix including the new VGA job.
- [ ] Post the CI run link, the 27-module list from the Task-4 step output, and
      the size deltas on DCX-43.
- [ ] Hand to the Code Reviewer, then QA. Do not self-merge.

---

## Out of scope (named so it isn't silently absorbed)

- A `monolith fb probe` verb for the modalias-less `vga16fb` / `hgafb`.
- Console acceleration sub-options (`FB_SAVAGE_ACCEL`, `FB_3DFX_ACCEL`) — left
  at their `n` defaults; a separate, measurable question.
- Re-litigating `FB_ASILIANT` / `FB_IMSTT` as Tier 0.
- Restoring DDC on `radeonfb` / `tdfxfb` / `cyber2000fb`, which would require
  accepting `CONFIG_I2C=y`.
