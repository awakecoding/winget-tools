[CmdletBinding()]
param(
    [ValidateSet('plan', 'run')]
    [string]$Mode = 'plan',

    [string]$CandidatePath,
    [string]$CampaignPath = 'out/icon-campaign-100.json',
    [string]$StatusPath,
    [string]$LockPath,
    [string]$CampaignId,
    [int]$TargetCount = 100,
    [int]$BatchSize = 10,
    [switch]$IncludeExisting,
    [string]$WingetIndexUrl = 'https://github.com/svrooij/winget-pkgs-index/raw/main/index.v2.json',
    [string]$WingetIndexCachePath = 'out/cache/winget-pkgs-index/index.v2.json',
    [switch]$RefreshWingetIndexCache,

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
$PSNativeCommandUseErrorActionPreference = $false
$env:GH_FORCE_TTY = '0'
$env:GH_PAGER = ''
$env:PAGER = ''
$env:GH_PROMPT_DISABLED = '1'

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

function Invoke-GitFastForward {
    param(
        [Parameter(Mandatory)] [string]$BranchName,
        [Parameter(Mandatory)] [string]$ContextLabel
    )

    & git pull --ff-only origin $BranchName
    if ($LASTEXITCODE -ne 0) {
        throw ("git pull --ff-only failed during {0}." -f $ContextLabel)
    }
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

function Get-CandidateIdsFromPackageIndex {
    param([Parameter(Mandatory)] [object]$PackageIndex)

    return @($PackageIndex.Keys | Sort-Object)
}

function Get-WingetIndexPackageMap {
    param(
        [Parameter(Mandatory)] [string]$IndexUrl,
        [Parameter(Mandatory)] [string]$CachePath,
        [Parameter(Mandatory)] [bool]$ForceRefresh
    )

    $cacheDir = Split-Path -Path $CachePath -Parent
    if ($cacheDir) {
        [void](New-Item -ItemType Directory -Path $cacheDir -Force)
    }

    $refreshCache = $ForceRefresh -or -not (Test-Path -LiteralPath $CachePath)
    if (-not $refreshCache) {
        $cacheAge = (Get-Date).ToUniversalTime() - (Get-Item -LiteralPath $CachePath).LastWriteTimeUtc
        $refreshCache = $cacheAge -ge [TimeSpan]::FromHours(4)
    }

    if ($refreshCache) {
        Invoke-WebRequest -Uri $IndexUrl -OutFile $CachePath
    }

    $rawJson = Get-Content -LiteralPath $CachePath -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($rawJson)) {
        throw ("WinGet package index cache is empty: {0}" -f $CachePath)
    }

    $rows = @($rawJson | ConvertFrom-Json)
    if ($rows.Count -eq 0) {
        throw ("WinGet package index cache is empty: {0}" -f $CachePath)
    }

    if ($rows[0] -isnot [psobject]) {
        throw ("WinGet package index cache must contain JSON objects: {0}" -f $CachePath)
    }

    $requiredProperties = @('PackageId', 'Version', 'Name', 'LastUpdate')
    $properties = @($rows[0].PSObject.Properties.Name)
    foreach ($property in $requiredProperties) {
        if ($property -notin $properties) {
            throw ("WinGet package index cache is missing required property '{0}': {1}" -f $property, $CachePath)
        }
    }

    $index = New-Object 'System.Collections.Generic.Dictionary[string, object]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($row in $rows) {
        $packageId = [string]$row.PackageId
        if ([string]::IsNullOrWhiteSpace($packageId)) {
            continue
        }

        $index[$packageId] = [pscustomobject]@{
            PackageId  = $packageId
            Version    = [string]$row.Version
            Name       = [string]$row.Name
            LastUpdate = [string]$row.LastUpdate
        }
    }

    return $index
}

