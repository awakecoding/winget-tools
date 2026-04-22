# Campaign Flow

This skill is built around the repository's durable extraction path:

- Workflow: `.github/workflows/extract-icons.yml`
- Campaign runner: `scripts/Invoke-IconExtractionCampaign.ps1`
- Durable output root: `winget-app-icons/<PackageId>/`

## What the runner does

1. Fast-forwards local `master` before selecting a batch.
2. Builds a candidate set from `tests/popular-packages.txt` unless explicit package IDs are provided.
3. Excludes existing package folders by default.
4. Validates candidate package IDs with `winget show` by default, or with `svrooij/winget-pkgs-index index.v2.csv` when `-ValidationSource svrooij-index-v2` is selected.
5. Waits for existing `extract-icons.yml` workflow-dispatch runs to become idle instead of piling onto the queue.
6. Dispatches the workflow with a unique `dispatch_token` and a human-readable `request_label`.
7. Watches the workflow run to completion.
8. Fast-forwards local `master` after each completed batch when workflow auto-commit is enabled.
9. Writes a local status TSV so the agent can summarize what happened without scraping multiple terminals.

## Defaults to prefer

- `BatchSize=10` for normal catalog growth.
- `AutoCommitResults=true` unless the user explicitly wants manual artifact import.
- `TargetCount=10` for a single normal batch when the user says “extract more app icons” without a count.

## Good prompt shapes

- `Extract 10 more winget app icons.`
- `Run one 10-package extract-icons batch and wait for it.`
- `Extract icons for Git.Git, Docker.DockerDesktop, and SlackTechnologies.Slack.`
- `Run a 50-package campaign from popular packages with auto-commit.`

## Result files to inspect

- Plan JSON: `out/icon-campaign-100.json` or the configured campaign path.
- Status TSV: same base name as the campaign path, with `.status.tsv`.
- Durable output: `winget-app-icons/<PackageId>/metadata.json` and optionally `winget-app-icons/<PackageId>/app-icon.ico`.

## Retry Pattern

1. Inspect the status TSV and isolate failed batches or package IDs.
2. Re-run the wrapper with `-PackageIds` for only the retry set.
3. Re-check the status TSV and fast-forwarded repo state before starting a new broad batch.
