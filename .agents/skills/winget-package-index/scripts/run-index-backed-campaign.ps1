[CmdletBinding(DefaultParameterSetName = 'Campaign')]
param(
    [Parameter(ParameterSetName = 'Campaign')]
    [string]$CandidatePath = 'tests/popular-packages.txt',

    [Parameter(ParameterSetName = 'Campaign')]
    [int]$TargetCount = 10,

    [Parameter(ParameterSetName = 'Inline', Mandatory)]
    [string[]]$PackageIds,

    [int]$BatchSize = 10,
    [string]$CampaignPath = 'out/icon-campaign-index-skill.json',
    [string]$StatusPath,
    [string]$CampaignId,
    [switch]$IncludeExisting,
    [switch]$RefreshIndex,
    [switch]$ContinueOnBatchFailure
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..'))
$campaignScript = Join-Path $repoRoot 'scripts\Invoke-IconExtractionCampaign.ps1'

if (-not (Test-Path -LiteralPath $campaignScript)) {
    throw "Campaign script not found: $campaignScript"
}

$params = @{
    Mode                   = 'run'
    CampaignPath           = $CampaignPath
    BatchSize              = $BatchSize
    Ref                    = 'master'
    AutoCommitResults      = $true
    ValidationSource       = 'svrooij-index-v2'
    RefreshWingetIndexCache = $RefreshIndex.IsPresent
    ContinueOnBatchFailure = $ContinueOnBatchFailure.IsPresent
}

if ($StatusPath) {
    $params['StatusPath'] = $StatusPath
}
if ($CampaignId) {
    $params['CampaignId'] = $CampaignId
}

if ($PSCmdlet.ParameterSetName -eq 'Inline') {
    $cleanIds = @($PackageIds | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() } | Select-Object -Unique)
    if ($cleanIds.Count -eq 0) {
        throw 'Provide at least one package ID.'
    }

    $inlineCandidatePath = Join-Path $repoRoot ("out/skill-inline-package-ids-{0}.txt" -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
    $dir = Split-Path -Path $inlineCandidatePath -Parent
    if ($dir) {
        [void](New-Item -ItemType Directory -Path $dir -Force)
    }
    $cleanIds | Set-Content -LiteralPath $inlineCandidatePath -Encoding UTF8

    $params['CandidatePath'] = $inlineCandidatePath
    $params['TargetCount'] = $cleanIds.Count
    $params['IncludeExisting'] = $true
}
else {
    $params['CandidatePath'] = $CandidatePath
    $params['TargetCount'] = $TargetCount
    $params['IncludeExisting'] = $IncludeExisting.IsPresent
}

& $campaignScript @params