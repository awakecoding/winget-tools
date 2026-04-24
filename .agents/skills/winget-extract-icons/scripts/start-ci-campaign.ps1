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

function Get-GitHubRepositorySlug {
    $originUrl = (& git config --get remote.origin.url 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($originUrl)) {
        throw 'Unable to resolve remote.origin.url for workflow dispatch.'
    }

    $trimmed = $originUrl.Trim()
    $match = [regex]::Match($trimmed, 'github\.com[:/](?<owner>[^/]+)/(?<repo>[^/.]+?)(?:\.git)?$')
    if (-not $match.Success) {
        throw ("remote.origin.url is not a GitHub repository URL: {0}" -f $trimmed)
    }

    return ('{0}/{1}' -f $match.Groups['owner'].Value, $match.Groups['repo'].Value)
}

function Invoke-GhCaptured {
    param([Parameter(Mandatory)] [string[]]$Arguments)

    $stdoutPath = Join-Path $env:TEMP ('gh-stdout-{0}.log' -f ([guid]::NewGuid().ToString('N')))
    $stderrPath = Join-Path $env:TEMP ('gh-stderr-{0}.log' -f ([guid]::NewGuid().ToString('N')))
    try {
        $process = Start-Process -FilePath 'gh' -ArgumentList $Arguments -NoNewWindow -Wait -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath

        $stdoutLines = if (Test-Path -LiteralPath $stdoutPath) { @(Get-Content -LiteralPath $stdoutPath -Encoding UTF8) } else { @() }
        $stderrLines = if (Test-Path -LiteralPath $stderrPath) { @(Get-Content -LiteralPath $stderrPath -Encoding UTF8) } else { @() }
        $combinedLines = @($stdoutLines + $stderrLines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut   = $stdoutLines
            StdErr   = $stderrLines
            Output   = ($combinedLines -join "`n")
        }
    }
    finally {
        foreach ($path in @($stdoutPath, $stderrPath)) {
            if (Test-Path -LiteralPath $path) {
                Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            }
        }
    }
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
$repoSlug = Get-GitHubRepositorySlug
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

    $dispatchRequestPath = Join-Path $env:TEMP ('gh-workflow-dispatch-{0}.json' -f ([guid]::NewGuid().ToString('N')))
    try {
        $dispatchRequest = [ordered]@{
            ref    = $Ref
            inputs = [ordered]@{
                campaign_id               = $campaignIdentifier
                campaign_run_label        = $campaignRunLabel
                campaign_gzip_base64      = $planPayload
                uninstall_after           = ([string]$UninstallAfter).ToLowerInvariant()
                per_package_timeout       = [string]$PerPackageTimeout
                auto_commit_results       = ([string]$AutoCommitResults).ToLowerInvariant()
                continue_on_batch_failure = ([string]$ContinueOnBatchFailure.IsPresent).ToLowerInvariant()
            }
        } | ConvertTo-Json -Depth 5 -Compress
        Set-Content -LiteralPath $dispatchRequestPath -Value $dispatchRequest -Encoding UTF8

        $dispatchResult = Invoke-GhCaptured -Arguments @(
            'api'
            ('repos/{0}/actions/workflows/{1}/dispatches' -f $repoSlug, $WorkflowName)
            '--method'
            'POST'
            '--input'
            $dispatchRequestPath
        )

        $dispatchText = $dispatchResult.Output
    }
    finally {
        if (Test-Path -LiteralPath $dispatchRequestPath) {
            Remove-Item -LiteralPath $dispatchRequestPath -Force -ErrorAction SilentlyContinue
        }
    }
    if ($dispatchResult.ExitCode -ne 0) {
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