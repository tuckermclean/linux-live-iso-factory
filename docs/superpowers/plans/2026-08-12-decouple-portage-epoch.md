# Decouple the Portage Epoch from the Builder Image — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the runtime portage snapshot a self-hosted, independently-pinned build input so a snapshot refresh no longer rebuilds the crossdev toolchain and builds are immune to Gentoo mirror pruning.

**Architecture:** Split the single `BUILD_EPOCH` into two pins — `TOOLCHAIN_EPOCH` (bakes the stage3 base + crossdev toolchain into the image; rare, human-gated) and `BUILD_EPOCH` (the runtime portage snapshot, fetched from our own S3 first, upstream as fallback, archived on fetch). The pin-bump automation splits into a cheap auto-merged snapshot flow and a human-gated toolchain flow.

**Tech Stack:** POSIX `/bin/sh`, Gentoo `emerge-webrsync`, Docker/crossdev, `aws s3`, GitHub Actions YAML, GNU make.

## Global Constraints

- **Reproducibility preserved:** both epochs pinned; the snapshot is served from our S3 (exact bytes). `SOURCE_DATE_EPOCH` still derives from `BUILD_EPOCH`. SBOM/attestation unchanged.
- **Security preserved:** `emerge-webrsync` still performs GPG verification of the snapshot (signing key `DCD05B71EAB94199527F44ACDB6B8C1F96D8BF6D`). Do NOT bypass it.
- **S3 layout:** snapshots live at `s3://$S3_BUCKET/portage-snapshots/gentoo-<EPOCH>.tar.xz` (+ sidecars). The bucket is publicly readable at its root (serves the ISO/dashboard today).
- **Fail-closed:** a snapshot missing from BOTH our S3 and upstream is a hard error (never silently proceed on a wrong tree).
- **Deferred (NOT in this plan):** self-hosting the stage3 base; a scheduled TOOLCHAIN_EPOCH maintenance cadence.
- **Validation is CI** for the build-system changes (no local crossdev). `sync-portage.sh` logic is unit-tested locally. **Never merge to master; land as a PR.**
- Current values to seed with: `TOOLCHAIN_EPOCH=20260811`, `BUILD_EPOCH=20260811` (both live today). `CROSS_*_VER`/`crossdev.lock` unchanged.

---

## File Structure

- `scripts/sync-portage.sh` — resilient snapshot fetch/verify-feed (create).
- `scripts/tests/sync-portage.test.sh` — unit tests for the fetch/fallback/archive predicate (create).
- `Dockerfile` — `TOOLCHAIN_EPOCH` for the baked tree (modify).
- `Makefile` — `sync-portage` calls the script with creds; `TOOLCHAIN_EPOCH` var; base-tools-hash decoupled from the runtime snapshot (modify).
- `.github/workflows/build.yml` — pass `S3_BUCKET`+AWS creds to `sync-portage` (modify).
- `scripts/update-build-pins.sh` — snapshot-bump vs toolchain-bump paths (modify).
- `.github/workflows/pin-bump.yml` — cheap auto-merged snapshot flow (modify) + `.github/workflows/toolchain-bump.yml` human-gated toolchain flow (create).
- `docs/version-pinning.md` — document the two-pin model (modify).

---

## Task 1: Resilient `sync-portage.sh` (self-hosted snapshot fetch) + tests

**Files:**
- Create: `scripts/sync-portage.sh`
- Create: `scripts/tests/sync-portage.test.sh`

**Interfaces:**
- Produces: `scripts/sync-portage.sh` — env in: `BUILD_EPOCH` (required), `S3_BUCKET` (optional; enables S3), `SYNC_MIRROR_DIR` (default `/var/monolith-portage-mirror`), `SYNC_UPSTREAM` (default `https://distfiles.gentoo.org/snapshots`), `SYNC_S3_PREFIX` (default `portage-snapshots`). Sourceable with `--source-only` (defines `fetch_snapshot` without running), like `scripts/s3-gc.sh`. `fetch_snapshot` populates `$SYNC_MIRROR_DIR/snapshots/` with `gentoo-$BUILD_EPOCH.tar.xz` + `.gpgsig`, trying S3 then upstream (archiving upstream→S3), returning 0 on success / non-zero if a required file is unavailable everywhere.

