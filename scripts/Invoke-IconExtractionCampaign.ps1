[CmdletBinding()]
param(
    [ValidateSet('plan', 'run')]
    [string]$Mode = 'plan',

    [string]$CandidatePath = 'tests/popular-packages.txt',
    [string]$CampaignPath = 'out/icon-campaign-100.json',
    [int]$TargetCount = 100,
    [int]$BatchSize = 10,
    [switch]$IncludeExisting,
    [int]$WingetShowTimeoutSeconds = 30,

    [string]$WorkflowName = 'extract-icons.yml',
    [string]$Ref = 'master',
    [bool]$UninstallAfter = $true,
    [int]$PerPackageTimeout = 900,
    [bool]$AutoCommitResults = $false,
    [switch]$DownloadAndImportArtifacts,
    [switch]$PushAfterCommit,
    [switch]$ContinueOnBatchFailure
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

function Get-CandidateIds {
    param([Parameter(Mandatory)] [string]$Path)

    $ids = New-Object System.Collections.Generic.List[string]
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
        $value = $line.Trim()
        if (-not $value) { continue }
        if ($value.StartsWith('#')) { continue }

        if ($value -match '\s+#') {
            $value = ($value -replace '\s+#.*$', '').Trim()
        }

        if (-not $value) { continue }
        $ids.Add($value)
    }

    return @($ids | Select-Object -Unique)
}

function Test-WingetPackageId {
    param(
        [Parameter(Mandatory)] [string]$PackageId,
        [Parameter(Mandatory)] [int]$TimeoutSeconds
    )

    # TimeoutSeconds is kept for backward compatibility of the interface.
    $null = $TimeoutSeconds

    $raw = @(& winget show --id $PackageId --exact --source winget --disable-interactivity --accept-source-agreements 2>&1)
    $exitCode = $LASTEXITCODE
    $text = (@($raw | ForEach-Object { $_.ToString() }) | Where-Object { $_.Trim() }) -join "`n"

    return [pscustomobject]@{
        packageId = $PackageId
        success   = ($exitCode -eq 0)
        exitCode  = $exitCode
        output    = $text
    }
}

function New-CampaignPlan {
    param(
        [Parameter(Mandatory)] [string]$RepoRoot,
        [Parameter(Mandatory)] [string]$CandidateFile,
        [Parameter(Mandatory)] [string]$OutputPath,
        [Parameter(Mandatory)] [int]$DesiredCount,
        [Parameter(Mandatory)] [int]$ChunkSize,
        [Parameter(Mandatory)] [bool]$AllowExisting,
        [Parameter(Mandatory)] [int]$TimeoutSeconds
    )

    if (-not (Test-Path -LiteralPath $CandidateFile)) {
        throw ("Candidate file not found: {0}" -f $CandidateFile)
    }

    if ($DesiredCount -lt 1) { throw 'TargetCount must be >= 1.' }
    if ($ChunkSize -lt 1) { throw 'BatchSize must be >= 1.' }
    if ($ChunkSize -gt 25) { throw 'BatchSize cannot exceed workflow maximum of 25.' }

    $candidates = @(Get-CandidateIds -Path $CandidateFile)
    $existingDirs = @(
        Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'winget-app-icons') -Directory |
            Select-Object -ExpandProperty Name
    )

    $pool = if ($AllowExisting) { $candidates } else { @($candidates | Where-Object { $_ -notin $existingDirs }) }
    $validated = New-Object System.Collections.Generic.List[string]
    $failedValidation = New-Object System.Collections.Generic.List[object]

    Write-Host ("Candidates: {0}; Existing excluded: {1}" -f $candidates.Count, ($candidates.Count - $pool.Count))

    foreach ($id in $pool) {
        if ($validated.Count -ge $DesiredCount) { break }

        $probe = Test-WingetPackageId -PackageId $id -TimeoutSeconds $TimeoutSeconds
        if ($probe.success) {
            $validated.Add($id)
            Write-Host ("[ok] {0} ({1}/{2})" -f $id, $validated.Count, $DesiredCount)
        }
        else {
            $failedValidation.Add([pscustomobject]@{
                packageId = $id
                exitCode  = $probe.exitCode
                output    = $probe.output
            })
            Write-Host ("[skip] {0} (exit={1})" -f $id, $probe.exitCode)
        }
    }

    if ($validated.Count -lt $DesiredCount) {
        throw ("Unable to collect {0} validated IDs. Collected {1}." -f $DesiredCount, $validated.Count)
    }

    $selected = @($validated | Select-Object -First $DesiredCount)
    $batches = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $selected.Count; $i += $ChunkSize) {
        $end = [int]([Math]::Min($i + $ChunkSize - 1, $selected.Count - 1))
        $batchPackages = @($selected[$i..$end])
        $batches.Add([pscustomobject]@{
            index      = [int]($batches.Count + 1)
            packages   = $batchPackages
            csv        = ($batchPackages -join ',')
            packageCnt = $batchPackages.Count
        })
    }

    $selectedArray = @($selected)
    $batchArray = @($batches.ToArray())
    $failedArray = @($failedValidation.ToArray())

    $plan = [pscustomobject]@{
        generatedAtUtc       = (Get-Date).ToUniversalTime().ToString('o')
        candidatePath        = (Resolve-Path -LiteralPath $CandidateFile).Path
        targetCount          = $DesiredCount
        batchSize            = $ChunkSize
        includeExisting      = $AllowExisting
        sourceCandidateCount = $candidates.Count
        existingExcluded     = ($candidates.Count - $pool.Count)
        validatedCount       = $selectedArray.Count
        failedValidationCnt  = $failedValidation.Count
        packages             = $selectedArray
        batches              = $batchArray
        failedValidation     = $failedArray
    }

    $outDir = Split-Path -Path $OutputPath -Parent
    if ($outDir) {
        [void](New-Item -ItemType Directory -Path $outDir -Force)
    }

    $plan | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
    return $plan
}

