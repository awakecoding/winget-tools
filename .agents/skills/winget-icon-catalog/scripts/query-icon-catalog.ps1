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

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..'))
$catalogScript = Join-Path $repoRoot 'scripts\Get-WingetAppIconCatalog.ps1'

if (-not (Test-Path -LiteralPath $catalogScript)) {
    throw "Catalog script not found: $catalogScript"
}

$params = @{
    PackageStateRoot       = $PackageStateRoot
    TopReasonCount         = $TopReasonCount
    SummaryOnly            = $SummaryOnly.IsPresent
    IncludeSummary         = $IncludeSummary.IsPresent
    HasIcon                = $HasIcon.IsPresent
    NoIcon                 = $NoIcon.IsPresent
}

if ($Status) {
    $params['Status'] = $Status
}
if ($PackageIdPattern) {
    $params['PackageIdPattern'] = $PackageIdPattern
}
if ($FailureCategory) {
    $params['FailureCategory'] = $FailureCategory
}
if ($ExtractFailureCategory) {
    $params['ExtractFailureCategory'] = $ExtractFailureCategory
}
if ($ExtractErrorPattern) {
    $params['ExtractErrorPattern'] = $ExtractErrorPattern
}

& $catalogScript @params