- [ ] **Step 1: Write the failing test**

Create `scripts/tests/sync-portage.test.sh`:

```sh
#!/bin/sh
# Unit tests for scripts/sync-portage.sh's fetch/fallback/archive logic.
# Stubs `aws` and `wget` on PATH; asserts source order + archive behavior.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
fails=0
mk_stub() {  # $1=name  $2=body
    printf '#!/bin/sh\n%s\n' "$2" > "$BIN/$1"; chmod +x "$BIN/$1"
}
setup() {
    TMP=$(mktemp -d); BIN="$TMP/bin"; mkdir -p "$BIN"
    export PATH="$BIN:$PATH"
    export SYNC_MIRROR_DIR="$TMP/mirror"; mkdir -p "$SYNC_MIRROR_DIR/snapshots"
    export BUILD_EPOCH=20260811
    export SYNC_S3_PREFIX=portage-snapshots
    export CALLLOG="$TMP/calls"; : > "$CALLLOG"
    . "$HERE/../sync-portage.sh" --source-only
}
teardown() { rm -rf "$TMP"; unset S3_BUCKET; }

# 1. S3 has the files -> used; upstream NOT touched; no archive upload.
setup
export S3_BUCKET=bkt
mk_stub aws 'echo "aws $*" >> "$CALLLOG"; case "$*" in *" cp s3://"*) f="${*##* }"; echo data > "$f"; exit 0;; esac; exit 0'
mk_stub wget 'echo "wget $*" >> "$CALLLOG"; exit 99'   # if wget runs, that is a failure
fetch_snapshot >/dev/null 2>&1 && r=0 || r=1
[ "$r" -eq 0 ] && echo "  ok: S3-hit returns 0" || { echo "  FAIL: S3-hit rc=$r"; fails=$((fails+1)); }
grep -q 'wget' "$CALLLOG" && { echo "  FAIL: upstream fetched despite S3 hit"; fails=$((fails+1)); } || echo "  ok: upstream not touched on S3 hit"
teardown

# 2. S3 miss -> upstream fetch -> archived back to S3.
setup
export S3_BUCKET=bkt
mk_stub aws 'echo "aws $*" >> "$CALLLOG"; case "$*" in *" cp s3://"*/*" "*) exit 1;; *" cp "*" s3://"*) exit 0;; esac; exit 1'
mk_stub wget 'echo "wget $*" >> "$CALLLOG"; f=""; for a in "$@"; do case "$a" in /*) f="$a";; esac; done; echo data > "$f"; exit 0'
fetch_snapshot >/dev/null 2>&1 && r=0 || r=1
[ "$r" -eq 0 ] && echo "  ok: upstream fallback returns 0" || { echo "  FAIL: fallback rc=$r"; fails=$((fails+1)); }
grep -q 'aws .* cp .* s3://' "$CALLLOG" && echo "  ok: fetched snapshot archived to S3" || { echo "  FAIL: not archived"; fails=$((fails+1)); }
teardown

# 3. Neither S3 nor upstream has the .tar.xz -> hard error (non-zero).
setup
export S3_BUCKET=bkt
mk_stub aws 'exit 1'
mk_stub wget 'exit 8'   # 404
fetch_snapshot >/dev/null 2>&1 && r=0 || r=1
[ "$r" -ne 0 ] && echo "  ok: unavailable everywhere -> non-zero" || { echo "  FAIL: should have failed"; fails=$((fails+1)); }
teardown

# 4. No S3_BUCKET set -> upstream only, no aws calls.
setup
mk_stub aws 'echo "aws $*" >> "$CALLLOG"; exit 0'
mk_stub wget 'f=""; for a in "$@"; do case "$a" in /*) f="$a";; esac; done; echo data > "$f"; exit 0'
fetch_snapshot >/dev/null 2>&1 && r=0 || r=1
[ "$r" -eq 0 ] && echo "  ok: no-S3 upstream-only returns 0" || { echo "  FAIL: rc=$r"; fails=$((fails+1)); }
grep -q 'aws' "$CALLLOG" && { echo "  FAIL: aws called without S3_BUCKET"; fails=$((fails+1)); } || echo "  ok: aws not called without S3_BUCKET"
teardown

echo; [ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
```

