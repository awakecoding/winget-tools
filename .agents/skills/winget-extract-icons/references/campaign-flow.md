# Campaign Flow

This skill is built around the repository's durable extraction path:

- Workflow: `.github/workflows/extract-icons.yml`
- CI campaign workflow: `.github/workflows/extract-icons-campaign.yml`
- Campaign planner: `scripts/Invoke-IconExtractionCampaign.ps1`
- Durable output root: `winget-app-icons/<PackageId>/`

## Preferred CI flow

1. The skill wrapper creates a validated campaign plan locally with `scripts/Invoke-IconExtractionCampaign.ps1 -Mode plan`.
2. The wrapper dispatches `.github/workflows/extract-icons-campaign.yml` once with the full compressed plan payload.
3. The campaign workflow expands the plan, creates one batch job per chunk, and runs them sequentially in CI with `max-parallel: 1`.
4. Each batch job calls `.github/workflows/extract-icons.yml` as a reusable workflow, so artifact creation and optional auto-commit stay identical to the single-batch path.
5. Later status checks can read GitHub Actions state directly; they no longer depend on a live local watcher process.

## Legacy local runner flow

1. Fast-forwards local `master` before selecting a batch.
2. Builds a candidate set from the cached `svrooij/winget-pkgs-index` catalog unless explicit package IDs or a custom candidate file are provided.
3. Excludes existing package folders by default.
4. Validates candidate package IDs against the cached `svrooij/winget-pkgs-index index.v2.json` file.
5. Waits for existing `extract-icons.yml` workflow-dispatch runs to become idle instead of piling onto the queue.
6. Dispatches the workflow with a unique `dispatch_token` and a human-readable `request_label`.
7. Watches the workflow run to completion.
8. Fast-forwards local `master` after each completed batch when workflow auto-commit is enabled.
9. Writes a local status TSV so the agent can summarize what happened without scraping multiple terminals.

Use the legacy local runner only when you explicitly want a local status TSV or local artifact import behavior.

## Defaults to prefer

- `BatchSize=10` for normal catalog growth.
- `AutoCommitResults=true` unless the user explicitly wants manual artifact import.
- `TargetCount=10` for a single normal batch when the user says “extract more app icons” without a count.
- Prefer CI campaign dispatch for unattended multi-batch runs.

## Good prompt shapes

- `Extract 10 more winget app icons.`
- `Run one 10-package extract-icons batch and wait for it.`
- `Extract icons for Git.Git, Docker.DockerDesktop, and SlackTechnologies.Slack.`
- `Run a 50-package campaign with auto-commit.`
- `Schedule a 250-package CI campaign and let it keep running after I close my laptop.`
- `Check the CI campaign state for unigetui-winget-untried-500-20260423.`

## Result files to inspect

- Plan JSON: `out/icon-campaign-100.json` or the configured campaign path.
- Status TSV: same base name as the campaign path, with `.status.tsv`, for legacy local-run mode.
- CI status: `get-ci-campaign-status.ps1` plus the Actions UI for the campaign workflow run.
- Durable output: `winget-app-icons/<PackageId>/metadata.json` and optionally `winget-app-icons/<PackageId>/app-icon.ico`.

## Retry Pattern

1. Inspect CI campaign status or the legacy status TSV and isolate failed batches or package IDs.
2. Re-run the wrapper with `-PackageIds` for only the retry set.
3. Re-check Actions state and the fast-forwarded repo state before starting a new broad batch.
