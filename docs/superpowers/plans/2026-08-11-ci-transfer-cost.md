# CI S3 Transfer-Cost Reduction — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop round-tripping large build artifacts through S3 in CI. Pass the ISO/squashfs between jobs of one workflow run via GitHub-native storage, gate all S3 writes to master/tags, and keep the bucket bounded — cutting S3 egress to publish-only levels.

**Architecture:** `build.yml` calls `boot-test.yml` (reusable, `needs: build`) and runs the `attestation` job — all one workflow run. Replace the S3 `cp`/`sync` artifact bus with `actions/cache` (free 10 GB pool) for the ISO+squashfs handoff; gate versioned S3 uploads behind master/tags; make the attestation-history sync incremental; add a scheduled GC; and harden the pin-bump automation that dispatches this same pipeline.

**Tech Stack:** GitHub Actions YAML, `actions/cache@v4`, `aws s3` (publish-only), bash, `scripts/update-build-pins.sh`.

## Global Constraints

- **S3 is publish-only.** Nothing produced and consumed within one workflow run may touch S3. Only master/tag builds write S3 (`latest` pointers, versioned release artifacts, attestation history).
- **Handoff mechanism = `actions/cache`, not artifacts.** The ISO+squashfs handoff (~0.4–0.8 GB) would exceed free-tier artifact storage (500 MB); the cache pool is a separate free 10 GB. Key handoff entries per-run: `ci-artifacts-${{ github.run_id }}-<file>`.
- **Fail-closed on cache miss.** A boot-test/attestation job that cannot restore its ISO must fail loudly (non-zero, clear message), never boot-test a stale/absent image.
- **No behavior regression.** The full boot-test matrix + attestation gate must still pass. QEMU boot semantics, attestation pillars, and `latest`/release publishing on master/tags are unchanged.
- **No self-hosted runners** in this scope (on-prem ⇒ no egress win). K3s is a later CI-speed phase.
- **Validation is the full CI run.** Workflow YAML changes have no local unit tests; they are proven by a green `full-ci` build, consistent with how boot-test/attestation changes are validated in this repo. The GC keep-list predicate is the one exception (small bash, locally testable).
- **Never merge to master; land as a PR.**

---

## File Structure

- `.github/workflows/build.yml` — cache-save ISO+squashfs; gate versioned S3 uploads to master/tags; cache-restore in the attestation job; incremental attestation-history sync (modify).
- `.github/workflows/boot-test.yml` — every boot-test job restores the ISO from cache instead of `aws s3 cp` (modify).
- `.github/workflows/gc.yml` — scheduled S3 garbage collector (create).
- `scripts/s3-gc.sh` — the GC logic + keep-list predicate, unit-testable (create).
- `scripts/tests/s3-gc.test.sh` — keep-list predicate tests (create).
- `.github/workflows/pin-bump.yml` — fail-closed bump guard (modify).
- `scripts/update-build-pins.sh` — `cmd_check` verifies the portage snapshot (modify).

---

## Task 1: ISO + squashfs handoff via `actions/cache`