function New-CampaignPlan {
    param(
        [Parameter(Mandatory)] [string]$RepoRoot,
        [string]$CandidateFile,
        [Parameter(Mandatory)] [string]$OutputPath,
        [Parameter(Mandatory)] [string]$CampaignIdentifier,
        [Parameter(Mandatory)] [int]$DesiredCount,
        [Parameter(Mandatory)] [int]$ChunkSize,
        [Parameter(Mandatory)] [bool]$AllowExisting,
        [object]$PackageIndex,
        [string]$PackageIndexUrl,
        [string]$PackageIndexCachePath
    )

    if ($DesiredCount -lt 1) { throw 'TargetCount must be >= 1.' }
    if ($ChunkSize -lt 1) { throw 'BatchSize must be >= 1.' }
    if ($ChunkSize -gt 25) { throw 'BatchSize cannot exceed workflow maximum of 25.' }

    $resolvedCandidatePath = $null
    $candidateSource = $null
    if (-not [string]::IsNullOrWhiteSpace($CandidateFile)) {
        if (-not (Test-Path -LiteralPath $CandidateFile)) {
            throw ("Candidate file not found: {0}" -f $CandidateFile)
        }

        $candidates = @(Get-CandidateIds -Path $CandidateFile)
        $resolvedCandidatePath = (Resolve-Path -LiteralPath $CandidateFile).Path
        $candidateSource = 'file'
    }
    elseif ($null -ne $PackageIndex) {
        $candidates = @(Get-CandidateIdsFromPackageIndex -PackageIndex $PackageIndex)
        $candidateSource = 'svrooij-index-v2'
    }
    else {
        throw 'CandidatePath is required unless the svrooij index is available for automatic candidate selection.'
    }

    $candidates = @($candidates)
    if ($candidates.Count -eq 0) {
        throw 'Candidate selection produced zero package IDs.'
    }

    $existingDirs = @(
        Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'winget-app-icons') -Directory |
            Select-Object -ExpandProperty Name
    )

    $pool = if ($AllowExisting) { $candidates } else { @($candidates | Where-Object { $_ -notin $existingDirs }) }
    $pool = @($pool)
    $validated = New-Object System.Collections.Generic.List[string]
    $failedValidation = New-Object System.Collections.Generic.List[object]

    Write-Host ("Candidates: {0}; Existing excluded: {1}" -f $candidates.Count, ($candidates.Count - $pool.Count))

    foreach ($id in $pool) {
        if ($validated.Count -ge $DesiredCount) { break }

        $indexRecord = $null
        if ($PackageIndex -and $PackageIndex.ContainsKey($id)) {
            $indexRecord = $PackageIndex[$id]
        }

        if ($null -ne $indexRecord) {
            $validated.Add($id)
            Write-Host ("[ok] {0} ({1}/{2})" -f $id, $validated.Count, $DesiredCount)
        }
        else {
            $failedValidation.Add([pscustomobject]@{
                packageId = $id
                exitCode  = $null
                output    = 'Package ID not present in svrooij/winget-pkgs-index index.v2.json.'
            })
            Write-Host ("[skip] {0} (missing from svrooij index)" -f $id)
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
        campaignId           = $CampaignIdentifier
        generatedAtUtc       = (Get-Date).ToUniversalTime().ToString('o')
        candidatePath        = $resolvedCandidatePath
        candidateSource      = $candidateSource
        targetCount          = $DesiredCount
        batchSize            = $ChunkSize
        includeExisting      = $AllowExisting
        validationSource     = 'svrooij-index-v2'
        packageIndexUrl      = $PackageIndexUrl
        packageIndexCachePath = $PackageIndexCachePath
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

function Test-ProcessAlive {
    param([Parameter(Mandatory)] [int]$ProcessId)

    try {
        Get-Process -Id $ProcessId -ErrorAction Stop | Out-Null
        return $true
    }
    catch {
        return $false
    }
}

function Acquire-CampaignLock {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$CampaignIdentifier
    )

    $dir = Split-Path -Path $Path -Parent
    if ($dir) {
        [void](New-Item -ItemType Directory -Path $dir -Force)
    }

    if (Test-Path -LiteralPath $Path) {
        $existing = @{}
        foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction SilentlyContinue)) {
            if ($line -match '^(?<key>[^=]+)=(?<value>.*)$') {
                $existing[$Matches['key']] = $Matches['value']
            }
        }

        $existingPid = 0
        if ($existing.ContainsKey('pid')) {
            [void][int]::TryParse([string]$existing['pid'], [ref]$existingPid)
        }

        if ($existingPid -gt 0 -and (Test-ProcessAlive -ProcessId $existingPid)) {
            throw ("Another icon extraction campaign appears to be active (pid {0}, campaign {1})." -f $existingPid, $existing['campaignId'])
        }

        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    }

    @(
        ("campaignId={0}" -f $CampaignIdentifier)
        ("pid={0}" -f $PID)
        ("startedAtUtc={0}" -f (Get-Date).ToUniversalTime().ToString('o'))
        ("machine={0}" -f $env:COMPUTERNAME)
    ) | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Release-CampaignLock {
    param([Parameter(Mandatory)] [string]$Path)

    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    }
}

