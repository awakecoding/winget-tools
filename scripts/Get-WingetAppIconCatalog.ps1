[CmdletBinding()]
param(
    [string]$PackageStateRoot = 'winget-app-icons',
    [string[]]$Status,
    [string]$PackageIdPattern,
    [switch]$HasIcon,
    [switch]$NoIcon,
    [string[]]$FailureCategory,
    [string[]]$ExtractFailureCategory,
    [string]$ExtractErrorPattern,
    [switch]$SummaryOnly,
    [switch]$IncludeSummary,
    [int]$TopReasonCount = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RepoRoot {
    $root = (& git rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $root) {
        throw 'Run this script from inside the git repository.'
    }

    return $root.Trim()
}

function Resolve-RepoPath {
    param(
        [Parameter(Mandatory)] [string]$RepoRoot,
        [Parameter(Mandatory)] [string]$Path
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $Path))
}

function Get-ExtractErrorSummary {
    param([string]$ExtractError)

    if ([string]::IsNullOrWhiteSpace($ExtractError)) {
        return $null
    }

    $summary = $ExtractError
    $scriptMarker = $summary.IndexOf('; Script=', [System.StringComparison]::OrdinalIgnoreCase)
    if ($scriptMarker -ge 0) {
        $summary = $summary.Substring(0, $scriptMarker)
    }

    $newlineMarker = $summary.IndexOfAny(@([char]"`r", [char]"`n"))
    if ($newlineMarker -ge 0) {
        $summary = $summary.Substring(0, $newlineMarker)
    }

    return $summary.Trim()
}

function Get-OptionalPropertyValue {
    param(
        [Parameter(Mandatory)] [object]$InputObject,
        [Parameter(Mandatory)] [string]$Name,
        $DefaultValue = $null
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $DefaultValue
    }

    return $property.Value
}

