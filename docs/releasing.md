# Cutting a release

This document covers the versioning scheme, what a tagged release actually
is (versus the nightly/on-push builds this repo produces continuously), and
the exact operator steps to cut one. The machinery itself lives in
`.github/workflows/release.yml`; this doc explains it, it doesn't define it.

## Versioning scheme

Tags follow `vMAJOR.MINOR.PATCH` ([SemVer](https://semver.org/)). The
current tag is `v0.0.1` — a pre-release placeholder from before any of the
attestation/CI machinery existed. **`v0.1.0` is the first real public
release**: the first tag cut through `release.yml`, with a full build +
boot-test + SBOM/CVE gate + signed SLSA provenance behind it.

- **Patch (`0.1.0` → `0.1.1`)** — no change to what ships, only how it was
  built or verified: a pinned dependency bump that doesn't change kernel
  config or the world package list, a CI/attestation fix, a doc fix, a
  reproducibility fix. Nothing a user booting the ISO would notice.
- **Minor (`0.1.0` → `0.2.0`)** — the ISO itself changed in a
  backward-compatible way: packages added to `configs/portage/world`, a
  kernel config change that adds capability without removing any, new boot
  modes, a new architecture variant. Existing use cases keep working.
- **Major (`0.x.y` → `1.0.0`)** — a breaking change to what "The Monolith"
  is or how it's used: dropping i486 support, changing the init system,
  removing a package class users may depend on, restructuring the ISO
  layout (partition scheme, boot loader) in a way that breaks existing
  boot media/scripts built against it. `1.0.0` itself should mark the point
  where the project considers its interface (boot behavior, package set
  shape, attestation artifact schema) stable enough to commit to not
  breaking casually.

Because `BUILD_EPOCH` (see `docs/version-pinning.md`) can advance
independently of any of the above — a routine weekly pin bump doesn't
usually warrant even a patch tag — **not every build gets a version tag,
and that's by design.**

### Nightly / on-push builds vs. tagged releases

Every push to `master`, the weekly schedule, and manual dispatch runs
`.github/workflows/build.yml` directly and produces a build identified as
`<BUILD_EPOCH>-<short-sha>` (e.g. `20260420-c91c98d`) — visible on the
[dashboard](https://themonolith.s3.amazonaws.com/) and published to S3 as
`themonolith-<that-string>.iso` (with `themonolith.iso` always pointing at
the most recent one, tagged or not). These are real, fully attested builds
— same CVE gate, same SLSA signing — they just aren't versioned or
published as a GitHub Release.

A tagged release (`vMAJOR.MINOR.PATCH`) is that same pipeline, pointed at a
specific commit and given a permanent, versioned identity: the ISO is named
`themonolith-<version>.iso` (e.g. `themonolith-0.1.0.iso`, no epoch/sha),
attached to a GitHub Release with `SHA256SUMS` and the enriched SBOM, and
gets its own permanent S3 prefix
(`s3://themonolith/attestation/<version>/`) alongside the epoch-keyed
nightly builds. **Every tagged release is traceable back to the exact
nightly/on-push build it was cut from** — the release's `BUILD_EPOCH` and
git SHA are recorded in that release's SBOM (`metadata.component` +
`formulation`) and SLSA provenance exactly as for any other build; tagging
doesn't rebuild anything with different inputs, it publishes a build that
went through the identical pipeline.

## How `build.yml` builds and `release.yml` publishes

`.github/workflows/build.yml` is the single source of truth for "how to
build and attest The Monolith." It triggers **directly** on a release tag
(`push: tags: ['v*.*.*']`, alongside its `push: branches`, `workflow_dispatch`,
and `schedule` triggers) and runs the whole `changes → build-image → build →
boot-test → attestation` chain itself — the identical pipeline a
push-to-master build runs, including the CVE gate and the boot-test gate.

`release.yml` does **not** build. It fires *after* a Build run finishes, via
`workflow_run`, and its single `publish` job does only what's specific to a
release: download the artifacts `build.yml` already produced and attested,
cross-check the ISO's hash, assemble release notes, and call `gh release
create`.

```yaml
# release.yml
on:
  workflow_run:
    workflows: [Build]
    types: [completed]

jobs:
  publish:
    if: >-
      github.event.workflow_run.conclusion == 'success' &&
      github.event.workflow_run.event == 'push' &&
      startsWith(github.event.workflow_run.head_branch, 'v')
```

**Why `build.yml` owns the tag trigger (and `release.yml` no longer calls
it).** `release.yml` used to invoke `build.yml` as a `workflow_call` reusable
unit, so there was one build definition and one build per tag. But signing
broke on that path: GitHub binds a Sigstore attestation to the workflow that
*entered* the run, and `actions/attest@v2` failed to persist with `Invalid
Argument - values do not match: build.yml != release.yml` — the certificate's
SAN was `build.yml` (the job that ran) but the persist API validated
`release.yml` (the entry point). Attestation only persists when the running
workflow and the entry workflow are the same file. So `build.yml` now triggers
on the tag itself (entry == job == `build.yml`, SAN matches, signing
succeeds), and `release.yml` waits for that build via `workflow_run` and
publishes. This is structurally impossible to catch on a PR or master build —
those enter through `build.yml` directly, so the mismatch only ever appears on
a real tag.

This keeps the two properties the `workflow_call` design was chosen for:

- **Zero duplicated build logic.** `release.yml` still does not reimplement
  `make build-packages` / `make build-rootfs` / `make iso` / `make
  attestation` anywhere. `build.yml` remains the only definition;
  `release.yml` reads back its results.
- **One build per release, every gate applies.** A release tag starts exactly
  one Build run (`build.yml` no longer has a `workflow_call` entry point, so
  there's no second racing build). If any job in it (`build`, `boot-test`,
  `attestation`, and the CVE/license/unowned gates inside `attestation`)
  fails, the Build run's `conclusion` is not `success`, the `workflow_run`
  `if:` gate is false, and `release.yml`'s `publish` job never runs — nothing
  gets published.

`workflow_run` fires for *every* Build completion (master pushes, `full-ci`
PRs, the schedule), so the `publish` job's `if:` narrows it to successful
v-tag pushes; every other Build completion produces a skipped Release run.
Before publishing, `publish` re-verifies `head_branch` against the actual tag
— it must point at the exact commit the Build built — and refuses otherwise.

## The digest-chain invariant, traced

**Invariant:** `sha256(ISO)` == the enriched SBOM's
`metadata.component.hashes[0].content` == the SLSA attestation's subject
digest. Concretely, for a release:

1. Inside the tag's `build.yml` run, the `build` job produces
   `output/themonolith-<version>.iso` (`make iso`) and uploads it to S3.
2. The `attestation` job's `make attestation` step invokes
   `scripts/attestation.sh`, which computes `ISO_SHA256=$(sha256sum
   "$ISO" | cut -d' ' -f1)` **once** — this is the single point where the
   hash is ever computed from bytes on disk.
3. That same `$ISO_SHA256` is passed to `scripts/enrich-sbom.py
   --iso-sha256`, which writes it into `bom.cdx.json`'s
   `metadata.component.hashes[0]` (and, since this run is on a `v*.*.*`
   tag, into two `externalReferences` of type `distribution` — one for the
   S3 copy, one for the future GitHub Release asset, both carrying that
   identical hash; see the "GitHub Release URL" note below).
4. The same `$ISO_SHA256` is passed to `scripts/generate-provenance.py
   --iso-sha256`, which writes `predicate.subject[0].digest.sha256` in
   `slsa-provenance.json`.
5. `actions/attest@v2` (inside the `attestation` job) signs that exact
   predicate with `subject-path:
   output/themonolith-<version>.iso` — Sigstore independently verifies at
   signing time that the file at `subject-path` hashes to the digest in the
   predicate, so the signed attestation and the predicate can never
   disagree.
6. `attestation-summary.json` (also written by `attestation.sh`) records
   the same `iso_sha256` value, and is what `release.yml`'s `publish` job
   reads back.
7. `release.yml` downloads the ISO and `bom.cdx.json` from S3, **re-hashes
   the downloaded ISO independently** (`sha256sum`) and asserts it matches
   both `attestation-summary.json`'s recorded value and the SBOM's own
   `metadata.component.hashes[0]` — a tamper/corruption check on the S3
   round-trip, not a re-derivation. Any mismatch fails the workflow before
   `gh release create` runs.
8. `SHA256SUMS`, the release notes, and the `gh release create` call all
   use that one value.

Every number that ends up in the release notes, `SHA256SUMS`, the SBOM, and
the SLSA attestation traces back to the single `sha256sum` call in step 2 —
nothing along the way recomputes it from a different copy of the file.

**GitHub Release URL in the SBOM:** GitHub Release asset download URLs are
deterministic — `<server>/<owner>/<repo>/releases/download/<tag>/<asset>` —
so `scripts/attestation.sh` can compute
`https://github.com/tuckermclean/linux-live-iso-factory/releases/download/v<version>/themonolith-<version>.iso`
from `GITHUB_REF`/`GITHUB_REPOSITORY` alone, *before* `gh release create`
ever runs, and pass it to `enrich-sbom.py --release-url`. This is why the
SBOM can point at the release asset without introducing an ordering
dependency on the release actually existing yet — by the time `gh release
create` runs and makes that URL resolve, the SBOM already named it
correctly.

## Required secrets and permissions

Build + attest happens entirely in the tag's `build.yml` run, which already
carries every permission it needs (`packages: write` at the workflow level for
GHCR; `id-token: write` + `attestations: write` on its own `attestation` job
for Sigstore signing). `release.yml` only creates the GitHub Release, so
`contents: write` is the only permission it needs:

| Secret | Used for |
|---|---|
| `AWS_ACCESS_KEY_ID`, `AWS_ACCESS_KEY_SECRET`, `AWS_REGION` | Same AWS credentials `build.yml`/`Makefile` already use for all S3 I/O — `release.yml`'s `publish` job uses them to download the built artifacts |
| `S3_BUCKET` | Bucket name (no credentials) — same variable `build.yml` forwards into the builder container for the SBOM's S3 `distribution` reference; used here to locate/download the built artifacts and to build the dashboard link in the release notes |
| `GITHUB_TOKEN` (automatic) | `gh release create` (in `release.yml`); GHCR login + `actions/attest@v2` (in `build.yml`) |

| Permission | Scope | Why |
|---|---|---|
| `contents: write` | `release.yml` top level + `publish` job | Create the GitHub Release and upload assets |
| `packages: write` | `build.yml` top level | Push the builder image to GHCR if it changed |
| `id-token: write`, `attestations: write` | `build.yml`'s `attestation` job | Sign SLSA provenance via Sigstore/GitHub OIDC (`actions/attest@v2`) |

No new secrets were introduced by this workflow — it reuses exactly the
four already configured for `build.yml`.

## Operator steps to cut a release

Once the version to release is decided (see the scheme above):

1. **Confirm `master` is in the state you want released** — this pins the
   commit; there is no separate release branch or freeze process today.
2. **Tag it:**
   ```sh
   git tag v0.1.0
   ```
3. **Push the tag** (this starts the **Build** workflow on the tag; once that
   Build succeeds, `release.yml` publishes automatically via `workflow_run`.
   Pushing commits to `master` alone does not cut a release):
   ```sh
   git push origin v0.1.0
   ```
4. **Watch the Build run** (this is where all the work — and any gate failure —
   happens):
   ```sh
   gh run watch --repo tuckermclean/linux-live-iso-factory \
     $(gh run list --repo tuckermclean/linux-live-iso-factory \
         --workflow=build.yml --branch v0.1.0 --limit 1 --json databaseId --jq '.[0].databaseId')
   ```
   Expect the same wall-clock time as a normal full build plus boot-test. When
   it succeeds, the **Release** workflow runs automatically and cuts the GitHub
   Release in a minute or two — find it under the Release workflow (its run is
   attributed to `master`, not the tag, because `workflow_run` runs on the
   default branch):
   ```sh
   gh run list --repo tuckermclean/linux-live-iso-factory --workflow=release.yml --limit 3
   ```
5. **Verify the published release:**
   ```sh
   gh release view v0.1.0 --repo tuckermclean/linux-live-iso-factory
   gh release download v0.1.0 --repo tuckermclean/linux-live-iso-factory \
     --pattern 'themonolith-0.1.0.iso'
   gh attestation verify themonolith-0.1.0.iso --owner tuckermclean
   sha256sum themonolith-0.1.0.iso   # must match SHA256SUMS and the release notes
   ```
6. If the run fails at the boot-test or attestation gate, **do not re-push
   the same tag** (git tags are meant to be immutable, and a force-push
   re-triggers the whole pipeline from a confusing state). Fix forward on
   `master`, delete the local/remote tag if it was already pushed
   (`git tag -d v0.1.0 && git push origin :refs/tags/v0.1.0`), and re-tag
   once the fix is in.

There is no rollback automation — a bad release is superseded by cutting a
new patch version, not by deleting the old one (deleting a published
release with real download counts/links out in the wild is a judgment
call for the operator, not something this pipeline does for you).
