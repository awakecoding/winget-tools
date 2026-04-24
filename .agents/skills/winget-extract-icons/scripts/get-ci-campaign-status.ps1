[CmdletBinding(DefaultParameterSetName = 'Campaign')]
param(
    [Parameter(ParameterSetName = 'Campaign', Mandatory)]
    [string]$CampaignId,

    [Parameter(ParameterSetName = 'Run', Mandatory)]
    [string]$RunId,

    [string]$WorkflowName = 'extract-icons-campaign.yml'
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

function Get-WorkflowRun {
    param([Parameter(Mandatory)] [string]$Id)

    $json = Normalize-GhJson -Text (@(& gh run view $Id --json databaseId,status,conclusion,displayTitle,createdAt,updatedAt,url,jobs 2>$null) -join "`n")
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) {
        return $null
    }

    return $json | ConvertFrom-Json -Depth 12
}

function Find-CampaignRun {
    param(
        [Parameter(Mandatory)] [string]$Workflow,
        [Parameter(Mandatory)] [string]$CampaignIdentifier
    )

    $json = Normalize-GhJson -Text (@(& gh run list --workflow $Workflow --limit 30 --json databaseId,status,conclusion,displayTitle,createdAt,updatedAt,url 2>$null) -join "`n")
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) {
        return $null
    }

    return @($json | ConvertFrom-Json | Where-Object {
            [string]$_.displayTitle -like ('*' + $CampaignIdentifier + '*')
        } | Sort-Object createdAt -Descending | Select-Object -First 1)
}

$resolvedRunId = $null
if ($PSCmdlet.ParameterSetName -eq 'Run') {
    $resolvedRunId = $RunId
}
else {
    $match = Find-CampaignRun -Workflow $WorkflowName -CampaignIdentifier $CampaignId
    if (-not $match) {
        throw ("No workflow run found for campaign '{0}'." -f $CampaignId)
    }
    $resolvedRunId = [string]$match.databaseId
}

$run = Get-WorkflowRun -Id $resolvedRunId
if (-not $run) {
    throw ("Unable to read workflow run {0}." -f $resolvedRunId)
}

$batchJobs = @($run.jobs | Where-Object { [string]$_.name -match '^Batch \d+/\d+ \(' })
$statusCounts = [ordered]@{}
foreach ($group in ($batchJobs | Group-Object status | Sort-Object Name)) {
    $statusCounts[$group.Name] = $group.Count
}

$conclusionCounts = [ordered]@{}
foreach ($group in ($batchJobs | Where-Object { -not [string]::IsNullOrWhiteSpace($_.conclusion) } | Group-Object conclusion | Sort-Object Name)) {
    $conclusionCounts[$group.Name] = $group.Count
}

$activeBatches = @($batchJobs | Where-Object { $_.status -ne 'completed' } | Sort-Object startedAt)
$failedBatches = @($batchJobs | Where-Object { $_.conclusion -and $_.conclusion -ne 'success' } | Sort-Object startedAt)

[pscustomobject]@{
    runId             = [string]$run.databaseId
    workflow          = $WorkflowName
    displayTitle      = [string]$run.displayTitle
    status            = [string]$run.status
    conclusion        = [string]$run.conclusion
    createdAt         = [string]$run.createdAt
    updatedAt         = [string]$run.updatedAt
    url               = [string]$run.url
    batchTotal        = $batchJobs.Count
    batchStatusCounts = $statusCounts
    batchConclusions  = $conclusionCounts
    activeBatches     = @($activeBatches | ForEach-Object {
            [ordered]@{
                name       = [string]$_.name
                status     = [string]$_.status
                conclusion = [string]$_.conclusion
                startedAt  = [string]$_.startedAt
                completedAt = [string]$_.completedAt
                url        = [string]$_.url
            }
        })
    failedBatches     = @($failedBatches | ForEach-Object {
            [ordered]@{
                name       = [string]$_.name
                conclusion = [string]$_.conclusion
                startedAt  = [string]$_.startedAt
                completedAt = [string]$_.completedAt
                url        = [string]$_.url
            }
        })
}