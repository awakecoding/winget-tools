---
name: winget-extract-icons
description: 'Extract WinGet app icons in GitHub Actions. Use when asked to extract app icons, run extract-icons.yml batches, trigger workflow_dispatch for extract-icons, process 10 to 25 WinGet packages per run, auto-commit extraction results to the repository, wait for GitHub Actions runs to complete, and populate winget-app-icons with metadata.'
---

# Extract WinGet Icons

Typical inputs: target count and batch size, or explicit package IDs.

Use this skill to grow or refresh `winget-app-icons/` through GitHub Actions instead of local installs.

## Default Behavior

- Select candidates from the cached `svrooij/winget-pkgs-index` catalog unless the user gives explicit package IDs or a custom `-CandidatePath`.
- Exclude package IDs already present under `winget-app-icons/` unless the user asks to reprocess them.
- Prefer 10-package batches.
- Default to the CI-native campaign workflow so later batches keep starting without a local watcher process.
- Run with `auto_commit_results=true` and keep package failures best-effort.

## Procedure

1. Start from [the skill wrapper](./scripts/run-default-campaign.ps1), not ad hoc terminal commands.
2. Use the default `-ExecutionModel Ci` path for multi-batch work so GitHub Actions owns the full campaign lifecycle.
3. Use automatic candidate selection for normal growth, or `-PackageIds` for an explicit retry set.
4. Inspect campaign state later with [the CI status helper](./scripts/get-ci-campaign-status.ps1) instead of relying on a local lock file.
5. Use `-ExecutionModel Local` only when you explicitly want the legacy local watcher and status TSV flow.

## Common Commands

```powershell
# Schedule one normal 10-package CI campaign using automatic candidate selection
.\.agents\skills\winget-extract-icons\scripts\run-default-campaign.ps1 -TargetCount 10 -BatchSize 10

# Schedule a CI campaign for specific package IDs
.\.agents\skills\winget-extract-icons\scripts\run-default-campaign.ps1 -PackageIds Git.Git,SlackTechnologies.Slack

# Schedule from a custom candidate file when you want a fixed package pool
.\.agents\skills\winget-extract-icons\scripts\run-default-campaign.ps1 -CandidatePath .\out\package-ids.txt -TargetCount 10 -BatchSize 10

# Query the latest CI campaign state by campaign ID
.\.agents\skills\winget-extract-icons\scripts\get-ci-campaign-status.ps1 -CampaignId my-campaign-id

# Use the old local watcher loop only when you want per-batch local status files
.\.agents\skills\winget-extract-icons\scripts\run-default-campaign.ps1 -ExecutionModel Local -TargetCount 10 -BatchSize 10
```

## Verify And Retry

1. Confirm the campaign workflow is progressing with `get-ci-campaign-status.ps1` or the Actions UI.
2. Confirm the repo received refreshed `winget-app-icons/<PackageId>/metadata.json` entries from batch auto-commits.
3. Retry only the failed package IDs with `-PackageIds`.

## Operating Rules

- Do not cancel queued or in-progress extraction runs unless the user explicitly asks.
- Do not install packages locally or write directly into `winget-app-icons/` outside the workflow import or auto-commit path.
- Keep batches at or below 25 package IDs.
- Prefer the CI-native campaign workflow when the user wants unattended continuation after the initial dispatch.

## References

- [Campaign flow](./references/campaign-flow.md)
- [Wrapper script](./scripts/run-default-campaign.ps1)
- [CI dispatch helper](./scripts/start-ci-campaign.ps1)
- [CI status helper](./scripts/get-ci-campaign-status.ps1)