- [ ] **Step 2: Run it — expect failure (no script yet)**

Run: `sh scripts/tests/sync-portage.test.sh`
Expected: FAIL (sourcing `../sync-portage.sh` errors — file absent).

- [ ] **Step 3: Implement `scripts/sync-portage.sh`**

```sh
#!/bin/sh
# Resilient self-hosted portage-snapshot sync. Populates the local mirror dir
# with the pinned BUILD_EPOCH snapshot from OUR S3 first (immune to Gentoo
# mirror pruning), upstream as fallback (archiving upstream -> S3 for next
# time), then hands it to emerge-webrsync which does GPG verify + extraction.
set -u

: "${SYNC_MIRROR_DIR:=/var/monolith-portage-mirror}"
: "${SYNC_UPSTREAM:=https://distfiles.gentoo.org/snapshots}"
: "${SYNC_S3_PREFIX:=portage-snapshots}"

# fetch_snapshot: ensure gentoo-$BUILD_EPOCH.tar.xz + .gpgsig are in the local
# mirror. Returns 0 on success, non-zero if a required file is unavailable
# everywhere. Idempotent.
fetch_snapshot() {
    _epoch="${BUILD_EPOCH:?BUILD_EPOCH must be set}"
    _snapdir="$SYNC_MIRROR_DIR/snapshots"
    mkdir -p "$_snapdir"
    _snap="gentoo-${_epoch}.tar.xz"
    # .gpgsig is required (GPG verify); .md5sum is optional on modern mirrors.
    for _f in "$_snap" "$_snap.gpgsig"; do
        _dst="$_snapdir/$_f"
        [ -s "$_dst" ] && continue
        # 1) our S3 mirror first
        if [ -n "${S3_BUCKET:-}" ] && aws s3 cp "s3://$S3_BUCKET/$SYNC_S3_PREFIX/$_f" "$_dst" >/dev/null 2>&1; then
            echo "  sync-portage: $_f <- s3://$S3_BUCKET/$SYNC_S3_PREFIX/"
            continue
        fi
        # 2) upstream, then archive to S3
        if wget -q -O "$_dst" "$SYNC_UPSTREAM/$_f"; then
            echo "  sync-portage: $_f <- upstream ($SYNC_UPSTREAM)"
            [ -n "${S3_BUCKET:-}" ] && aws s3 cp "$_dst" "s3://$S3_BUCKET/$SYNC_S3_PREFIX/$_f" >/dev/null 2>&1 \
                && echo "  sync-portage: archived $_f -> s3://$S3_BUCKET/$SYNC_S3_PREFIX/"
            continue
        fi
        rm -f "$_dst"
        echo "sync-portage: FATAL — $_f not in our S3 nor upstream; epoch $_epoch is unrecoverable" >&2
        return 1
    done
    return 0
}

# Sourced by the test harness — define functions, do not run.
[ "${1:-}" = "--source-only" ] && return 0 2>/dev/null || { case "${0##*/}" in *sync-portage.sh) : ;; esac; }

# Live mode: fetch, then emerge-webrsync from the local mirror (upstream fallback).
fetch_snapshot || exit 1
echo "==> emerge-webrsync --revert=$BUILD_EPOCH (mirror: self-hosted, fallback: upstream)"
GENTOO_MIRRORS="file://$SYNC_MIRROR_DIR ${SYNC_UPSTREAM%/snapshots}" emerge-webrsync --revert="$BUILD_EPOCH"
```

Note the `--source-only` guard mirrors `scripts/s3-gc.sh`'s dash-safe pattern (dash's `.` does not pass args; the basename fallback keeps live-mode detection working — copy that idiom exactly if this simpler form misbehaves under dash).

- [ ] **Step 4: Run the tests — expect PASS**

Run: `sh scripts/tests/sync-portage.test.sh`
Expected: `ALL PASS`. Also `sh -n scripts/sync-portage.sh` → no output; `chmod +x scripts/sync-portage.sh`.

- [ ] **Step 5: Commit**

```bash
git add scripts/sync-portage.sh scripts/tests/sync-portage.test.sh
git commit -m "build: resilient self-hosted portage-snapshot fetch (sync-portage.sh)"
```

---

