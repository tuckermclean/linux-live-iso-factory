# CI Efficiency — Round 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the remaining per-run transfer and time waste in build.yml
now that the 2026-08-11 transfer-cost plan's in-run cache handoff is live.
Primary target: the full-epoch binpkg restore (`aws s3 sync packages/<epoch>/
→ output/packages/` — every gpkg ever built, downloaded every build). Secondary
targets: redundant builder-image pulls, doubled large-artifact uploads,
per-run grype DB and pip downloads, and boot-test runner-setup overhead.

**Architecture:** Move the binpkg store off S3 onto GHCR (free, fast transfer
to Actions runners) as a single-layer OCI artifact per epoch, with an in-epoch
prune so the store carries only current-best gpkgs. Convert "latest" pointer
uploads to S3 server-side copies. Gate the build-image job on a manifest
check. Cache the grype DB and preinstall python tooling in the builder image.

**Prior art / do not redo:** ISO+squashfs in-run handoff (actions/cache,
fail-closed), S3 publish gating to master/tags, gc.yml, incremental
attestation-summary sync, pin-bump hardening — all landed. Leave them alone.

## Global Constraints

- **Correctness caches fail OPEN; handoff caches fail CLOSED.** A missing
  binpkg store must degrade to building from source (slow, correct). The
  existing ISO/squashfs handoff stays fail-on-cache-miss: true. Never invert
  these.
- **S3 remains publish-only** (established doctrine). This plan REMOVES the
  last big S3 read (binpkgs); it must not add new ones.
- **The attestation chain is untouched.** Binpkg storage location is build
  plumbing; SBOM/SLSA inputs and the gate are unchanged.
- **Measure before migrating.** Task 1 produces numbers; Task 2's mechanism
  choice is conditional on them. Do not skip to the mechanism.
- **Validation is a green `full-ci` run** per house convention. Land as a PR,
  never direct to master.

## File Structure

- `.github/workflows/build.yml` — binpkg restore/save steps replaced; image-
  job gate; server-side latest copies; grype cache (modify)
- `.github/workflows/boot-test.yml` — optional NIC-matrix consolidation
  (modify, Task 6)
- `scripts/binpkg-store.sh` — pack/push/pull/prune of the GHCR binpkg
  artifact (create)
- `scripts/tests/binpkg-store.test.sh` — prune predicate tests (create)
- `.github/workflows/gc.yml` — GHCR epoch-tag cleanup added (modify)
- `Dockerfile` — python check-jsonschema preinstalled (modify)

---

## Task 1: Measure the binpkg working set (gate for Task 2)

- [ ] **Step 1:** One-off workflow_dispatch job (or local run with creds):
  `aws s3 ls --summarize --recursive s3://$S3_BUCKET/packages/$BUILD_EPOCH/`
  → record total GB, object count, and the top-20 largest objects into this
  plan file under "Measurements".
- [ ] **Step 2:** Count superseded gpkgs: same listing, group by ${CAT}/${PN},
  count entries where >1 PVR exists. Record reclaimable GB from pruning.
- [ ] **Step 3:** Time the current restore: from the latest build run's logs,
  record wall-clock of "Restore binary package cache from S3" and "Save
  binary packages to S3". These are the baseline numbers this plan must beat.

## Task 2: Binpkg store → GHCR OCI artifact (the headline fix)

**Mechanism (conditional):** if Task 1 total ≤ 8 GB after pruning, proceed as
specced; if larger, split per-category layers (still one manifest) or fall
back to Task 2-ALT below.

- [ ] **Step 1:** `scripts/binpkg-store.sh` with subcommands:
  - `pack`: tar+zstd output/packages/ → binpkgs.tar.zst (deterministic order,
    --sort=name, numeric owners).
  - `push`: wrap as single-layer image `ghcr.io/<owner>/monolith-binpkgs:
    <BUILD_EPOCH>` (docker import or oras push — pick one, record why; oras
    preferred: no fake container semantics).
  - `pull`: fetch + unpack into output/packages/; MISSING TAG = warn + empty
    dir + exit 0 (fail-open: first build of a new epoch compiles from source,
    exactly like today).
  - `prune`: keep only the newest PVR per ${CAT}/${PN} (plus anything named
    in versions.lock at its locked version); delete the rest from the local
    dir before pack. Pure function over a file listing where possible.
- [ ] **Step 2:** Unit-test the prune predicate (fixture listing with
  multi-PVR packages, versions.lock pins, -rN revisions; assert survivors).
