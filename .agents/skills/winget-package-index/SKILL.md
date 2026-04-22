---
name: winget-package-index
description: 'Fetch and use the svrooij/winget-pkgs-index package catalog instead of winget show when asked to search WinGet packages, find an app ID, look up software in WinGet, resolve package metadata, build candidate lists, or run index-backed icon extraction campaigns.'
---

# Use WinGet Package Index

Typical inputs: count and batch size, or explicit package IDs.

Use this skill when package discovery or validation should come from the external `svrooij/winget-pkgs-index` dataset instead of repeated `winget show` calls.

## Default Behavior

- Prefer `index.v2.csv` from `svrooij/winget-pkgs-index` because it is the fast path.
- Refresh the cache when it is missing or when the user asks for the latest index.
- When paired with icon extraction, call the campaign runner with `-ValidationSource svrooij-index-v2` so candidate validation stays local and fast.
- Keep the existing extraction workflow, batching, auto-commit, and `winget-app-icons/<PackageId>/` output contract unchanged.

## Cache Details

- Cache path: `out/cache/winget-pkgs-index/index.v2.csv`
- Expected header columns: `PackageId`, `Version`, `Name`, `LastUpdate`
- Refresh the cache before planning or running when the user asks for the latest catalog or when the cached file is missing or malformed.

## Procedure

1. Start from the campaign runner, not from ad hoc `winget show` loops.
2. Use [the index-backed wrapper](./scripts/run-index-backed-campaign.ps1) for prompt-driven extraction work that should validate against `svrooij/winget-pkgs-index`.
3. For explicit package IDs, use the same wrapper with `-PackageIds` so the workflow path remains identical and only the validation source changes.
4. If the user needs the freshest catalog, refresh the cache before planning or running the campaign.
5. Verify the cache matches the [Cache Details](#cache-details) section before relying on it for selection.
6. Treat the external index as an availability filter only; the actual install and extraction still happen inside `.github/workflows/extract-icons.yml`.

## Common Commands

```powershell
# Run one index-backed 10-package extraction batch
.\.agents\skills\winget-package-index\scripts\run-index-backed-campaign.ps1 -TargetCount 10 -BatchSize 10 -RefreshIndex

# Run index-backed extraction for explicit package IDs
.\.agents\skills\winget-package-index\scripts\run-index-backed-campaign.ps1 -PackageIds Git.Git,SlackTechnologies.Slack -RefreshIndex

# Plan directly with the campaign runner using the external index
.\scripts\Invoke-IconExtractionCampaign.ps1 -Mode plan -ValidationSource svrooij-index-v2 -RefreshWingetIndexCache -TargetCount 10 -BatchSize 10
```

## Verify And Retry

1. Confirm the cache matches the [Cache Details](#cache-details) section.
2. After the campaign finishes, inspect the status TSV and confirm the plan JSON records `validationSource` as `svrooij-index-v2`.
3. If a batch fails, retry only the failed package IDs with the wrapper's `-PackageIds` parameter instead of rebuilding the whole candidate set.
4. If the cache is stale or malformed, refresh it and re-run the same command before widening the investigation.

## Operating Rules

- Do not treat the external index as a replacement for the extraction workflow; it only replaces slow local availability probes.
- Prefer `index.v2.csv` over the older `index.csv` and JSON variants unless a task explicitly needs a different format.
- Do not write directly into `winget-app-icons/` from this skill.

## References

- [Index-backed campaign wrapper](./scripts/run-index-backed-campaign.ps1)
- [Campaign flow](../extract-winget-icons/references/campaign-flow.md)