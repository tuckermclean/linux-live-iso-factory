#!/usr/bin/env python3
"""
generate-provenance.py — Pillar 6: SLSA Provenance v1.0 for The Monolith ISO.

Produces an in-toto Statement (https://in-toto.io/Statement/v1) with a
SLSA Build v1.0 predicate (https://slsa.dev/provenance/v1).

Build-specific inputs come from CLI args (passed by attestation.sh).
GitHub Actions context comes from environment variables forwarded into
the container via `docker run -e GITHUB_*` (see Makefile GITHUB_ENV).
When those vars are absent (local dev), placeholder values are used and
the predicate is still written — only the subject digest is required.

Usage (called by attestation.sh):
    generate-provenance.py --iso-sha256 HEX --iso-name NAME \
                           --build-tag TAG --output PATH \
                           [--builder-digest ID]

Exit codes:
    0   provenance written successfully
    1   --iso-sha256 missing or not computed (cannot produce a valid subject)
"""

import argparse
import hashlib
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path


def sha256_file(path: Path) -> str | None:
    try:
        h = hashlib.sha256()
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(65536), b""):
                h.update(chunk)
        return h.hexdigest()
    except OSError:
        return None


def env(key: str, default: str = "") -> str:
    return os.environ.get(key, default)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Generate SLSA v1.0 provenance for The Monolith ISO"
    )
    parser.add_argument("--iso-sha256",     required=True,  metavar="HEX")
    parser.add_argument("--iso-name",       required=True,  metavar="NAME")
    parser.add_argument("--build-tag",      required=True,  metavar="TAG")
    parser.add_argument("--output",         required=True,  metavar="PATH")
    parser.add_argument("--builder-digest", default="",     metavar="ID")
    # Build input pinning — these enrich resolvedDependencies so verifiers can
    # identify every input that determined the ISO contents, not just the source repo.
    parser.add_argument("--portage-snapshot-epoch", default="", metavar="EPOCH",
                        help="BUILD_EPOCH used for emerge-webrsync (e.g. 20260406)")
    parser.add_argument("--stage3-epoch",           default="", metavar="EPOCH",
                        help="BUILD_EPOCH used for gentoo/stage3 base image")
    parser.add_argument("--kernel-version",         default="", metavar="VER",
                        help="Upstream kernel version built (e.g. 6.12.80)")
    # Real build timestamps — bracketing when the actual compilation ran, not when
    # this script runs. Passed in by attestation.sh which records them around pillars.
    parser.add_argument("--build-started-on",  default="", metavar="ISO8601")
    parser.add_argument("--build-finished-on", default="", metavar="ISO8601")
    args = parser.parse_args()

    if not args.iso_sha256 or args.iso_sha256 == "(not computed)":
        print(
            "[provenance] ERROR: --iso-sha256 is empty or not computed — "
            "ISO must be present when attestation.sh runs",
            file=sys.stderr,
        )
        return 1

    output_path = Path(args.output)

    # ── GitHub Actions context (env vars forwarded from host into Docker) ────
    server_url           = env("GITHUB_SERVER_URL",              "https://github.com")
    repository           = env("GITHUB_REPOSITORY",              "unknown/unknown")
    repository_id        = env("GITHUB_REPOSITORY_ID",           "")
    repository_owner_id  = env("GITHUB_REPOSITORY_OWNER_ID",     "")
    repository_visibility = env("GITHUB_REPOSITORY_VISIBILITY",  "public")
    ref                  = env("GITHUB_REF",                     "refs/heads/master")
    sha                  = env("GITHUB_SHA",                     "unknown")
    run_id               = env("GITHUB_RUN_ID",                  "0")
    run_number           = env("GITHUB_RUN_NUMBER",              "0")
    run_attempt          = env("GITHUB_RUN_ATTEMPT",             "1")
    event_name           = env("GITHUB_EVENT_NAME",              "unknown")
    workflow_ref         = env(
        "GITHUB_WORKFLOW_REF",
        f"{repository}/.github/workflows/build.yml@{ref}",
    )
    workflow_sha         = env("GITHUB_WORKFLOW_SHA",            sha)
    actor                = env("GITHUB_ACTOR",                   "")
    actor_id             = env("GITHUB_ACTOR_ID",                "")

    repo_url      = f"{server_url}/{repository}"
    workflow_path = ".github/workflows/build.yml"
    invocation_id = f"{repo_url}/actions/runs/{run_id}/attempts/{run_attempt}"

    # buildType must be the GitHub Actions canonical build type URI — the
    # GitHub Attestations API rejects any other value for SLSA v1 predicates.
    build_type = "https://actions.github.io/buildtypes/workflow/v1"

    # builder.id identifies the trusted build platform — the workflow ref
    builder_id = f"{server_url}/{workflow_ref}"

    # ── Timestamps ───────────────────────────────────────────────────────────
    # Use caller-supplied timestamps when available so the provenance brackets
    # the actual build rather than just the attestation creation moment.
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    started_on  = args.build_started_on  or now
    finished_on = args.build_finished_on or now

    # ── resolvedDependencies ─────────────────────────────────────────────────
    # Each entry names a distinct external input that determines the ISO contents.
    # Without these, the provenance proves authorship but not input transparency.
    resolved_deps: list[dict] = [
        {
            "uri": f"git+{repo_url}@{ref}",
            "digest": {"gitCommit": sha},
            "name": repository,
        }
    ]

    # Gentoo stage3 base image — the toolchain bootstrap layer. BUILD_EPOCH pins
    # the exact daily tag so the same epoch always resolves to the same image.
    if args.stage3_epoch:
        resolved_deps.append({
            "uri": f"docker.io/gentoo/stage3:amd64-openrc-{args.stage3_epoch}",
            "name": "gentoo-stage3",
        })

    # Portage snapshot — the ebuild tree that drove all package selections and
    # patches. emerge-webrsync downloads gentoo-EPOCH.tar.xz and verifies its
    # GPG signature against the bundled Gentoo release key before extracting.
    if args.portage_snapshot_epoch:
        resolved_deps.append({
            "uri": (
                f"https://distfiles.gentoo.org/snapshots/"
                f"gentoo-{args.portage_snapshot_epoch}.tar.xz"
            ),
            "name": "gentoo-portage-snapshot",
        })

    # Upstream kernel source tarball. The version is extracted from the enriched
    # SBOM's monolith-kernel component by attestation.sh after Pillar 1b.
    if args.kernel_version:
        major = args.kernel_version.split(".")[0]
        resolved_deps.append({
            "uri": (
                f"https://cdn.kernel.org/pub/linux/kernel/"
                f"v{major}.x/linux-{args.kernel_version}.tar.xz"
            ),
            "name": "linux-kernel-source",
        })

    # Builder Docker image — the compiled crossdev toolchain layer on top of stage3.
    if args.builder_digest:
        owner = repository.split("/")[0]
        resolved_deps.append(
            {
                "uri": f"pkg:docker/ghcr.io/{owner}/monolith-builder",
                "digest": {"sha256": args.builder_digest.removeprefix("sha256:")},
                "name": "monolith-builder",
            }
        )

    # ── Byproducts: other attestation artifacts in the same output dir ───────
    attestation_dir = output_path.parent
    byproduct_specs = [
        ("bom.cdx.json",             "application/vnd.cyclonedx+json"),
        ("sbom.cdx.json",            "application/vnd.cyclonedx+json"),
        ("cve-report.cdx.json",      "application/vnd.cyclonedx+json"),
        ("license-report.json",      "application/json"),
        ("unowned-report.json",      "application/json"),
        ("attestation-summary.json", "application/json"),
    ]
    byproducts = []
    for filename, media_type in byproduct_specs:
        digest = sha256_file(attestation_dir / filename)
        if digest is not None:
            byproducts.append(
                {
                    "name": filename,
                    "mediaType": media_type,
                    "digest": {"sha256": digest},
                }
            )

    # ── Assemble SLSA v1.0 in-toto statement ─────────────────────────────────
    statement = {
        "_type": "https://in-toto.io/Statement/v1",
        "subject": [
            {
                "name": args.iso_name,
                "digest": {"sha256": args.iso_sha256},
            }
        ],
        "predicateType": "https://slsa.dev/provenance/v1",
        "predicate": {
            "buildDefinition": {
                "buildType": build_type,
                "externalParameters": {
                    "workflow": {
                        "ref":        ref,
                        "repository": repo_url,
                        "path":       workflow_path,
                    }
                },
                "internalParameters": {
                    "github": {
                        "event_name":             event_name,
                        "sha":                    sha,
                        "ref":                    ref,
                        "workflow_ref":            workflow_ref,
                        "workflow_sha":            workflow_sha,
                        "repository_id":          repository_id,
                        "repository_owner_id":    repository_owner_id,
                        "repository_visibility":  repository_visibility,
                        "actor":                  actor,
                        "actor_id":               actor_id,
                        "run_id":                 run_id,
                        "run_number":             run_number,
                        "run_attempt":            run_attempt,
                        "runner_environment":     "github-hosted",
                    },
                    "build": {
                        "tag": args.build_tag,
                        # SOURCE_DATE_EPOCH clamps all build-output timestamps;
                        # recording it here lets verifiers confirm the setting.
                        "source_date_epoch": env("SOURCE_DATE_EPOCH", ""),
                    },
                },
                "resolvedDependencies": resolved_deps,
            },
            "runDetails": {
                "builder": {
                    "id": builder_id,
                    **(
                        {"version": {"monolith-builder": args.builder_digest}}
                        if args.builder_digest
                        else {}
                    ),
                },
                "metadata": {
                    "invocationId": invocation_id,
                    "startedOn":    started_on,
                    "finishedOn":   finished_on,
                },
                **({"byproducts": byproducts} if byproducts else {}),
            },
        },
    }

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(statement, indent=2) + "\n")

    print(f"[provenance] Written: {output_path}")
    print(f"[provenance]   Subject:     {args.iso_name}")
    print(f"[provenance]   SHA-256:     {args.iso_sha256[:16]}...")
    print(f"[provenance]   Builder ID:  {builder_id}")
    print(f"[provenance]   Invocation:  {invocation_id}")
    print(f"[provenance]   Byproducts:  {len(byproducts)} artifact(s) recorded")
    return 0


if __name__ == "__main__":
    sys.exit(main())
