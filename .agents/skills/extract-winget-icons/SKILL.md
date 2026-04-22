---
name: extract-winget-icons
description: 'Extract WinGet app icons in GitHub Actions. Use when asked to extract app icons, run extract-icons.yml batches, trigger workflow_dispatch for extract-icons, process 10 to 25 WinGet packages per run, auto-commit extraction results to the repository, wait for GitHub Actions runs to complete, and populate winget-app-icons with metadata.'
---

# Extract WinGet Icons

Typical inputs: count and batch size, or explicit package IDs.

Use this skill when the goal is to grow or refresh the git-backed icon catalog under `winget-app-icons/` through the existing GitHub Actions workflow instead of installing packages locally.

## Default Behavior

- Prefer `tests/popular-packages.txt` as the candidate source unless the user gives explicit package IDs.
- Exclude package IDs that already exist under `winget-app-icons/` unless the user asks to reprocess existing entries.
- Prefer 10-package batches for normal population work.
- Dispatch `.github/workflows/extract-icons.yml` with `auto_commit_results=true`.
- Wait for existing `workflow_dispatch` runs of `extract-icons.yml` to finish before dispatching another batch.
- Fast-forward local `master` after each completed batch so later selections see newly committed package folders.
- Treat package-level failures as metadata outcomes, not reasons to abort the entire campaign.

## Procedure

1. Start from the workflow and campaign runner, not from ad hoc terminal one-liners.
2. For automatic batch selection, use the repo campaign runner through [the skill wrapper](./scripts/run-default-campaign.ps1).
3. For explicit package IDs, use the same wrapper with `-PackageIds` so the workflow still uses the durable `winget-app-icons/<PackageId>/` contract.
4. Let the campaign runner handle local locking, workflow-idle waiting, dispatch tokens, run watching, and post-run fast-forward pulls.
5. After completion, inspect the generated status TSV and confirm the repo fast-forwarded cleanly.
6. Only fall back to manual artifact import when workflow auto-commit is disabled or explicitly not desired.

## Common Commands

```powershell
# Extract one normal 10-package batch from tests/popular-packages.txt
.\.agents\skills\extract-winget-icons\scripts\run-default-campaign.ps1 -TargetCount 10 -BatchSize 10

# Extract icons for specific package IDs
.\.agents\skills\extract-winget-icons\scripts\run-default-campaign.ps1 -PackageIds Git.Git,SlackTechnologies.Slack
```

## Verify And Retry

1. Check the status TSV written next to the campaign plan and confirm each batch finished with `success`.
2. Fast-forward local `master` and confirm new package folders or refreshed `metadata.json` files appeared under `winget-app-icons/<PackageId>/`.
3. If some batches failed, collect the failed package IDs from the status TSV or plan JSON, then re-run the wrapper with `-PackageIds` for only that retry set.
4. If the failure is package-specific and the workflow recorded metadata, treat it as a completed extraction attempt unless the user explicitly wants another retry.

## Operating Rules

- Do not cancel queued or in-progress extraction runs unless the user explicitly asks to purge them.
- Do not install packages locally as part of the normal extraction workflow.
- Do not write directly into `winget-app-icons/` outside the workflow import/auto-commit path.
- Keep batches at or below the workflow maximum of 25 package IDs.

## References

- [Campaign flow](./references/campaign-flow.md)
- [Wrapper script](./scripts/run-default-campaign.ps1)