## Task 2: Wire `sync-portage.sh` into the Makefile + build.yml (creds + mount)

**Files:**
- Modify: `Makefile` (the `sync-portage` target)
- Modify: `.github/workflows/build.yml` (the "Sync portage" step)

**Interfaces:**
- Consumes: `scripts/sync-portage.sh` (Task 1).
- Produces: `make sync-portage` runs the resilient fetch on the RUNNER (which has `aws`+creds), then `emerge-webrsync` inside the container over a shared mirror mount.

- [ ] **Step 1: Change the `sync-portage` Makefile target**

Current:
```make
sync-portage: ensure-volume ensure-dirs
	@echo "==> Syncing portage tree (pinned: $(BUILD_EPOCH))"
	$(DOCKER_RUN) $(IMAGE_NAME) emerge-webrsync --revert=$(BUILD_EPOCH)
```
Replace with a version that fetches the snapshot on the host (aws lives here) into a mount, then runs emerge-webrsync in the container pointed at it:
```make
SNAP_MIRROR := $(PROJECT_DIR)/output/portage-mirror
SNAP_MOUNT  := -v $(SNAP_MIRROR):/var/monolith-portage-mirror

sync-portage: ensure-volume ensure-dirs
	@echo "==> Fetching portage snapshot (pinned: $(BUILD_EPOCH)) via self-hosted mirror"
	@mkdir -p $(SNAP_MIRROR)
	SYNC_MIRROR_DIR=$(SNAP_MIRROR) BUILD_EPOCH=$(BUILD_EPOCH) sh scripts/sync-portage.sh fetch-only
	@echo "==> emerge-webrsync from the local mirror"
	$(DOCKER_RUN) $(SNAP_MOUNT) -e BUILD_EPOCH=$(BUILD_EPOCH) $(IMAGE_NAME) \
		sh -c 'GENTOO_MIRRORS="file:///var/monolith-portage-mirror https://distfiles.gentoo.org" emerge-webrsync --revert=$(BUILD_EPOCH)'
```
Add a `fetch-only` mode to `sync-portage.sh` (a one-liner: `[ "${1:-}" = "fetch-only" ] && { fetch_snapshot; exit $?; }` placed just after the `--source-only` guard) so the host step fetches+archives without invoking emerge-webrsync (which only exists in the container). `S3_BUCKET`/`AWS_*` come from the runner env (Step 2). The `aws` CLI is on the GitHub runner; if a local `make` has no `aws`, the script's S3 block is skipped (falls back to upstream) — acceptable for local dev.

- [ ] **Step 2: Pass creds in `build.yml`**

The `build` job already runs `Configure AWS credentials` (sets `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_REGION` in the job env) before "Sync portage". Change the step so the script sees the bucket:
```yaml
      - name: Sync portage
        env:
          S3_BUCKET: ${{ secrets.S3_BUCKET }}
        run: make sync-portage
```
(`AWS_*` are already in the job environment from the credentials step; `make`/the host `sh` inherit them, so `aws s3 cp` in `sync-portage.sh` authenticates.)

- [ ] **Step 3: Verify (parse only; functional validation is Task 7's CI run)**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/build.yml')); print('YAML OK')"` and `make -n sync-portage` (dry-run prints the two commands). Confirm the `fetch-only` arm exists in the script (`grep -n fetch-only scripts/sync-portage.sh`).

- [ ] **Step 4: Commit**

```bash
git add Makefile scripts/sync-portage.sh .github/workflows/build.yml
git commit -m "build: sync-portage fetches the self-hosted snapshot on the runner, feeds the container"
```

---

## Task 3: Dockerfile — bake the toolchain tree at `TOOLCHAIN_EPOCH`

**Files:**
- Modify: `Dockerfile`

**Interfaces:**
- Produces: the builder image pinned to `TOOLCHAIN_EPOCH` (stage3 + baked tree + crossdev toolchain), independent of the runtime `BUILD_EPOCH`.

- [ ] **Step 1: Introduce `TOOLCHAIN_EPOCH` and repoint the baked tree**

In `Dockerfile`:
- Add near the top (keep `BUILD_EPOCH` ARG too, it may still be referenced for labels/SOURCE_DATE_EPOCH docs, but it must NOT gate the image):
  ```dockerfile
  ARG TOOLCHAIN_EPOCH=20260811
  ```
