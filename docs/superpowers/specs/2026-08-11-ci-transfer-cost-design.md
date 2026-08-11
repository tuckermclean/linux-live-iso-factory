# CI S3 Transfer-Cost Reduction — Design

**Status:** approved (design); pending spec review → implementation plan.
**Date:** 2026-08-11
**Branch:** `feat/ci-transfer-cost` (off `master`).

## Problem

The dominant AWS cost for this project is **S3 data egress**, not storage. Every full CI
build downloads the same large build artifacts out of S3 many times, and S3 bills internet
egress ($0.09/GB) for each read because GitHub-hosted runners live outside AWS.

The root cause is architectural: **S3 is used as the inter-job artifact bus.** `build.yml`
calls `boot-test.yml` as a reusable workflow (`uses: ./.github/workflows/boot-test.yml`,
`needs: build`), so the build job and every boot-test job run in **one workflow run** — yet
the build job *uploads* the ISO to S3 and each downstream job *re-downloads it from S3*
instead of receiving it in-network.

### Measured transfer per full build (current)

The squashfs is the bulk of the payload; the ISO wraps it, so ISO ≈ squashfs size. Per full
build (master push, tag, or a `full-ci`-labelled PR), S3 is read roughly:

| Consumer | S3 reads | Count |
|---|---|---|
| boot-test matrix jobs (`bios`×2, `uefi`, `toram-eject`, `ahci`, `nvme`, `usb`, `virtio`, `nicless`, `nic-models`×5, `nat-router`) | full ISO each | ~15 |
| `attestation` job (`needs: build`) | squashfs + ISO | 2 |
| `attestation` dashboard step | **entire** `attestation/` history (grows unbounded) | 1 (growing) |
| `build` job start | `packages/<epoch>/` binpkg cache | 1 |

So ~17 downloads of the (squashfs-sized) artifact per build — ~6 GB egress at a ~400 MB
ISO — purely to move a file between jobs already in the same run, plus a binpkg-cache read
and an ever-growing attestation-history read.

## Key insight

GitHub provides two in-network storage mechanisms that do **not** incur S3 egress; the
pipeline simply isn't using them:

- **Artifacts** (`actions/upload-artifact` / `download-artifact`) — pass outputs between jobs
  in a run. Counts against the artifacts/packages storage quota (free tier: 500 MB).
- **Actions cache** (`actions/cache`) — a **separate, free 10 GB/repo** pool (does not count
  against artifact storage), restorable later in the same run and across runs.

The cluster is **on-prem**, so self-hosted K3s runners would **not** reduce S3 egress (S3
bills internet egress to any external destination). K3s is therefore deferred to a later
CI-speed phase; the cost fix is achieved with GitHub-native mechanisms and needs no infra.

## Architecture

**Core principle: S3 becomes publish-only. Nothing produced and consumed within a single
workflow run touches S3.** The CI inner loop moves to GitHub-native storage; S3 retains only
what must outlive the run — `latest` pointers, tagged releases, and attestation history.

### Component changes

**A. Build → boot-test/attestation artifact handoff → GitHub Actions cache.** *(primary win)*
The `build` job saves the ISO (and squashfs, needed by attestation) into `actions/cache`
under a per-run key; every boot-test job and the attestation job restore from cache instead
of `aws s3 cp`. Removes ~17 S3 reads/build. The build's own in-run boot test reads the file
already on its disk — no download at all.

Mechanism = **`actions/cache`, not artifacts**, chosen deliberately: the ISO+squashfs handoff
is ~0.4–0.8 GB, which would exceed free-tier artifact storage (500 MB) and start billing,
whereas the cache pool is a separate free 10 GB. Cache key is scoped to the run
(`ci-artifacts-${{ github.run_id }}-<file>`) so each run's handoff is isolated; unused entries
evict by LRU/age. If a future move off free tier makes artifacts preferable (simpler API,
per-run auto-expiry), that swap is mechanical.

**B. Validation builds stop uploading to S3 entirely.** Branch/PR (`full-ci`) builds currently
upload a full versioned `themonolith-<version>.{iso,squashfs,vmlinuz,initrd}` set to S3 that
nothing downloads except the boot-tests (now on cache). Gate **all** per-build S3 uploads
behind the existing `PUBLISH_LATEST` condition (master/tags only). Effect: validation builds
leave **zero** S3 footprint — no upload egress and no storage growth (this also resolves the
separate unbounded-storage problem previously identified).

**C. `packages/<epoch>/` binpkg cache → `actions/cache` (measure-gated).** Currently
`aws s3 sync` down at build start + up at end, every build (1×/build, but large). Move to
`actions/cache` keyed on epoch + a content hash of the package set, so S3 is touched only on a
cache **miss**. This competes with (A) for the 10 GB pool, so it is **gated on measuring the
binpkg set size**: if it fits comfortably alongside the per-run ISO cache, migrate it; if it is
large (multi-GB), leave it on S3 (it is only a 1×/build read, far smaller than the ISO whale)
and revisit under the K3s phase (persistent PVC cache). This is the lower-priority lever.

