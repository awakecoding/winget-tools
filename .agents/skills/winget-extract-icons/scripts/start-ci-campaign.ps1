[CmdletBinding(DefaultParameterSetName = 'Campaign')]
param(
    [Parameter(ParameterSetName = 'Campaign')]
    [string]$CandidatePath,

    [Parameter(ParameterSetName = 'Campaign')]
    [int]$TargetCount = 10,

    [Parameter(ParameterSetName = 'Inline', Mandatory)]
    [string[]]$PackageIds,

    [int]$BatchSize = 10,
    [string]$CampaignPath = 'out/icon-campaign-skill.json',
    [string]$CampaignId,
    [switch]$IncludeExisting,
    [switch]$RefreshWingetIndexCache,
    [bool]$UninstallAfter = $true,
    [int]$PerPackageTimeout = 900,
    [bool]$AutoCommitResults = $true,
    [switch]$ContinueOnBatchFailure,
    [string]$WorkflowName = 'extract-icons-campaign.yml',
    [string]$Ref = 'master'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$env:GH_FORCE_TTY = '0'
$env:GH_PAGER = ''
$env:PAGER = ''
$env:GH_PROMPT_DISABLED = '1'
$env:NO_COLOR = '1'

function Normalize-GhJson {
    param([Parameter(Mandatory)] [string]$Text)

    return ([regex]::Replace($Text, '\x1B\[[0-9;]*[A-Za-z]', '')).Trim()
}

function ConvertTo-GzipBase64 {
    param([Parameter(Mandatory)] [string]$Text)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $outputStream = [System.IO.MemoryStream]::new()
    try {
        $gzipStream = [System.IO.Compression.GZipStream]::new($outputStream, [System.IO.Compression.CompressionLevel]::Optimal, $true)
        try {
            $gzipStream.Write($bytes, 0, $bytes.Length)
        }
        finally {
            $gzipStream.Dispose()
        }

        return [Convert]::ToBase64String($outputStream.ToArray())
    }
    finally {
        $outputStream.Dispose()
    }
}

function Get-RepoRoot {
    $root = (& git rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $root) {
        throw 'Run this script from inside the git repository.'
    }

    return $root.Trim()
}

function Resolve-CampaignRun {
    param(
        [Parameter(Mandatory)] [string]$Workflow,
        [Parameter(Mandatory)] [string]$CampaignIdentifier
    )

    $json = Normalize-GhJson -Text (@(& gh run list --workflow $Workflow --branch $Ref --event workflow_dispatch --limit 20 --json databaseId,status,conclusion,displayTitle,createdAt,updatedAt,url 2>$null) -join "`n")
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) {
        return $null
    }

    return @($json | ConvertFrom-Json | Where-Object {
            [string]$_.displayTitle -like ('*' + $CampaignIdentifier + '*')
        } | Sort-Object createdAt -Descending | Select-Object -First 1)
}

$repoRoot = Get-RepoRoot
$campaignScript = Join-Path $repoRoot 'scripts\Invoke-IconExtractionCampaign.ps1'
if (-not (Test-Path -LiteralPath $campaignScript)) {
    throw "Campaign script not found: $campaignScript"
}

$tempCandidatePath = $null
try {
    $planParams = @{
        Mode                   = 'plan'
        CampaignPath           = $CampaignPath
        BatchSize              = $BatchSize
        Ref                    = $Ref
        AutoCommitResults      = $AutoCommitResults
        PerPackageTimeout      = $PerPackageTimeout
    }

    if ($CampaignId) {
        $planParams['CampaignId'] = $CampaignId
    }
    if ($RefreshWingetIndexCache.IsPresent) {
        $planParams['RefreshWingetIndexCache'] = $true
    }

    if ($PSCmdlet.ParameterSetName -eq 'Inline') {
        $cleanIds = @(
            $PackageIds |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                ForEach-Object { $_.Trim() } |
                Select-Object -Unique
        )
        if ($cleanIds.Count -eq 0) {
            throw 'Provide at least one package ID.'
        }

        $tempCandidatePath = Join-Path $repoRoot ('out/skill-inline-package-ids-{0}.txt' -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
        $tempDir = Split-Path -Path $tempCandidatePath -Parent
        if ($tempDir) {
            [void](New-Item -ItemType Directory -Path $tempDir -Force)
        }
        $cleanIds | Set-Content -LiteralPath $tempCandidatePath -Encoding UTF8

        $planParams['CandidatePath'] = $tempCandidatePath
        $planParams['TargetCount'] = $cleanIds.Count
        $planParams['IncludeExisting'] = $true
    }
    else {
        if (-not [string]::IsNullOrWhiteSpace($CandidatePath)) {
            $planParams['CandidatePath'] = $CandidatePath
        }
        $planParams['TargetCount'] = $TargetCount
        $planParams['IncludeExisting'] = $IncludeExisting.IsPresent
    }

    & $campaignScript @planParams

    $planJson = Get-Content -LiteralPath $CampaignPath -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($planJson)) {
        throw ("Campaign plan file is empty: {0}" -f $CampaignPath)
    }

    $plan = $planJson | ConvertFrom-Json -Depth 10
    if (-not $plan) {
        throw ("Unable to load campaign plan from {0}." -f $CampaignPath)
    }

    $planPayload = ConvertTo-GzipBase64 -Text $planJson
    $campaignIdentifier = [string]$plan.campaignId
    $campaignRunLabel = 'Extract WinGet icon campaign {0} ({1} batches)' -f $campaignIdentifier, @($plan.batches).Count

    $dispatchOutput = @(
        & gh workflow run $WorkflowName --ref $Ref `
            -f ("campaign_id={0}" -f $campaignIdentifier) `
            -f ("campaign_run_label={0}" -f $campaignRunLabel) `
            -f ("campaign_gzip_base64={0}" -f $planPayload) `
            -f ("uninstall_after={0}" -f ([string]$UninstallAfter).ToLowerInvariant()) `
            -f ("per_package_timeout={0}" -f $PerPackageTimeout) `
            -f ("auto_commit_results={0}" -f ([string]$AutoCommitResults).ToLowerInvariant()) `
            -f ("continue_on_batch_failure={0}" -f ([string]$ContinueOnBatchFailure.IsPresent).ToLowerInvariant()) 2>&1
    )
    $dispatchText = ($dispatchOutput | ForEach-Object { $_.ToString() }) -join "`n"
    if ($LASTEXITCODE -ne 0) {
        throw ("Failed to dispatch workflow {0}. {1}" -f $WorkflowName, $dispatchText.Trim())
    }

    $run = Resolve-CampaignRun -Workflow $WorkflowName -CampaignIdentifier $campaignIdentifier

    [pscustomobject]@{
        workflow           = $WorkflowName
        ref                = $Ref
        campaignId         = $campaignIdentifier
        batchCount         = @($plan.batches).Count
        validatedCount     = [int]$plan.validatedCount
        autoCommitResults  = $AutoCommitResults
        continueOnFailure  = $ContinueOnBatchFailure.IsPresent
        dispatchOutput     = if ($dispatchText) { $dispatchText.Trim() } else { $null }
        runId              = if ($run) { [string]$run.databaseId } else { $null }
        runStatus          = if ($run) { [string]$run.status } else { $null }
        runUrl             = if ($run) { [string]$run.url } else { $null }
        planPath           = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $CampaignPath))
    }
}
finally {
    if ($tempCandidatePath -and (Test-Path -LiteralPath $tempCandidatePath)) {
        Remove-Item -LiteralPath $tempCandidatePath -Force -ErrorAction SilentlyContinue
    }
}