- Change `FROM gentoo/stage3:amd64-openrc-${BUILD_EPOCH} AS base-tools` →
  `FROM gentoo/stage3:amd64-openrc-${TOOLCHAIN_EPOCH} AS base-tools`
- After `FROM`, re-declare `ARG TOOLCHAIN_EPOCH` (ARGs don't cross `FROM`) alongside the existing `ARG BUILD_EPOCH`.
- Change `RUN emerge-webrsync --revert=${BUILD_EPOCH}` → `RUN emerge-webrsync --revert=${TOOLCHAIN_EPOCH}`
- Update the nearby comments: the baked tree is the *toolchain's* build tree, pinned to `TOOLCHAIN_EPOCH`; the runtime package tree is `BUILD_EPOCH`, injected by `sync-portage` at build time.

- [ ] **Step 2: Verify the image build inputs no longer include `BUILD_EPOCH`**

Run: `grep -nE 'BUILD_EPOCH|TOOLCHAIN_EPOCH|FROM|emerge-webrsync' Dockerfile`. Confirm every image-affecting line uses `TOOLCHAIN_EPOCH`; `BUILD_EPOCH` may appear only in comments/labels, not in `FROM`/`emerge-webrsync`/any `RUN` that builds the toolchain.

- [ ] **Step 3: Commit**

```bash
git add Dockerfile
git commit -m "build: bake the crossdev toolchain tree at TOOLCHAIN_EPOCH, not the runtime snapshot"
```

---

## Task 4: Makefile — `TOOLCHAIN_EPOCH` var + decouple base-tools-hash from the snapshot

**Files:**
- Modify: `Makefile`

**Interfaces:**
- Consumes: Dockerfile `TOOLCHAIN_EPOCH` (Task 3).
- Produces: `make build-image` builds/pushes the image keyed on `TOOLCHAIN_EPOCH`+crossdev pins; a `BUILD_EPOCH` change does NOT invalidate the image.

- [ ] **Step 1: Define `TOOLCHAIN_EPOCH` and pass it to buildx**

- Add a `TOOLCHAIN_EPOCH` make variable (read from the Dockerfile, mirroring how `BUILD_EPOCH` is sourced today):
  ```make
  TOOLCHAIN_EPOCH := $(shell grep '^ARG TOOLCHAIN_EPOCH=' Dockerfile | cut -d= -f2)
  ```
- In the `build-image` target's `docker buildx build --target base-tools ...`, pass `--build-arg TOOLCHAIN_EPOCH=$(TOOLCHAIN_EPOCH)` (and keep `--build-arg BUILD_EPOCH=$(BUILD_EPOCH)` only if a comment/label needs it).
- The registry tag currently includes `$(BUILD_EPOCH)` (`docker tag ... $(REGISTRY_IMAGE):$(BUILD_EPOCH)`); change that epoch tag to `$(TOOLCHAIN_EPOCH)` so the image tag reflects what actually pins it.

- [ ] **Step 2: Confirm base-tools-hash is toolchain-only**

The push gate is `COMBINED_HASH = sha256(BASE_HASH + crossdev.lock + binutils/headers vers)`. With Task 3, `BASE_HASH` (the base-tools image layers) is now derived from `TOOLCHAIN_EPOCH`, not `BUILD_EPOCH`, so a snapshot bump leaves `BASE_HASH` unchanged → `build-image` reports "up to date" and skips the crossdev rebuild. No formula change needed; ADD a comment at the hash computation documenting that `BASE_HASH` intentionally excludes the runtime snapshot (which is injected at `sync-portage` time). Verify by inspection that nothing in the base-tools stage still varies with `BUILD_EPOCH`.

- [ ] **Step 3: Verify**

Run: `make -n build-image | grep -E 'TOOLCHAIN_EPOCH|build-arg'` and confirm `TOOLCHAIN_EPOCH` is passed; `grep -nE 'BUILD_EPOCH|TOOLCHAIN_EPOCH' Makefile`.

- [ ] **Step 4: Commit**

```bash
git add Makefile
git commit -m "build: key the builder image on TOOLCHAIN_EPOCH; snapshot bumps no longer rebuild it"
```

---

## Task 5: Lock split + `docs/version-pinning.md`

**Files:**
- Modify: `docs/version-pinning.md`
- Modify: `Makefile` (only if `update-crossdev`/`update-versions` need the epoch source clarified)

**Interfaces:**
- Produces: documented, unambiguous ownership — `crossdev.lock` ↔ `TOOLCHAIN_EPOCH`; `versions.lock` ↔ `BUILD_EPOCH`.

- [ ] **Step 1: Document the two-pin model**

In `docs/version-pinning.md`, add a section stating: `TOOLCHAIN_EPOCH` pins the builder image (stage3 + crossdev toolchain, `crossdev.lock`, `CROSS_*_VER`) and is bumped rarely/deliberately; `BUILD_EPOCH` pins the runtime portage snapshot (self-hosted on S3, `versions.lock`, `SOURCE_DATE_EPOCH`) and is bumped routinely. Show which command regenerates which lock (`make update-versions` → `versions.lock` at `BUILD_EPOCH`; the toolchain flow → `crossdev.lock` at `TOOLCHAIN_EPOCH`). Note the deferred stage3-self-hosting + scheduled-toolchain-cadence follow-ups.

- [ ] **Step 2: Verify `update-versions` targets the runtime snapshot**

Confirm `make update-versions` regenerates `versions.lock` against the tree produced by `sync-portage` (`BUILD_EPOCH`), not the image's baked tree. If it currently reads the image tree, adjust it to run after `sync-portage` so it sees the runtime snapshot. Document the finding in the task report.

- [ ] **Step 3: Commit**

```bash
git add docs/version-pinning.md Makefile
git commit -m "docs(build): document TOOLCHAIN_EPOCH vs BUILD_EPOCH two-pin model"
```

---

## Task 6: pin-bump rework — cheap auto-merged snapshot flow + human-gated toolchain flow

**Files:**
- Modify: `scripts/update-build-pins.sh`
- Modify: `.github/workflows/pin-bump.yml`
- Create: `.github/workflows/toolchain-bump.yml`

**Interfaces:**
- Consumes: `TOOLCHAIN_EPOCH`/`BUILD_EPOCH` (Tasks 3–4), `sync-portage.sh` archiving (Task 1).
- Produces: routine `BUILD_EPOCH` bumps that skip the image rebuild and auto-merge on green; a separate human-gated `TOOLCHAIN_EPOCH` bump.

- [ ] **Step 1: `update-build-pins.sh` — bump `BUILD_EPOCH` only (snapshot path)**

Point `cmd_update`/`cmd_check` at `BUILD_EPOCH` (the runtime snapshot) — they already read/sed `^ARG BUILD_EPOCH=` and verify the snapshot; keep that (it now means the runtime snapshot, which is exactly right). Add a `cmd_update_toolchain` (or a `--toolchain` flag) that seds `^ARG TOOLCHAIN_EPOCH=` for the rare toolchain flow. Keep the fail-closed guard from the prior hardening (verify snapshot exists; assert the sed applied).

- [ ] **Step 2: `pin-bump.yml` — cheap snapshot flow, auto-merge on green**

Rework `pin-bump.yml`'s `bump-and-validate` so a routine bump: (a) bumps `BUILD_EPOCH` + `SOURCE_DATE_EPOCH`; (b) archives the new snapshot to S3 via `sh scripts/sync-portage.sh fetch-only` with `S3_BUCKET`/AWS creds; (c) does NOT run `make build-image` (the image is unchanged — that's the whole point); (d) regenerates `versions.lock` (`make sync-portage update-versions`); (e) dispatches the full build+boot+attestation validation; (f) on **fully-green**, auto-merges the PR (`gh pr merge --squash --auto` or an explicit merge after the wait), else leaves it labeled `needs-fixup`. Remove the crossdev-image rebuild + `crossdev.lock` regen from this flow. Keep the concurrency + wait-for-validation machinery.

