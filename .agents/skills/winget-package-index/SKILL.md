---
name: winget-package-index
description: 'Fetch and use the svrooij/winget-pkgs-index package catalog through a cached JSON index file instead of winget CLI package lookups when asked to search WinGet packages, find an app ID, look up software in WinGet, resolve package metadata, build candidate lists, or run index-backed icon extraction campaigns.'
---

# Use WinGet Package Index

Use this skill when package discovery should come from the cached `svrooij/winget-pkgs-index` JSON file parsed in PowerShell.

## Default Behavior

- Use the cached `index.v2.json` file under `out/`.
- Keep the existing extraction workflow and `winget-app-icons/<PackageId>/` output contract unchanged.

## Cache Details

- Cache path: `out/cache/winget-pkgs-index/index.v2.json`
- Source URL: `https://github.com/svrooij/winget-pkgs-index/raw/main/index.v2.json`
- Expected top-level shape: JSON array of objects with `PackageId`, `Version`, `Name`, and `LastUpdate`.
- Refresh only when the user asks for the latest catalog, when the cache is missing or malformed, or when the file is older than 4 hours.

## Procedure

1. Start from [the index-backed wrapper](./scripts/run-index-backed-campaign.ps1) or the campaign runner, not ad hoc `winget` queries.
2. Use `-PackageIds` when the user gives an explicit retry set.
3. Verify the cached JSON matches the [Cache Details](#cache-details) section before relying on it.
4. Treat the external index as an availability filter only; install and extraction still happen inside `.github/workflows/extract-icons.yml`.

## Common Commands

```powershell
# Run one index-backed 10-package extraction batch
.\.agents\skills\winget-package-index\scripts\run-index-backed-campaign.ps1 -TargetCount 10 -BatchSize 10 -RefreshIndex

# Run index-backed extraction for explicit package IDs
.\.agents\skills\winget-package-index\scripts\run-index-backed-campaign.ps1 -PackageIds Git.Git,SlackTechnologies.Slack -RefreshIndex

# Plan directly with the campaign runner using the external JSON index cache
.\scripts\Invoke-IconExtractionCampaign.ps1 -Mode plan -RefreshWingetIndexCache -TargetCount 10 -BatchSize 10
```

## Verify And Retry

1. Confirm the cache matches the [Cache Details](#cache-details) section.
2. After the campaign finishes, confirm the status TSV and plan JSON record `validationSource` as `svrooij-index-v2`.
3. Retry failed package IDs with `-PackageIds`; refresh the cache only when it is stale or malformed.

## Operating Rules

- Do not replace the extraction workflow with direct writes into `winget-app-icons/`.

## References

- [Index-backed campaign wrapper](./scripts/run-index-backed-campaign.ps1)
- [Campaign flow](../winget-extract-icons/references/campaign-flow.md)