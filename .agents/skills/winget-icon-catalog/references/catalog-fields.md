# Catalog Fields

The wrapper returns one object per package directory with these high-value fields:

- `PackageId`
- `Status`
- `HasIcon`
- `FailureCategory`
- `ExtractFailureCategory`
- `ExtractErrorSummary`
- `ExtractError`
- `IconCount`
- `CanonicalIconBytes`
- `LastCheckedUtc`
- `LastUpdatedUtc`
- `MetadataPath`

Summary output includes:

- `TotalPackages`
- `WithIconCount`
- `WithoutIconCount`
- `StatusCounts`
- `FailureCategoryCounts`
- `ExtractFailureCategoryCounts`
- `TopExtractErrorReasons`

Use `ExtractErrorSummary` for grouping. It strips stack-trace noise from `extractError` so repeated failures collapse into stable reasons.