- [ ] **Step 3:** build.yml: replace "Restore binary package cache from S3"
  with `binpkg-store.sh pull`; replace "Save binary packages to S3" with
  `prune → pack → push` (keep `if: always()` — partial progress from a failed
  build is still worth caching, same as today). GHCR login already exists in
  the job.
- [ ] **Step 4:** Keep the S3 packages/ tree READ-NEVER for two weeks
  (rollback insurance), then let gc.yml condemn it per existing retention
  rules. Update the build.yml comment block that documents the old deferral.
- [ ] **Step 5:** savedconfig-cache.sh currently purges stale binpkgs in S3 —
  port its check/mark to operate on the local unpacked store between pull and
  build (same semantics, no S3).
- [ ] **Step 6:** gc.yml: add GHCR cleanup — delete monolith-binpkgs tags for
  epochs not referenced by kept builds (GitHub packages API), mirroring the
  existing S3 epoch retention.

**Task 2-ALT (only if measurements force it):** single-tarball on S3
(`packages-<epoch>.tar.zst`, one GET/one PUT) — still kills the per-object
sync cost, keeps S3 egress. Record the decision either way.

## Task 3: Stop uploading big artifacts twice

- [ ] **Step 1:** In build.yml, for ISO / squashfs / vmlinuz / initrd: upload
  the VERSIONED object from the runner once, then create the latest pointer
  with a server-side copy: `aws s3 cp s3://$B/themonolith-$V.iso
  s3://$B/themonolith.iso` (no runner egress, near-instant). Same pattern for
  all four.
- [ ] **Step 2:** Verify content-type/ACL survive server-side copy as the
  dashboard expects (spot-check headers after the first master build).

## Task 4: Gate the build-image job properly

- [ ] **Step 1:** New first step in build-image: if
  `needs.changes.outputs.dockerfile != 'true'` AND
  `docker manifest inspect $REGISTRY/monolith-builder:$REGISTRY_TAG`
  succeeds → set `image-exists=true`, skip the pull-for-cache, make
  build-image, and push steps entirely (emit image-changed=false). The
  current flow pulls multi-GB images to conclude nothing changed.
- [ ] **Step 2:** Remove the now-redundant "Pull existing images for cache"
  step (make build-image performs its own registry-pull short-circuit; the
  extra pre-pull doubles the download in the local-build path). Verify the
  local-build path still gets --cache-from via the Makefile.

## Task 5: Small per-run downloads → cached or baked

- [ ] **Step 1:** Grype DB: actions/cache keyed `grype-db-<yyyy-ww>` around
  the grype cache dir; `make grype-db-update` refreshes only on miss or when
  the nightly scan (which should stay fresh) is the caller. Record DB dir
  path from the Makefile target first.
- [ ] **Step 2:** check-jsonschema: preinstall in the builder image (or a
  requirements pin + pip cache action). Delete the per-run pip install from
  the attestation job.
- [ ] **Step 3:** CycloneDX schemas: commit the three schema files (with $id
  stripped, as the workflow already does at runtime) under
  configs/attestation/schemas/ and validate offline — removes a curl + the
  hand-rolled fetch_schema logic from YAML into the repo where it's
  reviewable.

## Task 6 (optional, wall-clock not cost): boot-test consolidation

- [ ] **Step 1:** Collapse the NIC-model matrix (6+ short boots, one runner
  each, each paying runner setup + qemu install + ISO restore) into ONE job
  that loops models sequentially — these are sub-2-minute boots; the runner
  overhead exceeds the test time. Keep BIOS/UEFI/toram/persist/gui variants
  as parallel jobs (long, independent, benefit from parallelism).
- [ ] **Step 2:** Cache the qemu apt packages across boot-test jobs
  (awalsh128/cache-apt-pkgs or equivalent) — saves ~1-2 min × remaining jobs.

## Measurements (fill in during Task 1)

- packages/<epoch> total size: ____ GB, ____ objects
- reclaimable by prune: ____ GB
- current restore time: ____ min; save time: ____ min
- post-migration pull time: ____ min (record after Task 2 lands)

## Success Criteria

- Binpkg restore no longer touches S3; pull time beats the Task 1 baseline;
  first-build-of-epoch still succeeds from empty store (fail-open proven by
  a scratch-epoch dispatch run).
- Zero S3 GETs of packages/ in a full-ci run's AWS calls; S3 writes are
  publish-only, master/tags, as before.
- Large-artifact upload bytes per master build roughly halved (server-side
  latest copies).
- build-image job completes in seconds when Dockerfile is unchanged.
- Full boot-test matrix + attestation gate green, unchanged semantics.