function ConvertTo-UtcDateTime {
    param([Parameter(Mandatory)] [string]$Value)

    return [DateTimeOffset]::Parse(
        $Value,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::AssumeUniversal
    ).UtcDateTime
}

function Get-WorkflowRuns {
    param(
        [Parameter(Mandatory)] [string]$Workflow,
        [Parameter(Mandatory)] [string]$Branch
    )

    $lines = @(& gh run list --workflow $Workflow --branch $Branch --event workflow_dispatch --limit 50 --json databaseId,status,conclusion,createdAt,displayTitle --jq '.[] | "\(.databaseId)\t\(.status)\t\(.conclusion)\t\(.createdAt)\t\(.displayTitle)"' 2>$null)
    if ($LASTEXITCODE -ne 0) {
        return @()
    }

    $runs = New-Object System.Collections.Generic.List[object]
    foreach ($line in $lines) {
        $text = $line.ToString().Trim()
        if (-not $text) { continue }

        $parts = $text -split "`t", 5
        if ($parts.Count -lt 5) { continue }
        if ($parts[0] -notmatch '^\d+$') { continue }

        $createdAtUtc = [datetime]::MinValue
        try {
            $createdAtUtc = ConvertTo-UtcDateTime -Value $parts[3]
        }
        catch {
            $createdAtUtc = [datetime]::MinValue
        }

        $runs.Add([pscustomobject]@{
            runId        = [string]$parts[0]
            status       = [string]$parts[1]
            conclusion   = [string]$parts[2]
            createdAt    = [string]$parts[3]
            createdAtUtc = $createdAtUtc
            displayTitle = [string]$parts[4]
        }) | Out-Null
    }

    return @($runs.ToArray())
}

function Get-ActiveWorkflowRuns {
    param(
        [Parameter(Mandatory)] [string]$Workflow,
        [Parameter(Mandatory)] [string]$Branch
    )

    return @(
        Get-WorkflowRuns -Workflow $Workflow -Branch $Branch |
            Where-Object { $_.status -in @('queued', 'pending', 'in_progress') } |
            Sort-Object createdAtUtc, runId
    )
}

function Wait-ForWorkflowIdle {
    param(
        [Parameter(Mandatory)] [string]$Workflow,
        [Parameter(Mandatory)] [string]$Branch,
        [Parameter(Mandatory)] [bool]$PullAfterCompletion,
        [Parameter(Mandatory)] [string]$PullBranch,
        [Parameter(Mandatory)] [string]$ContextLabel
    )

    while ($true) {
        $active = @(Get-ActiveWorkflowRuns -Workflow $Workflow -Branch $Branch)
        if ($active.Count -eq 0) {
            return
        }

        $next = $active | Select-Object -First 1
        Write-Host ("Waiting for existing workflow run {0} [{1}] ({2}) before dispatching another batch." -f $next.runId, $next.status, $next.displayTitle)
        & gh run watch $next.runId --exit-status --compact

        if ($PullAfterCompletion) {
            Invoke-GitFastForward -BranchName $PullBranch -ContextLabel $ContextLabel
        }
    }
}

