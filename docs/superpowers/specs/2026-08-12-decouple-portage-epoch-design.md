# Decouple the Portage Epoch from the Builder Image — Design

**Status:** approved (direction + scope decisions); pending spec review → plan.
**Date:** 2026-08-12
**Branch:** `feat/decouple-portage-epoch` (off `master`).

## Problem

Two coupled fragilities in the builder-image build:

1. **A data refresh forces a toolchain rebuild.** The image is built in two stages:
   `base-tools` (`FROM gentoo/stage3:…-${BUILD_EPOCH}` + `emerge-webrsync --revert=${BUILD_EPOCH}`
   to bake the portage tree + host tools), then the crossdev toolchain
   (i486-musl gcc/binutils/musl) built on top and `docker commit`-ed. The push/rebuild gate is
   `COMBINED_HASH = sha256(BASE_HASH + crossdev.lock + binutils/headers vers)`, and `BASE_HASH`
   is the base-tools **image layers — which include the baked snapshot**. So bumping `BUILD_EPOCH`
   (a pure package-version data refresh) changes `BASE_HASH` → changes `COMBINED_HASH` → **rebuilds
   the entire crossdev toolchain (~100 min)** even though the toolchain pins (`CROSS_GCC_VER`,
   `CROSS_MUSL_VER`, `CROSS_BINUTILS_VER`, `crossdev.lock`) did not change.

2. **Snapshot pruning breaks every build.** The snapshot is fetched from Gentoo mirrors
   (`emerge-webrsync --revert`) both in the Dockerfile and at runtime by `sync-portage` (into the
   `monolith-repos` volume). Gentoo prunes daily snapshots after ~5 days; when the pinned snapshot
   expires the sync 404s and **all builds fail** (observed: `20260803` expired → total outage).

## Design: two independent pins

- **`TOOLCHAIN_EPOCH`** (new) — pins the image: the stage3 base + the portage tree the crossdev
  toolchain and host tools build against, baked into the image. Bumped **rarely and deliberately**
  (human-gated in this effort). The image's rebuild hash no longer includes the *runtime* snapshot,
  so a snapshot bump never rebuilds it.
- **`BUILD_EPOCH`** (kept; now purely the **runtime portage-snapshot** pin) — the tree packages are
  built against, **injected at build time from our self-hosted S3** (immune to upstream pruning).
  `SOURCE_DATE_EPOCH` still derives from `BUILD_EPOCH`; `versions.lock` regenerates from it.

Net: routine currency = bump `BUILD_EPOCH` → swap snapshot + regen `versions.lock` → validate →
auto-merge. **No image rebuild; minutes, not ~100 min; immune to pruning.**

## Components