- [ ] **Step 3: `toolchain-bump.yml` — human-gated toolchain flow**

Create `.github/workflows/toolchain-bump.yml` (workflow_dispatch, optional `target_epoch`): bumps `TOOLCHAIN_EPOCH`, rebuilds+pushes the image (`make build-image`), regenerates `crossdev.lock`, runs full validation, and opens a PR that a **human merges** (never auto-merge — toolchain changes are consequential). This is the old pin-bump image-rebuild path, moved here and retargeted to `TOOLCHAIN_EPOCH`. (Scheduled cadence deferred — leave only `workflow_dispatch` for now, with a comment that a `schedule:` trigger is a planned follow-up.)

- [ ] **Step 4: Verify**

Run: `bash -n scripts/update-build-pins.sh`; `python3 -c "import yaml; [yaml.safe_load(open(f)) for f in ['.github/workflows/pin-bump.yml','.github/workflows/toolchain-bump.yml']]; print('YAML OK')"`; `actionlint` on both if available. Confirm `pin-bump.yml` no longer calls `make build-image`; `toolchain-bump.yml` does.

- [ ] **Step 5: Commit**

```bash
git add scripts/update-build-pins.sh .github/workflows/pin-bump.yml .github/workflows/toolchain-bump.yml
git commit -m "ci: split pin-bump into cheap auto-merged snapshot flow + human-gated toolchain flow"
```

