# The Monolith — Agent Working Guide

**Read this first if you are an AI agent (or new contributor) picking up work on this repo.**

`README.md` and `docs/` document *what the system is and how it's built* — read those for
architecture (build pipeline, boot matrix, attestation, package set). **This file captures the
tacit knowledge that you cannot grep for**: the design doctrines, how the maintainer wants work
done, and the hard-won traps and recipes discovered while building this. Keep it updated — it is
the durable handoff record.

The project owner is **Tucker McLean** (me@tuckermclean.com), the sole developer. He is
technically deep (Gentoo internals, CI/CD, SLSA/attestation, low-level boot), cost-conscious
about AWS/CI spend, and terse. He values getting to the point over exhaustive option surveys.

---

## Design doctrines — hard rules

Violating these wastes his time. When in doubt, ask "would this run on a 486?"

- **486-target minimalism.** Everything must run on an i486 with a few MB of RAM. Do not pull in
  heavy dependencies. The reflex challenge to any addition is *"we're trying to run this on a 486,
  remember?"*
- **rootfs is all-static.** Dynamic binaries fail at boot. The "musl libc not found" warning means
  static-only, not benign.
- **Python stays out** of the target rootfs. See the tmpfiles→systemd-utils→python trap below.
- **Bitmap-only fonts. NO freetype / fontconfig / Xft.** The disc ships bitmap fonts (Terminus is
  the default X font). Any package that drags in freetype — commonly via `font.eclass` →
  `x11-apps/mkfontscale` → `media-libs/freetype` — is rejected. Break the chain with
  `package.provided`, do not accept the dep.
- **Don't add back things we deliberately removed.** He will notice and be annoyed.
- **The clock-epoch origin sentinel is `1970-01-01` (the Unix epoch) — NOT Y2K.** We fought for
  1970 and 1970 won: `CLOCK_EPOCH_RTC = "1970-01-01T00:00:00"` in `boot-test.py`, "the truest image
  of a machine whose clock never started." A commit once moved it to 2000-01-01, but that was a
  **misdiagnosis** (the `clock-epoch` test was hanging on a long `monolith_time_url=…` ISOLINUX boot
  label, not the RTC) and was reverted — *"Y2K is too late; it occurs AFTER the origin myth in the
  story."* Separately, the runtime `monolith-time-check` recognizes 1970 / 1980 / 2000 as dead-clock
  "ignorance" sentinels (`SENTINELS="0 315532800 946684800"`) because real hardware resets to any of
  them — that's detection breadth, not the origin.

He built an honest, elaborate supply-chain pipeline (SLSA provenance, a digest-chain invariant,
a CVE gate). Releases should come *through* that pipeline and be verifiable. He dislikes UI cruft
(e.g. he had the `g` / `/` keyboard shortcuts ripped out of the dashboard).

---

## How to work with him

- **Standing autonomy grant:** *"as long as it goes with the plan, the tests are meaningful and
  green, you can merge."* On a green CI run for work that fits the agreed direction, merging to
  `master` is authorized without re-asking.
- **Exception — workflow-file / release-machinery changes** (`.github/workflows/*`, the
  release/signing path): he prefers to read first. Open a PR, explain clearly, let him merge.
  He often merges quickly and then says "continue."
- **Pushing workflow files needs a `workflow`-scoped PAT.** The default `gh` token has only
  `gist, read:org, repo`, which GitHub rejects for `.github/workflows/*` pushes. Use a PAT
  **transiently** (inline `git -c credential.helper=…` or an env-scoped `GH_TOKEN`), never written
  to `.git/config` or `gh auth`. **⚠️ A PAT used in the prior chat is exposed in that history and
  MUST be rotated — never carry it forward. Obtain a fresh one or have Tucker push workflow files
  himself.** Never commit a token to the repo.
- **Debugging discipline** (this repo rewards it):
  - **Capture stderr before theorizing.** A `2>/dev/null` once masked a `dd: not found` and sent a
    debugging session chasing the wrong cause. Never hide stderr while debugging.
  - **Instrument both sides of a boundary early** when a multi-component flow misbehaves.
  - **Tests aren't free.** Every boot test must mean something; de-flake rather than pile on
    retries.
- **Recovery instinct he appreciates:** if a build is green but only a downstream publish/wrapper
  step failed, recover from the already-verified artifact rather than triggering a wasteful full
  rebuild (a from-source Monolith build is ~30–60 min).

---

## Build / CI / release essentials