function ConvertTo-CountMap {
    param(
        [Parameter(Mandatory)] [object[]]$InputObjects,
        [Parameter(Mandatory)] [scriptblock]$Selector,
        [switch]$Descending,
        [int]$Take = 0
    )

    $groups = @(
        $InputObjects |
            ForEach-Object { & $Selector $_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Group-Object |
            Sort-Object @{ Expression = 'Count'; Descending = $Descending.IsPresent }, Name
    )

    if ($Take -gt 0) {
        $groups = @($groups | Select-Object -First $Take)
    }

    $map = [ordered]@{}
    foreach ($group in $groups) {
        $map[$group.Name] = $group.Count
    }

    return [pscustomobject]$map
}

$repoRoot = Get-RepoRoot
$packageRoot = Resolve-RepoPath -RepoRoot $repoRoot -Path $PackageStateRoot
if (-not (Test-Path -LiteralPath $packageRoot)) {
    throw "Package state root not found: $packageRoot"
}

if ($HasIcon -and $NoIcon) {
    throw 'Use either -HasIcon or -NoIcon, not both.'
}

$metadataFiles = @(
    Get-ChildItem -LiteralPath $packageRoot -Directory |
        ForEach-Object {
            $metadataPath = Join-Path $_.FullName 'metadata.json'
            if (Test-Path -LiteralPath $metadataPath) {
                Get-Item -LiteralPath $metadataPath
            }
        }
)

$rows = New-Object System.Collections.Generic.List[object]
foreach ($metadataFile in $metadataFiles) {
    $metadata = Get-Content -LiteralPath $metadataFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    $packageDir = Split-Path -Path $metadataFile.DirectoryName -Leaf
    $appIconPath = Join-Path $metadataFile.DirectoryName 'app-icon.ico'
    $packageId = Get-OptionalPropertyValue -InputObject $metadata -Name 'packageId' -DefaultValue $packageDir
    $statusValue = Get-OptionalPropertyValue -InputObject $metadata -Name 'status'
    $hasIconValue = Get-OptionalPropertyValue -InputObject $metadata -Name 'hasIcon' -DefaultValue $false
    $failureCategoryValue = Get-OptionalPropertyValue -InputObject $metadata -Name 'failureCategory'
    $extractFailureCategoryValue = Get-OptionalPropertyValue -InputObject $metadata -Name 'extractFailureCategory'
    $extractErrorValue = Get-OptionalPropertyValue -InputObject $metadata -Name 'extractError'
    $extractErrorSummary = Get-ExtractErrorSummary -ExtractError ([string]$extractErrorValue)
    $iconCountValue = Get-OptionalPropertyValue -InputObject $metadata -Name 'iconCount' -DefaultValue 0
    $canonicalIconBytesValue = Get-OptionalPropertyValue -InputObject $metadata -Name 'canonicalIconBytes' -DefaultValue 0
    $lastCheckedUtcValue = Get-OptionalPropertyValue -InputObject $metadata -Name 'lastCheckedUtc'
    $lastUpdatedUtcValue = Get-OptionalPropertyValue -InputObject $metadata -Name 'lastUpdatedUtc'
    $packageVersionValue = Get-OptionalPropertyValue -InputObject $metadata -Name 'packageVersion'
    $wingetVersionValue = Get-OptionalPropertyValue -InputObject $metadata -Name 'wingetVersion'

    $rows.Add([pscustomobject]@{
        PackageId               = [string]$packageId
        PackageDirectory        = $packageDir
        Status                  = if ($null -ne $statusValue) { [string]$statusValue } else { $null }
        HasIcon                 = [bool]$hasIconValue
        AppIconPath             = if (Test-Path -LiteralPath $appIconPath) { $appIconPath } else { $null }
        FailureCategory         = if ($null -ne $failureCategoryValue) { [string]$failureCategoryValue } else { $null }
        ExtractFailureCategory  = if ($null -ne $extractFailureCategoryValue) { [string]$extractFailureCategoryValue } else { $null }
        ExtractErrorSummary     = $extractErrorSummary
        ExtractError            = if ($null -ne $extractErrorValue) { [string]$extractErrorValue } else { $null }
        IconCount               = [int]$iconCountValue
        CanonicalIconBytes      = [int]$canonicalIconBytesValue
        LastCheckedUtc          = if ($null -ne $lastCheckedUtcValue) { [string]$lastCheckedUtcValue } else { $null }
        LastUpdatedUtc          = if ($null -ne $lastUpdatedUtcValue) { [string]$lastUpdatedUtcValue } else { $null }
        PackageVersion          = if ($null -ne $packageVersionValue) { [string]$packageVersionValue } else { $null }
        WingetVersion           = if ($null -ne $wingetVersionValue) { [string]$wingetVersionValue } else { $null }
        MetadataPath            = $metadataFile.FullName
    }) | Out-Null
}

$results = @($rows.ToArray())

if ($Status) {
    $results = @($results | Where-Object { $_.Status -in $Status })
}
if ($PackageIdPattern) {
    $results = @($results | Where-Object { $_.PackageId -like $PackageIdPattern })
}
if ($HasIcon) {
    $results = @($results | Where-Object { $_.HasIcon })
}
if ($NoIcon) {
    $results = @($results | Where-Object { -not $_.HasIcon })
}
if ($FailureCategory) {
    $results = @($results | Where-Object { $_.FailureCategory -in $FailureCategory })
}
if ($ExtractFailureCategory) {
    $results = @($results | Where-Object { $_.ExtractFailureCategory -in $ExtractFailureCategory })
}
if ($ExtractErrorPattern) {
    $results = @($results | Where-Object { $_.ExtractErrorSummary -like $ExtractErrorPattern -or $_.ExtractError -like $ExtractErrorPattern })
}

$summary = [pscustomobject]@{
    GeneratedAtUtc              = (Get-Date).ToUniversalTime().ToString('o')
    PackageStateRoot            = $packageRoot
    TotalPackages               = $results.Count
    WithIconCount               = @($results | Where-Object { $_.HasIcon }).Count
    WithoutIconCount            = @($results | Where-Object { -not $_.HasIcon }).Count
    StatusCounts                = ConvertTo-CountMap -InputObjects $results -Selector { param($row) $row.Status }
    FailureCategoryCounts       = ConvertTo-CountMap -InputObjects $results -Selector { param($row) $row.FailureCategory }
    ExtractFailureCategoryCounts = ConvertTo-CountMap -InputObjects $results -Selector { param($row) $row.ExtractFailureCategory }
    TopExtractErrorReasons      = ConvertTo-CountMap -InputObjects $results -Selector { param($row) $row.ExtractErrorSummary } -Descending -Take $TopReasonCount
}

if ($SummaryOnly) {
    $summary
    return
}

if ($IncludeSummary) {
    [pscustomobject]@{
        Summary = $summary
        Results = $results
    }
    return
}

$results