function Resolve-LatestRunId {
    param(
        [Parameter(Mandatory)] [string]$Workflow,
        [Parameter(Mandatory)] [string]$Branch,
        [Parameter(Mandatory)] [datetime]$StartedAtUtc
    )

    $deadline = (Get-Date).ToUniversalTime().AddMinutes(3)
    do {
        $json = & gh run list --workflow $Workflow --branch $Branch --event workflow_dispatch --limit 20 --json databaseId,createdAt
        if ($LASTEXITCODE -eq 0 -and $json) {
            $rows = @($json | ConvertFrom-Json)
            $newest = $rows |
                Where-Object {
                    ([datetime]::Parse($_.createdAt).ToUniversalTime()) -ge $StartedAtUtc.AddSeconds(-15)
                } |
                Sort-Object { [datetime]::Parse($_.createdAt).ToUniversalTime() } -Descending |
                Select-Object -First 1

            if ($newest) {
                return [string]$newest.databaseId
            }
        }

        Start-Sleep -Seconds 3
    }
    while ((Get-Date).ToUniversalTime() -lt $deadline)

    throw 'Could not resolve a workflow run ID after dispatch.'
}

function Assert-StagedFilesWithinTargets {
    param([Parameter(Mandatory)] [string[]]$TargetFolders)

    $staged = @(
        & git diff --cached --name-only |
            ForEach-Object { $_.ToString().Trim() } |
            Where-Object { $_ }
    )

    if ($staged.Count -eq 0) {
        return $staged
    }

    $outside = @(
        $staged | Where-Object {
            $path = $_
            -not ($TargetFolders | Where-Object { $path -eq $_ -or $path.StartsWith($_ + '/') } | Select-Object -First 1)
        }
    )

    if ($outside.Count -gt 0) {
        throw ("Staged files outside target folders: {0}" -f ($outside -join ', '))
    }

    return $staged
}