**D. Attestation dashboard history sync → incremental.** The dashboard step runs
`aws s3 sync s3://…/attestation/ output/all-attestation/` every build, pulling the **entire,
ever-growing** attestation history down to regenerate `builds-index.json`. This is a compounding
egress leak. Fix direction (details in plan): sync only new/changed records, or maintain the
builds index incrementally, or generate the dashboard from the current build plus a cached index
rather than a full re-download. Secondary to (A)/(B) but worth closing.

**E. Storage GC → scheduled CI job.** A scheduled workflow (`gc.yml` or similar) prunes stale
S3 objects — old `packages/<epoch>/` (keeping the current epoch), any historical
`themonolith-<epoch>-<sha>.*` validation artifacts left from before (B), and old
`builds/<version>/logs/` — protecting `latest` pointers and tagged (`semver`) releases. With
(B) in place, validation builds no longer create new litter, so this mostly clears history and
old epochs. Runs on a cron; dry-run-then-delete with the keep-list encoded.

### Out of scope / deferred

- **K3s self-hosted runners.** On-prem ⇒ no S3-egress reduction. Deferred to a future
  **CI-speed** phase (persistent warm binpkg cache on a PVC, no per-job QEMU install, heavier
  parallelism) — that is where the "fastest CI wall-clock" goal is realized. Not required for,
  and does not block, the cost fix.
- **`release.yml` tag consumption** (downloads the released ISO + attestation to attach to the
  GitHub Release) is legitimate publish-consumption, ~once per release — negligible volume.
  May later read from the build run's cache/artifact, but not in this scope.
- **Merging build and boot-test into one job** (which would remove the handoff entirely) is
  rejected: it would serialize the boot-test matrix and lose parallelism. Keep the job
  structure; use the cache handoff.

## Data flow (after)

```
full build run:
  build job:
    restore binpkg cache (actions/cache, miss → S3)   # C (or S3 if large)
    build packages → kernel → rootfs(squashfs) → ISO
    actions/cache SAVE  iso, squashfs   (key: run_id)  # A
    if master/tag: aws s3 cp iso/squashfs/kernel/initrd + latest pointers  # B
  boot-test jobs (parallel, same run):
    actions/cache RESTORE iso            → QEMU boot   # A  (no S3)
  attestation job (same run):
    actions/cache RESTORE iso + squashfs → SBOM/sign   # A  (no S3)
    if master/tag: aws s3 sync attestation/<version>/ ; incremental dashboard  # B/D
scheduled gc.yml:
    prune old packages/<epoch>, stale validation artifacts, old logs   # E
```

## Error handling

- **Cache miss on a handoff restore** (eviction, expiry, or a re-run after 7 days): the boot-test
  job cannot proceed. Restores must **fail loudly** (non-zero, clear message) rather than silently
  boot-testing a stale/absent ISO. A re-run of an old workflow whose cache has evicted must
  re-run `build` (which re-populates the cache), not just the boot-test job — document this.
- **Binpkg cache miss (C):** falls back to S3 sync (if retained) or a clean rebuild — same as
  today's `|| true` tolerance; must not fail the build.
- **GC (E):** dry-run mode and an explicit keep-list; never deletes the current epoch, `latest`
  pointers, or `semver` release artifacts. A safety check aborts if the keep-list would match
  zero objects (guards against a mis-set bucket/prefix wiping everything).

## Testing

- **Primary validation is CI itself:** a `full-ci` PR build must go green end-to-end with **zero
  `aws s3 cp/sync` reads** in the build/boot-test/attestation path (grep the run logs / assert no
  S3 GET in the boot-test jobs). The boot-test matrix must pass sourcing the ISO from cache.
- **Cost check:** confirm (via AWS cost explorer / bucket request metrics over a few builds) that
  S3 GET request count and egress bytes per build drop to ~publish-only levels.
- **GC job:** dry-run output reviewed before enabling deletes; a unit-style test of the keep-list
  predicate (semver + current-epoch + latest pointers retained; validation artifacts matched).
- **No local unit tests** for the workflow YAML changes themselves; they are validated by the
  full CI run, consistent with how boot-test/attestation changes are validated in this repo.

## Success criteria

1. A full CI build performs **no S3 downloads** of the ISO/squashfs in boot-test or attestation
   jobs (handoff is cache-only).
2. Branch/PR (`full-ci`) builds perform **no S3 uploads** at all.
3. S3 egress + GET-request volume per build drops to publish-only levels (master/tags write
   `latest`/release/attestation; end users/releases read).
4. No regression: the full boot-test matrix + attestation gate still pass.
5. A scheduled GC job keeps the bucket bounded (current epoch + latest + tags retained).