---

## Task 7: Full CI validation + snapshot backfill + acceptance

**Files:** none (validation + a one-off backfill).

- [ ] **Step 1: Backfill the live snapshots to S3**

Trigger `toolchain-bump.yml` or the routine `pin-bump.yml` (or a one-off `workflow_dispatch`) so `sync-portage.sh fetch-only` archives `gentoo-20260808/10/11.tar.xz` (+ `.gpgsig`) to `s3://$S3_BUCKET/portage-snapshots/`. Confirm via `aws s3 ls s3://$S3_BUCKET/portage-snapshots/` (in a CI step or by the user). This must happen while those snapshots are still live upstream.

- [ ] **Step 2: Full-CI validation build (branch)**

Push the branch, label `full-ci` (or `gh workflow run build.yml --ref feat/decouple-portage-epoch`). Confirm:
  - the `build` job's `sync-portage` fetches the snapshot from **our S3** (log shows `<- s3://…`, not `<- upstream`);
  - `build-image` reports **"up to date"** / does not rebuild the crossdev toolchain (base-tools-hash unchanged) — the ~100 min rebuild does not occur;
  - full build+boot+attestation is green.

- [ ] **Step 3: Pruning-resilience proof**

After Step 1's backfill, set `BUILD_EPOCH` to a snapshot that is **404 upstream but archived in our S3** (e.g. `20260803` re-archived, or `20260808` once it prunes) and run a build; confirm the `build` job succeeds sourcing the snapshot from S3 with upstream unavailable. Record the run URL in the task report.

- [ ] **Step 4: Routine-bump proof**

Run `pin-bump.yml` (routine) against a newer snapshot; confirm it validates green, does NOT rebuild the image, and auto-merges. Record the run URL.

---

## Self-Review

**1. Spec coverage:** two-pin model → Tasks 3–4; self-hosted resilient snapshot → Tasks 1–2; lock split + docs → Task 5; full pin-bump rework (cheap auto-merge + human-gated toolchain) → Task 6; S3 archiving + backfill + acceptance (no-rebuild, S3-fetch, pruning-resilience, reproducibility) → Tasks 1/7. Deferred items (stage3 self-hosting, scheduled toolchain cadence) are explicitly out of scope in Global Constraints + Task 6 Step 3. ✓

**2. Placeholder scan:** No TBD/TODO. CI-validated steps (Tasks 3–7) give concrete edits + explicit acceptance checks; the two genuinely mechanism-uncertain points (emerge-webrsync `file://` feeding; `update-versions` reading the runtime vs image tree) carry a concrete default plus a named verification, not a vague "handle it".

**3. Type/name consistency:** `TOOLCHAIN_EPOCH` / `BUILD_EPOCH` used consistently; `sync-portage.sh` modes `--source-only` / `fetch-only` and env (`SYNC_MIRROR_DIR`, `SYNC_UPSTREAM`, `SYNC_S3_PREFIX`, `S3_BUCKET`, `BUILD_EPOCH`) match between the script, its tests, the Makefile mount (`/var/monolith-portage-mirror`), and build.yml. `fetch_snapshot` is the single produced function name used by the test and live mode.