Architecture is in the repo — start with `README.md` (Build instructions), then:
`docs/releasing.md`, `docs/version-pinning.md`, `docs/cve-gate.md`, `docs/kernel-tiers.md`,
and `docs/superpowers/specs/` for design specs.

- **Pinned snapshot epochs:** `BUILD_EPOCH=20260811` (runtime portage tree, mirrored to S3 via
  `sync-portage.sh`) and `TOOLCHAIN_EPOCH=20260810` (builder-image tree, **NOT** mirrored — see the
  time-bomb below). These being equal-prefixed is why the dashboard once mis-sorted builds by tag.
- **Release flow (current, post-#54/#55/#56):** push a `vX.Y.Z` tag → **`build.yml`** triggers
  directly on the tag and does build **+ attest** (it must be the OIDC entry point; see the release
  gotchas) → **`release.yml`** fires via `workflow_run` after Build completes and does *publish
  only* (download the attested ISO from S3, re-verify the digest chain, `gh release create`).
  - Tag builds compile **from source** (skip the binpkg cache + `--usepkg`) so no cached binary
    enters a signed release.
  - A `-rcN`/`-betaN` suffix → GitHub **prerelease**, published `--prerelease --latest=false`
    (GitHub's API forbids a prerelease holding the "Latest" badge). A final `vX.Y.Z` (no suffix)
    becomes "Latest".
  - The **dashboard's** own "LATEST" is independent of GitHub's badge — `generate-dashboard.py`
    sorts builds by attestation **timestamp**.
- **S3 bucket `themonolith` is public-read** (dashboard at `themonolith.s3.amazonaws.com`), so
  built artifacts can be fetched without credentials for verification/recovery.

---

## Traps & hard-won recipes (knowledge base)

Symptom → cause → fix. These cost real debugging time; don't rediscover them.

**Packaging / dependency traps**
- **freetype trap:** `font.eclass` RDEPENDs `mkfontscale` which RDEPENDs `freetype`. Adding any
  bitmap-font package can silently pull freetype in. Fix: `package.provided` the
  `freetype`/`mkfontscale`/`encodings` chain (see `configs/portage/profile/package.provided`).
- **tmpfiles → systemd-utils → python trap:** any `inherit tmpfiles` package (ppp, mutt via
  cyrus-sasl, …) pulls `virtual/tmpfiles` → `systemd-utils[tmpfiles]`, which `REQUIRED_USE`-needs
  Python → emerge fails at dep resolution. Fix options: `package.provided` / an overlay virtual.
- **Overlay-ebuild revbump busts binpkg cache:** editing an overlay ebuild *in place* after its
  first green build silently reuses the stale S3 binpkg under `emerge --usepkg`. Always revbump
  (`-rN`) and bump `versions.lock` to force a rebuild.
- **rootfs files unowned by attestation:** hand-authored `$ROOTFS_DIR` files (init scripts, `/etc`,
  monolith-net) MUST be added to `unowned-allowlist.yaml` or attestation Pillar 4 fails the build.
  Every new one needs an entry. (Longer-term plan: a `monolith-base` ebuild to own them.)
- **cross-toolchain missing `libatomic.a`** — FIXED (PR #32): `EXTRA_ECONF='--disable-shared
  --enable-static'` on `cross-*/gcc` in the Dockerfile (the `static-libs` USE was a no-op).
- **acct-user/dnsmasq collision** (nondeterministic): `acct-user/dnsmasq` can fail pre-merge →
  `--keep-going` drops `net-dns/dnsmasq` → dnsmasq missing from rootfs → nat-router boot test fails.
  A rebuild usually clears it.

**Static cross-build recipes (i486-musl)**
- **Rust:** rustup nightly + `build-std` + 6 link fixes → static i486-musl. First used for `rl144`;
  also how `www-client/stele` builds.
- **perl-cross static musl (`-Uusedl` perl 5.42):** the full gauntlet — `_GNU_SOURCE`,
  `--allow-multiple-definition`, `-DNO_LOCALE`, and the big one: force per-module `pm_to_blib` or
  ship NO static-ext `.pm`.
- **DBD driver can't `static_ext` into `-Uusedl` perl:** `DBD::SQLite`'s `Makefile.PL` needs an
  importable `DBI` at configure time but miniperl can't load DBI's XS. Workaround: the guestbook
  uses the `sqlite3` CLI instead.
- **TinyX Xfbdev static build:** 5 vendored server header shims, no client libs, `Xpoll` from
  xorg-proto, a GCC-14 `-Wno-error` quartet. Lesson: enumerate the whole header gap *before*
  spending another build cycle.
- **X client libs (libX11/libxcb/libXext) cross+static:** dodge the modern-X Python tar-pit with a
  data-only overlay `xcb-proto` (host-python codegen; no target python/libxml2/zstd).
- **X Terminus default font:** bitmap-only, no freetype. `pcf-fontname.py` reads a PCF's `FONT`
  property to generate `fonts.dir`; XLFDs are CamelCase (`-xos4-Terminus-Medium-R-Normal--…`);
  `fonts.alias` maps `fixed`/`variable`/bold/heading.

**Boot / runtime**
- **initramfs busybox lacks `dd` and `findfs`** (stale binpkg): read block-device labels with
  `cat | tr | grep`, not `dd`/`findfs`.
- **nat-router link-local flake:** `monolith-router` skipped assigning the LAN gateway CIDR when
  `eth1` held a failed-DHCP `169.254` link-local. (Instrument both sides of a boundary early.)
- **kernel module tiers:** three-tier (Tier 0/1/2) driver split balancing the 486 vs modern UEFI
  boxes — full writeup in `docs/kernel-tiers.md`.

**CI / release**
- **`actions/attest` can't persist from a reusable workflow:** GitHub binds the Sigstore cert SAN
  to the *entry* workflow. Calling `build.yml` via `workflow_call` from `release.yml` failed with
  `values do not match: build.yml != release.yml`. Fix: build.yml owns the tag trigger; release.yml
  publishes via `workflow_run`. (PR #55.)
- **A prerelease can never be GitHub "Latest"** — `HTTP 422: Latest release cannot be draft or
  prerelease`. Publish prereleases `--prerelease --latest=false`. (PR #56.)
- **Recovery pattern:** when Build is green but publish failed, download the exact ISO + `bom.cdx.json`
  + `attestation-summary.json` from public S3, re-verify `sha256(ISO) == attestation-summary.iso_sha256
  == SBOM metadata.component.hashes[0]` **and** `gh attestation verify`, then `gh release create`
  manually. The SLSA attestation lives in GitHub's store keyed to the ISO sha, so it verifies for
  downloaders regardless of who cut the release.

**Cost / infra watch-items**
- **S3 bucket unbounded growth:** the build bucket has no lifecycle policy; every CI build leaves
  versioned ISO/squashfs sets + package caches, never pruned. Costs money. Needs cleanup + a
  lifecycle policy.
- **CI transfer cost:** S3 egress (repeated ISO downloads used as a job bus) is the big AWS cost.
  Spec + plan on branch `feat/ci-transfer-cost` and `docs/superpowers/specs/…-ci-transfer-cost-design.md`
  (S3 → publish-only via `actions/cache`). K3s option deferred.
- **Builder-image toolchain-epoch time-bomb:** the builder image is currently un-rebuildable because
  its pinned `TOOLCHAIN_EPOCH` portage snapshot was pruned upstream and is not mirrored to S3 (unlike
  the runtime `BUILD_EPOCH` tree). Any Dockerfile change or cache expiry breaks *all* builds. Fix
  plan: mirror the toolchain tree to S3 like the runtime tree. **Flagged, not yet done.**

---

## Roadmap (deferred, owner-aware)

- **Networking-box arc (SP1–SP5):** netboot is deferred behind a persistence → initrd-mod UI.
- **Stele browser** (`www-client/stele`): Rust i486 browser, currently direct-framebuffer; an X11
  wire backend is on the roadmap. REPIN it each build.

---

## Current status (2026-08-21, at harness handoff)

*Verify against `git log` and `gh` before trusting — this is a point-in-time snapshot.*

- **`master` = `e20a252`.** The release pipeline is complete and correct end-to-end after three
  merged PRs: **#54** (from-source tag builds + dashboard timestamp sort), **#55** (decouple
  attest/publish via `workflow_run`), **#56** (prereleases never "Latest").
- **`v0.1.0-rc1` is published** — prerelease, attestation verifies green, shows as LATEST on the
  dashboard. It was published from the verified S3 artifact (the recovery pattern above); the *next*
  tag will publish fully automatically.
- **Open threads (none urgent):** rotate the exposed workflow PAT; fix the builder toolchain-epoch
  time-bomb; add an S3 lifecycle policy; the `feat/ci-transfer-cost` work; the intermittent
  acct-user/dnsmasq build flake.

---

*Note for maintainers: the outgoing agent kept per-fact notes in a Claude Code memory directory that
does not travel between harnesses. This file supersedes those notes as the in-repo durable record —
add to it here rather than relying on any external memory.*