function New-DispatchToken {
    param(
        [Parameter(Mandatory)] [string]$CampaignIdentifier,
        [Parameter(Mandatory)] [int]$BatchIndex
    )

    return ("{0}-b{1}-{2}" -f $CampaignIdentifier, $BatchIndex, ([guid]::NewGuid().ToString('N').Substring(0, 8)))
}

function New-RequestLabel {
    param(
        [Parameter(Mandatory)] [string]$CampaignIdentifier,
        [Parameter(Mandatory)] [int]$BatchIndex,
        [Parameter(Mandatory)] [int]$BatchTotal,
        [Parameter(Mandatory)] [int]$PackageCount,
        [Parameter(Mandatory)] [string]$DispatchToken
    )

    return ("Extract WinGet icons {0} batch {1}/{2} ({3} packages) {4}" -f $CampaignIdentifier, $BatchIndex, $BatchTotal, $PackageCount, $DispatchToken)
}

function Resolve-RunIdFromDispatchOutput {
    param([Parameter(Mandatory)] [string]$Text)

    if ($Text -match '/runs/(?<runId>\d+)') {
        return [string]$Matches['runId']
    }

    return $null
}

function Resolve-RunIdByToken {
    param(
        [Parameter(Mandatory)] [string]$Workflow,
        [Parameter(Mandatory)] [string]$Branch,
        [Parameter(Mandatory)] [string]$DispatchToken,
        [Parameter(Mandatory)] [datetime]$StartedAtUtc
    )

    $deadline = (Get-Date).ToUniversalTime().AddMinutes(3)
    do {
        $runs = @(Get-WorkflowRuns -Workflow $Workflow -Branch $Branch)

        $tokenMatch = @(
            $runs |
                Where-Object {
                    $_.displayTitle -like ("*{0}*" -f $DispatchToken) -and
                    $_.createdAtUtc -ge $StartedAtUtc.AddSeconds(-30)
                } |
                Sort-Object createdAtUtc -Descending
        )
        if ($tokenMatch.Count -gt 0) {
            return [string]$tokenMatch[0].runId
        }

        $recent = @(
            $runs |
                Where-Object { $_.createdAtUtc -ge $StartedAtUtc.AddSeconds(-15) } |
                Sort-Object createdAtUtc -Descending
        )
        if ($recent.Count -eq 1) {
            return [string]$recent[0].runId
        }

        Start-Sleep -Seconds 3
    }
    while ((Get-Date).ToUniversalTime() -lt $deadline)

    throw ("Could not resolve a workflow run ID for dispatch token {0}." -f $DispatchToken)
}

function Get-RunState {
    param([Parameter(Mandatory)] [string]$RunId)

    $line = (& gh run view $RunId --json status,conclusion --jq '"\(.status)\t\(.conclusion)"' 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $line) {
        return [pscustomobject]@{ status = 'unknown'; conclusion = '' }
    }

    $parts = $line.ToString().Split("`t", 2)
    return [pscustomobject]@{
        status     = if ($parts.Count -ge 1) { [string]$parts[0] } else { 'unknown' }
        conclusion = if ($parts.Count -ge 2) { [string]$parts[1] } else { '' }
    }
}

