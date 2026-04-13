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
    # startedOn: approximate — the attestation job starts shortly after the build
    started_on  = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    finished_on = started_on  # refined below after writing the file

    # ── resolvedDependencies ─────────────────────────────────────────────────
    resolved_deps: list[dict] = [
        {
            "uri": f"git+{repo_url}@{ref}",
            "digest": {"gitCommit": sha},
            "name": repository,
        }
    ]
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
        ("sbom-enriched.cdx.json",   "application/vnd.cyclonedx+json"),
        ("sbom.cdx.json",            "application/vnd.cyclonedx+json"),
        ("cve-report.json",          "application/json"),
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