function Import-RunArtifactAndCommit {
    param(
        [Parameter(Mandatory)] [string]$RepoRoot,
        [Parameter(Mandatory)] [string]$RunId,
        [Parameter(Mandatory)] [object]$Batch,
        [Parameter(Mandatory)] [int]$BatchTotal,
        [Parameter(Mandatory)] [bool]$PushCommit
    )

    $artifactName = ("winget-icon-batch-{0}" -f $RunId)
    $downloadDir = Join-Path $env:TEMP ("winget-artifact-{0}" -f $RunId)
    Remove-Item -LiteralPath $downloadDir -Recurse -Force -ErrorAction SilentlyContinue
    [void](New-Item -ItemType Directory -Path $downloadDir -Force)

    & gh run download $RunId --name $artifactName --dir $downloadDir
    if ($LASTEXITCODE -ne 0) {
        throw ("Failed to download artifact {0} for run {1}." -f $artifactName, $RunId)
    }

    $zipPath = Join-Path $downloadDir ("winget-app-icons-batch-{0}.zip" -f $RunId)
    if (-not (Test-Path -LiteralPath $zipPath)) {
        throw ("Expected batch zip not found: {0}" -f $zipPath)
    }

    Expand-Archive -LiteralPath $zipPath -DestinationPath $RepoRoot -Force

    $targetFolders = @($Batch.packages | ForEach-Object { "winget-app-icons/{0}" -f $_ })
    & git add -- $targetFolders
    if ($LASTEXITCODE -ne 0) {
        throw 'git add failed for extracted package folders.'
    }

    $staged = @(Assert-StagedFilesWithinTargets -TargetFolders $targetFolders)
    if ($staged.Count -eq 0) {
        Write-Host ("No changes after importing run {0}; nothing to commit." -f $RunId)
        return
    }

    $message = ("Import icon extraction batch {0}/{1} from run {2}" -f $Batch.index, $BatchTotal, $RunId)
    & git commit -m $message
    if ($LASTEXITCODE -ne 0) {
        throw 'git commit failed after artifact import.'
    }

    if ($PushCommit) {
        & git push origin HEAD:master
        if ($LASTEXITCODE -ne 0) {
            throw 'git push failed after batch commit.'
        }
    }
}

$repoRoot = Get-RepoRoot
Set-Location -LiteralPath $repoRoot

$allowExisting = [bool]$IncludeExisting
$campaign = New-CampaignPlan -RepoRoot $repoRoot -CandidateFile $CandidatePath -OutputPath $CampaignPath -DesiredCount $TargetCount -ChunkSize $BatchSize -AllowExisting $allowExisting -TimeoutSeconds $WingetShowTimeoutSeconds
Write-Host ("Campaign plan written to: {0}" -f $CampaignPath)
Write-Host ("Validated IDs: {0}; Batches: {1}" -f $campaign.validatedCount, $campaign.batches.Count)

if ($Mode -eq 'plan') {
    return
}

foreach ($batch in $campaign.batches) {
    Write-Host ''
    Write-Host ("=== Batch {0}/{1} ({2} packages) ===" -f $batch.index, $campaign.batches.Count, $batch.packageCnt)

    $dispatchStarted = (Get-Date).ToUniversalTime()
    & gh workflow run $WorkflowName --ref $Ref `
        -f ("package_ids_csv={0}" -f $batch.csv) `
        -f ("uninstall_after={0}" -f ([string]$UninstallAfter).ToLowerInvariant()) `
        -f ("per_package_timeout={0}" -f $PerPackageTimeout) `
        -f ("auto_commit_results={0}" -f ([string]$AutoCommitResults).ToLowerInvariant())

    if ($LASTEXITCODE -ne 0) {
        if ($ContinueOnBatchFailure) {
            Write-Warning ("Dispatch failed for batch {0}; continuing." -f $batch.index)
            continue
        }

        throw ("Dispatch failed for batch {0}." -f $batch.index)
    }

    $runId = Resolve-LatestRunId -Workflow $WorkflowName -Branch $Ref -StartedAtUtc $dispatchStarted
    Write-Host ("Run ID: {0}" -f $runId)

    & gh run watch $runId --exit-status --compact
    $watchExit = $LASTEXITCODE
    if ($watchExit -ne 0 -and -not $ContinueOnBatchFailure) {
        throw ("Workflow run {0} failed for batch {1}." -f $runId, $batch.index)
    }

    if ($DownloadAndImportArtifacts) {
        Import-RunArtifactAndCommit -RepoRoot $repoRoot -RunId $runId -Batch $batch -BatchTotal $campaign.batches.Count -PushCommit:$PushAfterCommit.IsPresent
    }
}
