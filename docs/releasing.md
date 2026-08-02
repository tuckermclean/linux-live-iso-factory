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

## How `release.yml` reuses `build.yml`

`.github/workflows/build.yml` is the single source of truth for "how to
build and attest The Monolith" — it now exposes a `workflow_call` trigger
(alongside its existing `push`/`workflow_dispatch`/`schedule` triggers), and
`release.yml` invokes the **entire file** as one reusable unit:

```yaml
jobs:
  build:
    uses: ./.github/workflows/build.yml
    secrets: inherit
```

This was chosen over dispatch-and-poll (the approach
`.github/workflows/pin-bump.yml` uses and documents its own reasoning for in
`docs/version-pinning.md`, from back when `build.yml` was being edited by
several branches in parallel at once) because that hazard is gone now — this
is the only branch touching `build.yml` — and `workflow_call` gives a single
literal build definition with typed outputs instead of a polling loop:

- **Zero duplicated build logic.** `release.yml` does not reimplement
  `make build-packages` / `make build-rootfs` / `make iso` / `make
  attestation` anywhere. It calls the workflow that already does, and reads
  back results.
- **Every existing gate applies for free.** The `changes`, `build-image`,
  `build`, `boot-test`, and `attestation` jobs inside `build.yml` all run
  exactly as they do for a push-to-master build — including the CVE
  gate (Pillar 3 of `scripts/attestation.sh`, `configs/attestation/cve-policy.yaml`)
  and the boot-test gate (`.github/workflows/boot-test.yml`, called from
  *inside* `build.yml`, per the `needs:`-can't-cross-files note at the top
  of that file). If any of them fail, the whole `workflow_call` reports
  failure, `release.yml`'s `publish` job never runs, and nothing gets
  published.
- **No duplicate tag-triggered builds.** `build.yml` used to also trigger
  directly on `push: tags: ['*']`; that trigger was removed (see the NOTE
  at the top of `build.yml`) so a release tag doesn't kick off two
  independent builds racing to write the same S3 keys. `release.yml`
  (`push: tags: v*.*.*`) is now the only tag entry point.

`release.yml`'s own `publish` job (after `build.yml` succeeds) only does
what's specific to a *release*: download the artifacts `build.yml` already
produced, cross-check the ISO's hash, assemble release notes, and call `gh
release create`.

## The digest-chain invariant, traced

**Invariant:** `sha256(ISO)` == the enriched SBOM's
`metadata.component.hashes[0].content` == the SLSA attestation's subject
digest. Concretely, for a release:

1. Inside the reused `build.yml` run, the `build` job produces
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

`release.yml` needs nothing beyond what `build.yml` already requires, plus
`contents: write` to create the GitHub Release:

| Secret | Used for |
|---|---|
| `AWS_ACCESS_KEY_ID`, `AWS_ACCESS_KEY_SECRET`, `AWS_REGION` | Same AWS credentials `build.yml`/`Makefile` already use for all S3 I/O |
| `S3_BUCKET` | Bucket name (no credentials) — same variable `build.yml` forwards into the builder container for the SBOM's S3 `distribution` reference and used here to locate/download the built artifacts and to build the dashboard link in the release notes |
| `GITHUB_TOKEN` (automatic) | `gh release create`, and (inside the reused `build.yml`) GHCR login + `actions/attest@v2` |

| Permission | Scope | Why |
|---|---|---|
| `contents: write` | `release.yml` top level + `publish` job | Create the GitHub Release and upload assets |
| `packages: write` | `release.yml` top level (passed through to `build.yml`'s `build-image` job) | Push the builder image to GHCR if it changed |
| `id-token: write`, `attestations: write` | `release.yml` top level (passed through to `build.yml`'s `attestation` job) | Sign SLSA provenance via Sigstore/GitHub OIDC (`actions/attest@v2`) |

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
3. **Push the tag** (this is the only thing that triggers `release.yml` —
   pushing commits to `master` alone does not):
   ```sh
   git push origin v0.1.0
   ```
4. **Watch the run:**
   ```sh
   gh run watch --repo tuckermclean/linux-live-iso-factory \
     $(gh run list --repo tuckermclean/linux-live-iso-factory \
         --workflow=release.yml --branch v0.1.0 --limit 1 --json databaseId --jq '.[0].databaseId')
   ```
   or via the Actions tab. Expect the same wall-clock time as a normal full
   build (the `build.yml` call does all the same work), plus a few minutes
   for boot-test and the publish step.
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
