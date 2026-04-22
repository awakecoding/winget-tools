---
name: winget-icon-catalog
description: 'Inspect and query the winget-app-icons catalog when asked to count packages with icons, list missing or failed extractions, filter metadata.json records by status or failure reason, or summarize extraction outcomes from the local registry.'
---

# Inspect WinGet Icon Catalog

Use this skill to query `winget-app-icons/*/metadata.json` and the presence of `app-icon.ico` files.

## Default Behavior

- Read the local `winget-app-icons/` registry instead of rebuilding summaries from ad hoc searches.
- Start from [the wrapper script](./scripts/query-icon-catalog.ps1).
- Use `-SummaryOnly` for counts, then add filters only when the user asks for a narrower slice.

## Common Commands

```powershell
# Count packages with and without icons, plus grouped status and failure totals
.\.agents\skills\winget-icon-catalog\scripts\query-icon-catalog.ps1 -SummaryOnly

# List packages that failed during extraction
.\.agents\skills\winget-icon-catalog\scripts\query-icon-catalog.ps1 -Status ExtractError

# Filter failures to one category
.\.agents\skills\winget-icon-catalog\scripts\query-icon-catalog.ps1 -ExtractFailureCategory ManifestUnavailable

# Find failures whose extracted error mentions ARP
.\.agents\skills\winget-icon-catalog\scripts\query-icon-catalog.ps1 -ExtractErrorPattern *ARP*

# Return both summary data and matching rows
.\.agents\skills\winget-icon-catalog\scripts\query-icon-catalog.ps1 -NoIcon -IncludeSummary
```

## Filters

- `-Status` filters by metadata status such as `HasIcon`, `NoIcon`, `InstallFailed`, or `ExtractError`.
- `-HasIcon` and `-NoIcon` filter on the current `app-icon.ico` state.
- `-FailureCategory` and `-ExtractFailureCategory` narrow the results to a failure class.
- `-ExtractErrorPattern` filters on the normalized extract-error text.
- `-PackageIdPattern` filters package IDs with PowerShell wildcard matching.

## Verify And Retry

1. Start with `-SummaryOnly` to confirm the totals.
2. Add one filter at a time when drilling into failures.
3. Use `-IncludeSummary` when the user wants both counts and matching rows in one result.

## References

- [Field guide](./references/catalog-fields.md)
- [Wrapper script](./scripts/query-icon-catalog.ps1)