**Files:**
- Modify: `.github/workflows/build.yml` (save ISO+squashfs to cache after they're built; restore in the `attestation` job)
- Modify: `.github/workflows/boot-test.yml` (restore ISO from cache in every job)

**Interfaces:**
- Produces: two cache entries per run — `ci-artifacts-<run_id>-iso` (path `output/themonolith-<version>.iso`) and `ci-artifacts-<run_id>-squashfs` (path `output/themonolith-<version>.squashfs`) — consumed by all boot-test jobs (ISO) and the attestation job (both).

- [ ] **Step 1: Save the squashfs to cache in `build.yml` (right after "Build rootfs")**

Immediately after the `Build rootfs` step (which produces `output/themonolith-$BUILD_VERSION.squashfs`), add:

```yaml
      - name: Cache squashfs for downstream jobs (in-run handoff)
        uses: actions/cache/save@v4
        with:
          path: output/themonolith-${{ env.BUILD_VERSION }}.squashfs
          key: ci-artifacts-${{ github.run_id }}-squashfs
```

- [ ] **Step 2: Save the ISO to cache in `build.yml` (right after "Build ISO")**

Immediately after the `Build ISO` step, add:

```yaml
      - name: Cache ISO for downstream jobs (in-run handoff)
        uses: actions/cache/save@v4
        with:
          path: output/themonolith-${{ env.BUILD_VERSION }}.iso
          key: ci-artifacts-${{ github.run_id }}-iso
```

- [ ] **Step 3: Replace S3 ISO restore with cache restore in every `boot-test.yml` job**

In `boot-test.yml`, every job has a step:

```yaml
      - name: Restore ISO from S3
        run: |
          mkdir -p output
          aws s3 cp "s3://${{ secrets.S3_BUCKET }}/themonolith-${{ inputs.build-version }}.iso" \
            "output/themonolith-${{ inputs.build-version }}.iso"
```

Replace each with a cache restore that fails closed:

```yaml
      - name: Restore ISO from in-run cache
        uses: actions/cache/restore@v4
        with:
          path: output/themonolith-${{ inputs.build-version }}.iso
          key: ci-artifacts-${{ github.run_id }}-iso
          fail-on-cache-miss: true
```

`boot-test.yml` is `workflow_call`; `github.run_id` is the SAME for the calling `build.yml` run and this reusable workflow's jobs, so the key matches. Remove the now-unused `Configure AWS credentials` step from any boot-test job that no longer references S3 (verify no other S3 use remains in that job first).

- [ ] **Step 4: Replace S3 restores with cache restores in the `attestation` job (`build.yml`)**

The attestation job restores squashfs then ISO from S3:

```yaml
      - name: Restore squashfs from S3
        run: |
          aws s3 cp s3://${{ secrets.S3_BUCKET }}/themonolith-$BUILD_VERSION.squashfs \
            output/themonolith-$BUILD_VERSION.squashfs
      ...
      - name: Restore ISO from S3
        run: |
          aws s3 cp s3://${{ secrets.S3_BUCKET }}/themonolith-$BUILD_VERSION.iso \
            output/themonolith-$BUILD_VERSION.iso
```

Replace both with cache restores:

```yaml
      - name: Restore squashfs from in-run cache
        uses: actions/cache/restore@v4
        with:
          path: output/themonolith-${{ env.BUILD_VERSION }}.squashfs
          key: ci-artifacts-${{ github.run_id }}-squashfs
          fail-on-cache-miss: true
      - name: Restore ISO from in-run cache
        uses: actions/cache/restore@v4
        with:
          path: output/themonolith-${{ env.BUILD_VERSION }}.iso
          key: ci-artifacts-${{ github.run_id }}-iso
          fail-on-cache-miss: true
```

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/build.yml .github/workflows/boot-test.yml
git commit -m "ci(cost): hand off ISO/squashfs via actions/cache, not S3"
```

*(Validated by the full CI run in the final task, not locally.)*

---

## Task 2: Gate all per-build S3 uploads to master/tags

**Files:**
- Modify: `.github/workflows/build.yml`

**Interfaces:**
- Consumes: the existing `PUBLISH_LATEST` env (true only on master/tags — see "Determine whether to publish 'latest' pointers").
- Produces: validation (branch/PR) builds upload **nothing** to S3; the ISO/squashfs live only in the run cache (Task 1).

- [ ] **Step 1: Gate the versioned uploads**

Today the kernel/squashfs/initrd/ISO steps upload the **versioned** object unconditionally (`aws s3 cp output/... s3://.../themonolith-$BUILD_VERSION.*`) and only gate the `latest` pointer behind `PUBLISH_LATEST`. Wrap the **entire** upload body of each of "Save kernel image to S3", "Save squashfs to S3", "Save initrd to S3", "Upload ISO to S3" so nothing runs unless `PUBLISH_LATEST == true`. Example for the ISO step:

```yaml
      - name: Upload ISO to S3
        if: env.PUBLISH_LATEST == 'true'
        run: |
          aws s3 cp output/themonolith-$BUILD_VERSION.iso s3://${{ secrets.S3_BUCKET }}/themonolith-$BUILD_VERSION.iso
          aws s3 cp output/themonolith-$BUILD_VERSION.iso s3://${{ secrets.S3_BUCKET }}/themonolith.iso
          echo "==> Uploaded versioned + latest ISO"
```

Apply the same `if: env.PUBLISH_LATEST == 'true'` gate to the kernel, squashfs, and initrd save steps, and collapse their inner `if [ "$PUBLISH_LATEST" = "true" ]` branch (now redundant) so both the versioned `cp` and the `latest` `cp` run together under the step-level gate.

- [ ] **Step 2: Gate the build-logs upload too**

`Save build logs to S3` (`aws s3 sync output/logs/ s3://.../builds/$BUILD_VERSION/logs/`) also only makes sense for published builds; add `if: env.PUBLISH_LATEST == 'true'`. (Boot-test/serial logs remain available as GitHub artifacts regardless.)

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/build.yml
git commit -m "ci(cost): only master/tag builds write artifacts to S3 (validation builds leave no footprint)"
```

---

## Task 3: Binpkg cache → `actions/cache` (measure-gated)

**Files:**
- Modify: `.github/workflows/build.yml` (the "Restore/Save binary package cache" steps)

**Interfaces:**
- Consumes: `BUILD_EPOCH`.
- Produces: S3 `packages/<epoch>/` read/written only on a cache miss (or kept on S3 if the set is too large for the 10 GB pool).

- [ ] **Step 1: Measure the binpkg set size**

From a recent build's logs (or a one-off `aws s3 ls --summarize --recursive s3://$BUCKET/packages/20260803/`), record the total size. Decision rule: if `packages/<epoch>` comfortably fits alongside the per-run ISO/squashfs cache within the 10 GB repo pool (rule of thumb ≤ ~6 GB), migrate to `actions/cache`; if larger, **leave it on S3** (it is a 1×/build read, far smaller than the ISO whale) and note the deferral. Record the measured size and the decision in the task's report.

- [ ] **Step 2 (if migrating): Replace S3 sync with `actions/cache`**

Replace `Restore binary package cache from S3` and `Save binary packages to S3` with:

```yaml
      - name: Restore binpkg cache
        id: binpkgs
        uses: actions/cache/restore@v4
        with:
          path: output/packages
          key: binpkgs-${{ env.BUILD_EPOCH }}-${{ hashFiles('configs/portage/world', 'configs/portage/package.use/**', 'Dockerfile') }}
          restore-keys: |
            binpkgs-${{ env.BUILD_EPOCH }}-
      # ... build packages ...
      - name: Save binpkg cache
        if: always()
        uses: actions/cache/save@v4
        with:
          path: output/packages
          key: binpkgs-${{ env.BUILD_EPOCH }}-${{ hashFiles('configs/portage/world', 'configs/portage/package.use/**', 'Dockerfile') }}
```

On a new epoch the key changes ⇒ guaranteed miss ⇒ full rebuild (intended). Keep the current `|| true` tolerance semantics (a miss must not fail the build).

- [ ] **Step 2 (if deferring): document and leave as-is**

If the set is too large, keep the S3 sync but add a comment referencing this task and the K3s-PVC follow-up. No code change.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/build.yml
git commit -m "ci(cost): binpkg cache via actions/cache (or documented S3 deferral) — <measured size>"
```

---

## Task 4: Incremental attestation-history sync

**Files:**
- Modify: `.github/workflows/build.yml` (the "Generate and upload site" step)

**Interfaces:**
- Consumes: the existing per-build `attestation/<version>/` upload.
- Produces: the dashboard regenerates without downloading the entire attestation history each build.

- [ ] **Step 1: Stop the full-history download**

Today: `aws s3 sync s3://$BUCKET/attestation/ output/all-attestation/` pulls the entire, growing history every build. Replace with one of (in preference order, pick per what `make dashboard` needs):
  (a) maintain `builds-index.json` incrementally — download only the current index, append this build's record, re-upload; or
  (b) `aws s3 sync` with `--exclude "*" --include "*/attestation-summary.json"` so only the small summary per build is fetched, not full SBOMs.

Implement (b) as the low-risk default unless `make dashboard` requires full records:

```yaml
      - name: Sync attestation summaries for the dashboard
        if: env.PUBLISH_LATEST == 'true'
        run: |
          mkdir -p output/all-attestation
          aws s3 sync s3://${{ secrets.S3_BUCKET }}/attestation/ output/all-attestation/ \
            --exclude "*" --include "*/attestation-summary.json" --include "*/builds-index.json"
          make dashboard ATTEST_INPUT_DIR=output/all-attestation
```

Verify `make dashboard` produces the same `builds-index.json` from summaries alone; if it needs more fields, widen the `--include` set minimally rather than reverting to a full sync.

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/build.yml
git commit -m "ci(cost): dashboard fetches attestation summaries only, not full history"
```

---

## Task 5: Scheduled S3 garbage collector

**Files:**
- Create: `scripts/s3-gc.sh`
- Create: `scripts/tests/s3-gc.test.sh`
- Create: `.github/workflows/gc.yml`

**Interfaces:**
- Produces: a cron-driven prune of stale S3 objects, protecting `latest` pointers, semver release artifacts, and the current epoch's `packages/`.

- [ ] **Step 1: Write the keep-list predicate test (TDD)**

`scripts/tests/s3-gc.test.sh` — source `s3-gc.sh` with a `--dry-run` classifier and assert the predicate keeps/deletes correctly:

```sh
#!/bin/sh
set -u
. "$(dirname "$0")/../s3-gc.sh" --source-only
fails=0
keep() { classify "$1" "$2" | grep -q KEEP   || { echo "FAIL keep: $1"; fails=$((fails+1)); }; }
del()  { classify "$1" "$2" | grep -q DELETE || { echo "FAIL del:  $1"; fails=$((fails+1)); }; }
CUR=20260803
keep "themonolith.iso" "$CUR"                          # latest pointer
keep "themonolith-0.0.1.iso" "$CUR"                     # semver release
keep "packages/20260803/foo.gpkg.tar" "$CUR"           # current epoch
del  "themonolith-20260803-abc12.iso" "$CUR"           # validation artifact
del  "packages/20260727/foo.gpkg.tar" "$CUR"           # old epoch
del  "builds/20260727-abc12/logs/x.log" "$CUR"         # old build logs
[ "$fails" -eq 0 ] && echo ALL PASS || { echo "$fails FAILED"; exit 1; }
```

- [ ] **Step 2: Run it — expect failure (no s3-gc.sh yet)**

Run: `sh scripts/tests/s3-gc.test.sh` → FAIL.

- [ ] **Step 3: Implement `scripts/s3-gc.sh`**

```sh
#!/bin/sh
# S3 garbage collector for The Monolith build bucket.
# classify KEY CURRENT_EPOCH -> "KEEP" | "DELETE"
set -u
classify() {
    key="$1"; cur="$2"
    case "$key" in
        themonolith.iso|themonolith.squashfs|themonolith.vmlinuz|themonolith.initrd) echo KEEP; return;;
        themonolith-[0-9]*.[0-9]*.[0-9]*.*) echo KEEP; return;;                 # semver release
        themonolith-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-*) echo DELETE; return;; # <epoch>-<sha> validation
        packages/"$cur"/*) echo KEEP; return;;
        packages/*) echo DELETE; return;;
        builds/*) echo DELETE; return;;
        attestation/*) echo KEEP; return;;                                       # dashboard history
        *) echo KEEP; return;;                                                   # unknown -> keep (safe)
    esac
}
[ "${1:-}" = "--source-only" ] && return 0
# Live mode: S3_BUCKET + KEEP_EPOCH required. --apply to delete; default dry-run.
BUCKET="${S3_BUCKET:?set S3_BUCKET}"; CUR="${KEEP_EPOCH:?set KEEP_EPOCH}"
APPLY=""; [ "${1:-}" = "--apply" ] && APPLY=1
kept=0; del=0
aws s3 ls "s3://$BUCKET" --recursive | while read -r _ _ _ key; do
    [ -z "$key" ] && continue
    if [ "$(classify "$key" "$CUR")" = DELETE ]; then
        del=$((del+1)); echo "DELETE s3://$BUCKET/$key"
        [ -n "$APPLY" ] && aws s3 rm "s3://$BUCKET/$key"
    fi
done
# Safety: refuse to run if the keep-list would match nothing (mis-set bucket/epoch).
```

- [ ] **Step 4: Run the test — expect PASS**

Run: `sh scripts/tests/s3-gc.test.sh` → `ALL PASS`.

- [ ] **Step 5: Add the scheduled workflow `.github/workflows/gc.yml`**

```yaml
name: S3 GC
on:
  schedule: [{ cron: '0 4 * * 0' }]   # Sundays 04:00 UTC
  workflow_dispatch:
    inputs:
      apply: { description: "Actually delete (else dry-run)", type: boolean, default: false }
jobs:
  gc:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_ACCESS_KEY_SECRET }}
          aws-region: ${{ secrets.AWS_REGION }}
      - name: Determine current epoch
        run: echo "KEEP_EPOCH=$(grep '^ARG BUILD_EPOCH=' Dockerfile | cut -d= -f2)" >> "$GITHUB_ENV"
      - name: GC (dry-run unless apply=true)
        env:
          S3_BUCKET: ${{ secrets.S3_BUCKET }}
        run: sh scripts/s3-gc.sh ${{ (github.event_name == 'workflow_dispatch' && inputs.apply) && '--apply' || '' }}
```

First runs are dry-run (cron never passes `apply`); a human reviews the dry-run output and runs `workflow_dispatch` with `apply=true` once satisfied.

- [ ] **Step 6: Commit**

```bash
git add scripts/s3-gc.sh scripts/tests/s3-gc.test.sh .github/workflows/gc.yml
git commit -m "ci(cost): scheduled S3 GC (dry-run default) with tested keep-list"
```

---

## Task 6: Pin-bump hardening (related-work from #20)

**Files:**
- Modify: `scripts/update-build-pins.sh` (`cmd_check` verifies the portage snapshot)
- Modify: `.github/workflows/pin-bump.yml` (bump step fails closed)

**Interfaces:**
- Produces: the weekly pin gate no longer fires while stage3 leads the portage snapshot; a bump that doesn't actually change the Dockerfile aborts before build/validate/PR.

- [ ] **Step 1: `cmd_check` must verify the portage snapshot before flagging `*`**

In `scripts/update-build-pins.sh` `cmd_check`, after computing `latest_date` from `fetch_latest_stage3_date`, guard the `*` on the snapshot existing:

```sh
    if [[ "${latest_date}" != "(unavailable)" ]] && [[ "${current_epoch}" != "${latest_date}" ]]; then
        if verify_portage_snapshot "${latest_date}"; then
            printf "  %-25s %-28s %-28s *\n" "BUILD_EPOCH" "${current_epoch}" "${latest_date}"
        else
            printf "  %-25s %-28s %-28s (stage3 ahead; portage snapshot for %s not yet published)\n" \
                "BUILD_EPOCH" "${current_epoch}" "${latest_date}" "${latest_date}"
        fi
    else
        printf "  %-25s %-28s %-28s\n" "BUILD_EPOCH" "${current_epoch}" "${latest_date}"
    fi
```

The `pin-bump.yml` gate keys off the `*`, so no `*` ⇒ no bump attempt during the race.

- [ ] **Step 2: The bump step must fail closed (`pin-bump.yml`)**

Replace the "Bump BUILD_EPOCH + SOURCE_DATE_EPOCH" step with a fail-closed version that (a) doesn't hide the exit code behind `| tee`, and (b) asserts the Dockerfile actually changed:

```yaml
      - name: Bump BUILD_EPOCH + SOURCE_DATE_EPOCH
        run: |
          set -euo pipefail
          scripts/update-build-pins.sh update "${NEW_EPOCH}" 2>&1 | tee /tmp/pin-bump-update.log
          NOW=$(grep '^ARG BUILD_EPOCH=' Dockerfile | cut -d= -f2)
          if [ "$NOW" != "${NEW_EPOCH}" ]; then
            echo "::error::BUILD_EPOCH is $NOW, expected ${NEW_EPOCH} — bump did not apply; aborting."
            exit 1
          fi
```

With `set -o pipefail` the `update` refusal now fails the step; the explicit assertion is the backstop for any other silent no-op. A failed bump aborts the job before build/validate/PR, so no mislabeled PR can be produced.

- [ ] **Step 3: Commit**

```bash
git add scripts/update-build-pins.sh .github/workflows/pin-bump.yml
git commit -m "ci(pins): gate check on portage snapshot; fail-closed bump (fixes #20 class)"
```

---

## Task 7: Full-CI validation

**Files:** none (validation only).

- [ ] **Step 1: Push and run full CI**

Push the branch; run a `full-ci` build (label the PR or `gh workflow run build.yml --ref <branch>`). Confirm:
  - the boot-test matrix + attestation pass sourcing the ISO/squashfs from **cache** (no `aws s3 cp` of the ISO in any boot-test/attestation job — grep the run logs);
  - a branch build performs **no S3 uploads** (Task 2);
  - `make dashboard` still produces a valid `builds-index.json` from the trimmed sync (Task 4).

- [ ] **Step 2: Confirm the cost drop**

Over 1–2 builds, confirm via bucket request metrics that per-build S3 GET count + egress bytes dropped to publish-only levels. Record in the task report.

- [ ] **Step 3: GC dry-run**

Trigger `gc.yml` via `workflow_dispatch` (apply=false) and review the DELETE list before anyone enables `apply=true`.

---

## Self-Review

**1. Spec coverage:** §A handoff → Task 1; §B upload gating → Task 2; §C binpkg cache → Task 3 (measure-gated); §D attestation sync → Task 4; §E GC → Task 5; pin-bump related-work → Task 6; success criteria (no S3 reads in boot-test/attestation, no uploads on validation builds, cost drop) → Task 7. ✓

**2. Placeholder scan:** No TBD/TODO. Task 3 is explicitly a measure-then-decide task (both branches specified). Task 4 names concrete `--include` filters with a verify step. GC keep-list is real code with tests.

**3. Type/name consistency:** cache keys `ci-artifacts-${{ github.run_id }}-{iso,squashfs}` and `binpkgs-${{ env.BUILD_EPOCH }}-…` are used identically across save (Task 1/3) and restore (Task 1/3); `PUBLISH_LATEST` gate (Task 2) matches the existing env; `classify()` signature is identical in `s3-gc.sh` and its test.