1. **Dockerfile** — `FROM gentoo/stage3:…-${TOOLCHAIN_EPOCH}`; `emerge-webrsync --revert=${TOOLCHAIN_EPOCH}`
   (the baked tree is now the *toolchain's*, not the runtime snapshot). Host tools/crossdev unchanged
   otherwise. `BUILD_EPOCH` is removed from the image build inputs.
2. **`scripts/sync-portage.sh`** (resilient, self-hosted) — replaces the bare
   `emerge-webrsync --revert=$BUILD_EPOCH`. Fetch order per snapshot file
   (`gentoo-$BUILD_EPOCH.tar.xz` + sidecars): **our S3** (`s3://$BUCKET/portage-snapshots/`) →
   upstream distfiles (then **archive to S3**). The fetch/archive runs on the **runner** (has `aws` +
   creds), places the files into a container-visible mount, and `emerge-webrsync` consumes them via a
   local `file://` GENTOO_MIRRORS entry (upstream as fallback) — **GPG verify + extraction preserved**.
   Fail-closed only if neither ours nor upstream has it.
3. **Lock split** — `crossdev.lock` ↔ `TOOLCHAIN_EPOCH` (toolchain); `versions.lock` ↔ `BUILD_EPOCH`
   (target packages, regenerated on snapshot bump). Document the split in `docs/version-pinning.md`.
4. **S3 archiving + backfill** — archive the pinned snapshot on every successful fetch; **backfill the
   live snapshots (`20260808/10/11`) to S3 immediately** so we're covered before they prune.
5. **pin-bump rework (full)** — split into two flows:
   - **Routine snapshot currency** (frequent, cheap, auto): bump `BUILD_EPOCH` → verify+archive the
     snapshot to S3 → regen `versions.lock` (no image rebuild) → full build+boot+attestation
     validation → **auto-merge on fully-green** (routine dependency currency, no human in the loop);
     any red → PR labeled `needs-fixup`, no merge.
   - **Toolchain bump** (rare, human-gated): bump `TOOLCHAIN_EPOCH` (+ `CROSS_*_VER`/crossdev pins) →
     rebuild+commit+push image → regen `crossdev.lock` → validation → open a PR a **human merges**
     (toolchain changes are consequential). *(Deferred follow-up: put this on a regular maintenance
     schedule — the user wants TOOLCHAIN_EPOCH bumped periodically too, just not in this effort.)*
6. **`build.yml`** — the "Sync portage" step passes `S3_BUCKET` + AWS creds through to
   `scripts/sync-portage.sh`; `build-image` and the snapshot sync are no longer coupled.

## Data flow (after)

```
every build:  image (cached, pinned TOOLCHAIN_EPOCH)  +  sync-portage injects BUILD_EPOCH snapshot
              from our S3  ->  build packages with the toolchain against the runtime snapshot.
routine bump: bump BUILD_EPOCH -> archive+verify snapshot on S3 -> regen versions.lock
              -> full validation -> AUTO-MERGE.  Image untouched.
toolchain bump (rare, human): bump TOOLCHAIN_EPOCH/crossdev pins -> rebuild+push image
              -> regen crossdev.lock -> validation -> human PR.
```

## Error handling

- Snapshot missing from **both** our S3 and upstream → fail loudly (only reachable if never archived
  AND upstream pruned; backfill + archive-on-fetch prevents it going forward).
- **Toolchain↔snapshot skew** (a package needs a newer gcc/musl than the pinned toolchain provides) →
  surfaces as a build error → signal to bump `TOOLCHAIN_EPOCH` deliberately. Rare (gcc/musl are stable
  across weeks; both pins are ours).
- `emerge-webrsync` GPG verification still gates the snapshot (security unchanged).
- pin-bump auto-merge triggers only on a fully-green validation.

## Reproducibility / attestation

Both epochs are pinned; the snapshot is self-hosted (exact bytes preserved as long as we pin it).
`SOURCE_DATE_EPOCH` derives from `BUILD_EPOCH` as before. The target package set is unchanged (same
tree, served from our mirror), so SBOM/SLSA/attestation are unaffected.

## Non-goals / deferred

- **Self-hosting the stage3 base** (deferred, low risk — image cached in our GHCR; `TOOLCHAIN_EPOCH`
  bumps are rare and hit a fresh stage3). Revisit if it ever bites.
- **Scheduled TOOLCHAIN_EPOCH maintenance cadence** (deferred follow-up per user; this effort makes
  the toolchain bump a clean human-gated flow, ready to be put on a schedule later).
- No change to the target package set or the build itself.

## Testing / acceptance

- **CI is the gate** (build-system change; no local unit test for the crossdev image), except the
  unit-testable `sync-portage.sh` fetch/fallback/archive logic (stub `aws`+`wget`, like `s3-gc.test.sh`).
- **Acceptance:**
  1. A `BUILD_EPOCH` bump does **not** rebuild the crossdev toolchain (`base-tools-hash` unchanged;
     `build-image` reports "up to date") and completes in minutes.
  2. `sync-portage` fetches the snapshot from **our S3** (log shows the S3 hit; no upstream fetch).
  3. A build succeeds on a snapshot that is **404 upstream** but archived in our S3 (simulate with an
     already-pruned epoch we've backfilled, e.g. `20260803` once re-archived — or `20260808` after it
     prunes).
  4. Full build+boot+attestation green at the pinned epoch.
  5. A routine pin-bump run auto-merges on green **without** an image rebuild.

## Success criteria

1. Routine epoch (snapshot) bumps do not rebuild the builder image — minutes, not ~100 min.
2. Builds never fail from upstream snapshot pruning (self-hosted).
3. Routine bumps auto-merge on green; toolchain bumps are a separate, human-gated (later: scheduled) flow.
4. Reproducibility + attestation unchanged.
