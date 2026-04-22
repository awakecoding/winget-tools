---
name: winget-extract-icons
description: 'Extract WinGet app icons in GitHub Actions. Use when asked to extract app icons, run extract-icons.yml batches, trigger workflow_dispatch for extract-icons, process 10 to 25 WinGet packages per run, auto-commit extraction results to the repository, wait for GitHub Actions runs to complete, and populate winget-app-icons with metadata.'
---

# Extract WinGet Icons

Typical inputs: target count and batch size, or explicit package IDs.

Use this skill to grow or refresh `winget-app-icons/` through `.github/workflows/extract-icons.yml` instead of local installs.

## Default Behavior

- Select candidates from the cached `svrooij/winget-pkgs-index` catalog unless the user gives explicit package IDs or a custom `-CandidatePath`.
- Exclude package IDs already present under `winget-app-icons/` unless the user asks to reprocess them.
- Prefer 10-package batches.
- Run with `auto_commit_results=true` and keep package failures best-effort.

## Procedure

1. Start from [the skill wrapper](./scripts/run-default-campaign.ps1), not ad hoc terminal commands.
2. Use automatic candidate selection for normal growth, or `-PackageIds` for an explicit retry set.
3. Let the campaign runner handle locking, workflow-idle waits, dispatch tokens, run watching, and post-run fast-forward pulls.
4. Inspect the status TSV after completion.

## Common Commands

```powershell
# Extract one normal 10-package batch using automatic candidate selection
.\.agents\skills\winget-extract-icons\scripts\run-default-campaign.ps1 -TargetCount 10 -BatchSize 10

# Extract icons for specific package IDs
.\.agents\skills\winget-extract-icons\scripts\run-default-campaign.ps1 -PackageIds Git.Git,SlackTechnologies.Slack

# Extract from a custom candidate file when you want a fixed package pool
.\.agents\skills\winget-extract-icons\scripts\run-default-campaign.ps1 -CandidatePath .\out\package-ids.txt -TargetCount 10 -BatchSize 10
```

## Verify And Retry

1. Confirm each batch finished with `success` in the status TSV.
2. Confirm the repo fast-forwarded and refreshed `winget-app-icons/<PackageId>/metadata.json` entries appeared.
3. Retry only the failed package IDs with `-PackageIds`.

## Operating Rules

- Do not cancel queued or in-progress extraction runs unless the user explicitly asks.
- Do not install packages locally or write directly into `winget-app-icons/` outside the workflow import or auto-commit path.
- Keep batches at or below 25 package IDs.

## References

- [Campaign flow](./references/campaign-flow.md)
- [Wrapper script](./scripts/run-default-campaign.ps1)