function Initialize-StatusFile {
    param([Parameter(Mandatory)] [string]$Path)

    $dir = Split-Path -Path $Path -Parent
    if ($dir) {
        [void](New-Item -ItemType Directory -Path $dir -Force)
    }

    'timestampUtc`tcampaignId`tbatchIndex`tbatchTotal`tpackageCount`tdispatchToken	runId	requestLabel	status	conclusion	note' | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Add-StatusRow {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$CampaignIdentifier,
        [Parameter(Mandatory)] [int]$BatchIndex,
        [Parameter(Mandatory)] [int]$BatchTotal,
        [Parameter(Mandatory)] [int]$PackageCount,
        [Parameter(Mandatory)] [string]$DispatchToken,
        [string]$RunId,
        [Parameter(Mandatory)] [string]$RequestLabel,
        [Parameter(Mandatory)] [string]$Status,
        [string]$Conclusion = '',
        [string]$Note = ''
    )

    $safeNote = ($Note -replace "`r?`n", ' | ')
    $row = @(
        (Get-Date).ToUniversalTime().ToString('o')
        $CampaignIdentifier
        [string]$BatchIndex
        [string]$BatchTotal
        [string]$PackageCount
        $DispatchToken
        $RunId
        $RequestLabel
        $Status
        $Conclusion
        $safeNote
    ) -join "`t"

    Add-Content -LiteralPath $Path -Value $row -Encoding UTF8
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

$usePackageIndexCandidates = [string]::IsNullOrWhiteSpace($CandidatePath)
if (-not $usePackageIndexCandidates) {
    $CandidatePath = Resolve-RepoPath -RepoRoot $repoRoot -Path $CandidatePath
}
$CampaignPath = Resolve-RepoPath -RepoRoot $repoRoot -Path $CampaignPath
$WingetIndexCachePath = Resolve-RepoPath -RepoRoot $repoRoot -Path $WingetIndexCachePath
if (-not $StatusPath) {
    $StatusPath = [System.IO.Path]::ChangeExtension($CampaignPath, '.status.tsv')
}
else {
    $StatusPath = Resolve-RepoPath -RepoRoot $repoRoot -Path $StatusPath
}
if (-not $LockPath) {
    $LockPath = Resolve-RepoPath -RepoRoot $repoRoot -Path 'out/icon-extraction-campaign.lock'
}
else {
    $LockPath = Resolve-RepoPath -RepoRoot $repoRoot -Path $LockPath
}
if (-not $CampaignId) {
    $CampaignId = ("icon-campaign-{0}" -f (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss'))
}

if ($AutoCommitResults -and $DownloadAndImportArtifacts) {
    Write-Warning 'DownloadAndImportArtifacts is ignored when AutoCommitResults=true because the workflow already commits refreshed package folders.'
    $DownloadAndImportArtifacts = $false
}

Acquire-CampaignLock -Path $LockPath -CampaignIdentifier $CampaignId
try {
    Invoke-GitFastForward -BranchName $Ref -ContextLabel 'campaign initialization'

    $allowExisting = [bool]$IncludeExisting
    $packageIndex = $null
    $packageIndexUrl = $null
    $packageIndexCachePath = $null
    $packageIndex = Get-WingetIndexPackageMap -IndexUrl $WingetIndexUrl -CachePath $WingetIndexCachePath -ForceRefresh:$RefreshWingetIndexCache
    $packageIndexUrl = $WingetIndexUrl
    $packageIndexCachePath = $WingetIndexCachePath
    Write-Host ("Using svrooij WinGet package index cache: {0}" -f $WingetIndexCachePath)

    $campaign = New-CampaignPlan -RepoRoot $repoRoot -CandidateFile $CandidatePath -OutputPath $CampaignPath -CampaignIdentifier $CampaignId -DesiredCount $TargetCount -ChunkSize $BatchSize -AllowExisting $allowExisting -PackageIndex $packageIndex -PackageIndexUrl $packageIndexUrl -PackageIndexCachePath $packageIndexCachePath
    Write-Host ("Campaign plan written to: {0}" -f $CampaignPath)
    Write-Host ("Validated IDs: {0}; Batches: {1}" -f $campaign.validatedCount, $campaign.batches.Count)

    if ($Mode -eq 'plan') {
        return
    }

    Initialize-StatusFile -Path $StatusPath
    Wait-ForWorkflowIdle -Workflow $WorkflowName -Branch $Ref -PullAfterCompletion:$AutoCommitResults -PullBranch $Ref -ContextLabel 'pre-dispatch idle wait'

    foreach ($batch in $campaign.batches) {
        Write-Host ''
        Write-Host ("=== Batch {0}/{1} ({2} packages) ===" -f $batch.index, $campaign.batches.Count, $batch.packageCnt)

        Wait-ForWorkflowIdle -Workflow $WorkflowName -Branch $Ref -PullAfterCompletion:$AutoCommitResults -PullBranch $Ref -ContextLabel ("batch {0} idle wait" -f $batch.index)

        $dispatchToken = New-DispatchToken -CampaignIdentifier $CampaignId -BatchIndex $batch.index
        $requestLabel = New-RequestLabel -CampaignIdentifier $CampaignId -BatchIndex $batch.index -BatchTotal $campaign.batches.Count -PackageCount $batch.packageCnt -DispatchToken $dispatchToken
        $dispatchStarted = (Get-Date).ToUniversalTime()

        $dispatchOutput = @(
            & gh workflow run $WorkflowName --ref $Ref `
                -f ("package_ids_csv={0}" -f $batch.csv) `
                -f ("uninstall_after={0}" -f ([string]$UninstallAfter).ToLowerInvariant()) `
                -f ("per_package_timeout={0}" -f $PerPackageTimeout) `
                -f ("auto_commit_results={0}" -f ([string]$AutoCommitResults).ToLowerInvariant()) `
                -f ("campaign_id={0}" -f $CampaignId) `
                -f ("batch_index={0}" -f $batch.index) `
                -f ("batch_total={0}" -f $campaign.batches.Count) `
                -f ("dispatch_token={0}" -f $dispatchToken) `
                -f ("request_label={0}" -f $requestLabel) 2>&1
        )
        $dispatchText = ($dispatchOutput | ForEach-Object { $_.ToString() }) -join "`n"
        if ($dispatchText) {
            Write-Host $dispatchText.TrimEnd()
        }

        if ($LASTEXITCODE -ne 0) {
            Add-StatusRow -Path $StatusPath -CampaignIdentifier $CampaignId -BatchIndex $batch.index -BatchTotal $campaign.batches.Count -PackageCount $batch.packageCnt -DispatchToken $dispatchToken -RequestLabel $requestLabel -Status 'dispatch_failed' -Note $dispatchText
            if ($ContinueOnBatchFailure) {
                Write-Warning ("Dispatch failed for batch {0}; continuing." -f $batch.index)
                continue
            }

            throw ("Dispatch failed for batch {0}." -f $batch.index)
        }

        $runId = Resolve-RunIdFromDispatchOutput -Text $dispatchText
        if (-not $runId) {
            $runId = Resolve-RunIdByToken -Workflow $WorkflowName -Branch $Ref -DispatchToken $dispatchToken -StartedAtUtc $dispatchStarted
        }
        Write-Host ("Run ID: {0}" -f $runId)

        & gh run watch $runId --exit-status --compact
        $watchExit = $LASTEXITCODE
        $runState = Get-RunState -RunId $runId
        $status = if ($watchExit -eq 0) { 'success' } else { 'failed' }

        Add-StatusRow -Path $StatusPath -CampaignIdentifier $CampaignId -BatchIndex $batch.index -BatchTotal $campaign.batches.Count -PackageCount $batch.packageCnt -DispatchToken $dispatchToken -RunId $runId -RequestLabel $requestLabel -Status $status -Conclusion $runState.conclusion

        if ($AutoCommitResults) {
            Invoke-GitFastForward -BranchName $Ref -ContextLabel ("post-batch pull for batch {0}" -f $batch.index)
        }

        if ($DownloadAndImportArtifacts) {
            Import-RunArtifactAndCommit -RepoRoot $repoRoot -RunId $runId -Batch $batch -BatchTotal $campaign.batches.Count -PushCommit:$PushAfterCommit.IsPresent
        }

        if ($watchExit -ne 0 -and -not $ContinueOnBatchFailure) {
            throw ("Workflow run {0} failed for batch {1}." -f $runId, $batch.index)
        }
    }
}
finally {
    Release-CampaignLock -Path $LockPath
}
