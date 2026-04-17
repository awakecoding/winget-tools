<#
.SYNOPSIS
    Bulk-installs WinGet packages, extracts each one's icon, and (optionally)
    uninstalls them again. Designed to run unattended in CI.

.DESCRIPTION
    For every PackageId in the provided list:

      1. Probe for an existing ARP icon via Get-WinGetIcon.ps1. If it yields
         at least one .ico, mark AlreadyInstalled + IconExtracted and skip
         installation entirely. This avoids a slow 'winget list' preflight.
      2. Otherwise: winget install --silent --accept-package-agreements
                                   --accept-source-agreements
                                   --disable-interactivity
         (with a timeout). Falls back to default scope if machine scope fails.
      3. Re-run Get-WinGetIcon.ps1 to capture the icon from the fresh install.
      4. (optional) winget uninstall --silent --accept-source-agreements
                                     --disable-interactivity

    Each step is wrapped in try/catch. One bad package never breaks the loop.

    A summary record per package is emitted on the pipeline AND written to
    -SummaryPath as JSON. Statuses:

      AlreadyInstalled  - winget reported the package is already installed
      Installed         - install completed (exit code 0)
      InstallFailed     - install exited non-zero
      InstallTimeout    - install exceeded -PerPackageTimeoutSeconds
      IconExtracted     - extractor produced at least one .ico file
      NoIcon            - extractor ran but produced 0 files (e.g., MSI with no
                          ProductIcon, or DisplayIcon pointed at a missing file)
      ExtractError      - extractor threw an exception
      Unsupported       - candidate-flagged installer type (msix, portable...)
                          NOT attempted; recorded for skip purposes
      Skipped           - blank/comment line in the input file

.PARAMETER Packages
    Inline list of WinGet PackageIds. Mutually exclusive with -PackageListFile
    and -CandidateFile.

.PARAMETER PackageListFile
    Path to a text file with one PackageId per line. '#' starts a comment.

.PARAMETER CandidateFile
    Path to a JSON file (produced by Update-CandidateList.ps1) with per-package
    metadata (version, installerType, eligible, manifestSha). Enables installer-
    type pre-filter and version-aware refresh.

.PARAMETER ShardIndex
    0-based shard index. Used with -ShardCount to deterministically slice the
    package list (FNV-1a hash mod ShardCount). Default: 0.

.PARAMETER ShardCount
    Total number of shards. 1 = no sharding. Default: 1.

.PARAMETER OutDir
    Root output directory. One subfolder per PackageId.
    Default: .\out\bulk-icons

.PARAMETER SummaryPath
    Where to write the JSON summary. Default: <OutDir>\summary.json

.PARAMETER UninstallAfter
    Run 'winget uninstall' after each successful install. Required in CI to
    avoid filling the runner's disk.

.PARAMETER PerPackageTimeoutSeconds
    Hard timeout (in seconds) for the install step. Default: 600 (10 min).

.PARAMETER MaxPackages
    If > 0, only process the first N PackageIds from the list. Useful for
    smoke tests.

.PARAMETER RegistryPath
    Path to a JSON registry file that records per-package extraction outcomes
    across runs. When supplied, packages whose registry entry is fresh enough
    are skipped entirely (no install/extract). Updated and rewritten at end.

.PARAMETER MaxNew
    Cap on the number of NEW packages processed per run, AFTER skipping cached
    ones. 0 = no cap. Use to spread work across multiple CI runs.

.PARAMETER RefreshAfterDays
    Re-check packages whose status is HasIcon/NoIcon after this many days.
    Default: 30.

.PARAMETER RetryFailedAfterDays
    Re-check packages whose status is InstallFailed/InstallTimeout/ExtractError
    after this many days. Default: 7.

.PARAMETER IgnoreRegistry
    Process every candidate, ignoring registry freshness (registry is still
    updated).

.PARAMETER Force
    Forwarded to Get-WinGetIcon.ps1 to overwrite existing .ico files.

.EXAMPLE
    .\scripts\Invoke-BulkIconExtraction.ps1 `
        -PackageListFile .\tests\popular-packages.txt `
        -OutDir .\out\bulk-icons `
        -RegistryPath .\data\icon-registry.json `
        -MaxNew 100 `
        -UninstallAfter

.EXAMPLE
    # Smoke test against a couple of packages without touching install state:
    .\scripts\Invoke-BulkIconExtraction.ps1 `
        -Packages 'Git.Git','Docker.DockerDesktop' `
        -OutDir .\out\smoke
#>

[CmdletBinding(DefaultParameterSetName = 'List')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Inline')]
    [string[]] $Packages,

    [Parameter(Mandatory, ParameterSetName = 'File')]
    [string]   $PackageListFile,

    [Parameter(Mandatory, ParameterSetName = 'Candidate')]
    [string]   $CandidateFile,

    [string] $OutDir,

    [string] $SummaryPath,

    [string] $RegistryPath,

    [Parameter(HelpMessage = '0-based shard index. Used with -ShardCount to deterministically slice the package list.')]
    [ValidateRange(0, 999)]
    [int]    $ShardIndex = 0,

    [Parameter(HelpMessage = 'Total number of shards. 1 = no sharding.')]
    [ValidateRange(1, 1000)]
    [int]    $ShardCount = 1,

    [switch] $UninstallAfter,

    [ValidateRange(30, 7200)]
    [int]    $PerPackageTimeoutSeconds = 600,

    [ValidateRange(30, 3600)]
    [int]    $UninstallTimeoutSeconds = 180,

    [ValidateRange(0, 100000)]
    [int]    $MaxPackages = 0,

    [Parameter(HelpMessage = 'Cap the number of NEW packages processed per run (after skipping cached ones). 0 = no cap.')]
    [ValidateRange(0, 100000)]
    [int]    $MaxNew = 0,

    [Parameter(HelpMessage = 'Skip packages whose registry entry is HasIcon/NoIcon/Unsupported and was checked within this many days.')]
    [ValidateRange(0, 3650)]
    [int]    $RefreshAfterDays = 30,

    [Parameter(HelpMessage = 'Retry packages whose registry entry is InstallFailed/InstallTimeout/ExtractError after this many days.')]
    [ValidateRange(0, 3650)]
    [int]    $RetryFailedAfterDays = 7,

    [Parameter(HelpMessage = 'Ignore the registry entirely and re-process every candidate.')]
    [switch] $IgnoreRegistry,

    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# pwsh 7.4+ treats non-zero native exit codes as terminating errors when this
# preference is $true (GitHub Actions default). We intentionally check exit
# codes ourselves, so opt out.
$PSNativeCommandUseErrorActionPreference = $false

$repoRoot   = Split-Path -Parent $PSScriptRoot
$iconScript = Join-Path $repoRoot 'scripts\Get-WinGetIcon.ps1'

if (-not (Test-Path -LiteralPath $iconScript)) {
    throw "Get-WinGetIcon.ps1 not found at: $iconScript"
}

# -----------------------------------------------------------------------------
# Resolve inputs
# -----------------------------------------------------------------------------

# $candidateMeta[packageId] = @{ version, installerType, eligible, manifestSha, publisher?, moniker? }
$candidateMeta = @{}

if ($PSCmdlet.ParameterSetName -eq 'File') {
    if (-not (Test-Path -LiteralPath $PackageListFile)) {
        throw "Package list file not found: $PackageListFile"
    }
    $Packages = Get-Content -LiteralPath $PackageListFile |
        ForEach-Object {
            $line = $_.Trim()
            if (-not $line) { return }
            if ($line.StartsWith('#')) { return }
            # Allow '#' trailing comments.
            $hashIdx = $line.IndexOf('#')
            if ($hashIdx -ge 0) { $line = $line.Substring(0, $hashIdx).Trim() }
            if ($line) { $line }
        }
}
elseif ($PSCmdlet.ParameterSetName -eq 'Candidate') {
    if (-not (Test-Path -LiteralPath $CandidateFile)) {
        throw "Candidate file not found: $CandidateFile"
    }
    $candidates = Get-Content -LiteralPath $CandidateFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $candidates -or -not $candidates.entries) {
        throw "Candidate file '$CandidateFile' has no .entries property."
    }
    $pkgList = New-Object System.Collections.Generic.List[string]
    foreach ($c in $candidates.entries) {
        if (-not $c.packageId) { continue }
        $pkgList.Add([string]$c.packageId) | Out-Null
        $meta = @{
            version       = if ($c.PSObject.Properties['version'])       { [string]$c.version }       else { '' }
            installerType = if ($c.PSObject.Properties['installerType']) { [string]$c.installerType } else { '' }
            eligible      = if ($c.PSObject.Properties['eligible'])      { [bool]$c.eligible }        else { $true }
            manifestSha   = if ($c.PSObject.Properties['manifestSha'])   { [string]$c.manifestSha }   else { '' }
        }
        if ($c.PSObject.Properties['publisher'] -and $c.publisher) { $meta['publisher'] = [string]$c.publisher }
        if ($c.PSObject.Properties['moniker']   -and $c.moniker)   { $meta['moniker']   = [string]$c.moniker }
        $candidateMeta[[string]$c.packageId] = $meta
    }
    $Packages = $pkgList.ToArray()
}

if (-not $Packages -or $Packages.Count -eq 0) {
    throw 'No packages to process.'
}

# Apply sharding BEFORE any other truncation so each shard sees the same slice
# regardless of MaxPackages/MaxNew.
if ($ShardCount -gt 1) {
    if ($ShardIndex -ge $ShardCount) {
        throw "ShardIndex ($ShardIndex) must be less than ShardCount ($ShardCount)."
    }
    $sliced = New-Object System.Collections.Generic.List[string]
    foreach ($pkg in $Packages) {
        # Stable, deterministic slice. Use FNV-1a 32-bit on UTF8 bytes (safe
        # across PowerShell versions; .NET's String.GetHashCode is randomized
        # per-process since core).
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($pkg)
        $h = [uint32]2166136261
        foreach ($b in $bytes) {
            $h = [uint32](($h -bxor [uint32]$b) * [uint32]16777619)
        }
        if (($h % [uint32]$ShardCount) -eq [uint32]$ShardIndex) {
            $sliced.Add($pkg) | Out-Null
        }
    }
    Write-Host ("Sharding: index {0}/{1} -> {2} of {3} candidates." -f $ShardIndex, $ShardCount, $sliced.Count, $Packages.Count)
    $Packages = $sliced.ToArray()
}

if ($MaxPackages -gt 0 -and $Packages.Count -gt $MaxPackages) {
    Write-Host "Truncating package list to first $MaxPackages of $($Packages.Count)."
    $Packages = $Packages[0..($MaxPackages - 1)]
}

if (-not $OutDir) {
    $OutDir = Join-Path $repoRoot 'out\bulk-icons'
}
$OutDir = [IO.Path]::GetFullPath($OutDir)
[void](New-Item -ItemType Directory -Path $OutDir -Force)

if (-not $SummaryPath) {
    $SummaryPath = Join-Path $OutDir 'summary.json'
}
$SummaryPath = [IO.Path]::GetFullPath($SummaryPath)

# Resolve sharded registry path: when -RegistryPath points to a directory and
# we're sharding, append shard-NN.json automatically.
if ($RegistryPath) {
    $RegistryPath = [IO.Path]::GetFullPath($RegistryPath)
    $isDir = Test-Path -LiteralPath $RegistryPath -PathType Container
    if ($ShardCount -gt 1 -and ($isDir -or $RegistryPath -notmatch '\.json$')) {
        if (-not (Test-Path -LiteralPath $RegistryPath)) {
            [void](New-Item -ItemType Directory -Path $RegistryPath -Force)
        }
        $RegistryPath = Join-Path $RegistryPath ("shard-{0:D2}.json" -f $ShardIndex)
    }
}

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

function Invoke-IconExtraction {
    param(
        [Parameter(Mandatory)] [string] $PackageId,
        [Parameter(Mandatory)] [string] $PkgOutDir,
        [switch] $Force
    )

    # Returns @{ Files = FileInfo[]; Error = string }.
    [void](New-Item -ItemType Directory -Path $PkgOutDir -Force)
    $err = ''
    try {
        $null = & $script:iconScript -PackageId $PackageId -OutDir $PkgOutDir -Force:$Force 2>&1
    }
    catch {
        $err = $_.Exception.Message
    }
    $files = @(Get-ChildItem -LiteralPath $PkgOutDir -Filter '*.ico' -File -ErrorAction SilentlyContinue)
    return [pscustomobject]@{ Files = $files; Error = $err }
}

function Invoke-WinGetCommand {
    param(
        [Parameter(Mandatory)] [string[]] $Arguments,
        [Parameter(Mandatory)] [int]      $TimeoutSeconds,
        [string] $Tag
    )

    # Run winget with a hard timeout. Returns: @{ ExitCode; TimedOut; StdOut; StdErr }.
    $stdoutFile = [IO.Path]::GetTempFileName()
    $stderrFile = [IO.Path]::GetTempFileName()

    $proc = $null
    $timedOut = $false
    try {
        $proc = Start-Process -FilePath 'winget' -ArgumentList $Arguments `
            -RedirectStandardOutput $stdoutFile `
            -RedirectStandardError  $stderrFile `
            -WindowStyle Hidden -PassThru

        $finished = $proc.WaitForExit([int]([TimeSpan]::FromSeconds($TimeoutSeconds).TotalMilliseconds))

        if (-not $finished) {
            $timedOut = $true
            try { $proc.Kill($true) } catch { }
            $proc.WaitForExit(5000) | Out-Null
        }

        $exitCode = if ($timedOut) { -1 } else { $proc.ExitCode }
        $stdout   = if (Test-Path $stdoutFile) { (Get-Content $stdoutFile -Raw -ErrorAction SilentlyContinue) } else { '' }
        $stderr   = if (Test-Path $stderrFile) { (Get-Content $stderrFile -Raw -ErrorAction SilentlyContinue) } else { '' }

        return [pscustomobject]@{
            Tag      = $Tag
            ExitCode = $exitCode
            TimedOut = $timedOut
            StdOut   = if ($stdout) { $stdout.Trim() } else { '' }
            StdErr   = if ($stderr) { $stderr.Trim() } else { '' }
        }
    }
    finally {
        if ($proc) { $proc.Dispose() }
        Remove-Item -LiteralPath $stdoutFile, $stderrFile -ErrorAction SilentlyContinue
    }
}

function Install-WinGetPackage {
    param(
        [Parameter(Mandatory)] [string] $PackageId,
        [Parameter(Mandatory)] [int]    $TimeoutSeconds
    )

    $commonArgs = @(
        'install', '--id', $PackageId, '--exact',
        '--silent',
        '--accept-package-agreements',
        '--accept-source-agreements',
        '--disable-interactivity'
    )

    # Try machine scope first (more likely to write to ARP HKLM).
    $r = Invoke-WinGetCommand -Arguments ($commonArgs + @('--scope', 'machine')) `
                              -TimeoutSeconds $TimeoutSeconds `
                              -Tag 'install-machine'

    if ($r.TimedOut) { return $r }
    if ($r.ExitCode -eq 0) { return $r }

    # Common fall-back: --scope machine is unsupported (exit 0x8a15010d) for
    # user-scoped installers. Retry without --scope.
    $r2 = Invoke-WinGetCommand -Arguments $commonArgs `
                               -TimeoutSeconds $TimeoutSeconds `
                               -Tag 'install-default'
    return $r2
}

function Uninstall-WinGetPackage {
    param(
        [Parameter(Mandatory)] [string] $PackageId,
        [Parameter(Mandatory)] [int]    $TimeoutSeconds
    )

    $uninstallArgs = @(
        'uninstall', '--id', $PackageId, '--exact',
        '--silent',
        '--accept-source-agreements',
        '--disable-interactivity'
    )
    return Invoke-WinGetCommand -Arguments $uninstallArgs -TimeoutSeconds $TimeoutSeconds -Tag 'uninstall'
}

function Show-WinGetPackage {
    param(
        [Parameter(Mandatory)] [string] $PackageId,
        [int] $TimeoutSeconds = 60
    )

    # `winget show` populates the V2 FileCache (manifest YAML) for the given
    # package even if the package is preinstalled. This lets Get-WinGetIcon's
    # manifest-driven hint extraction succeed for packages we never install.
    $showArgs = @(
        'show', '--id', $PackageId, '--exact',
        '--source', 'winget',
        '--accept-source-agreements',
        '--disable-interactivity'
    )
    return Invoke-WinGetCommand -Arguments $showArgs -TimeoutSeconds $TimeoutSeconds -Tag 'show'
}

# -----------------------------------------------------------------------------
# Registry helpers
# -----------------------------------------------------------------------------

function Read-IconRegistry {
    param([string] $Path)

    $empty = [pscustomobject]@{
        schema      = 1
        description = ''
        generated   = $null
        entries     = @{}   # internal: real Hashtable for easy add/remove under StrictMode
    }
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $empty }
    try {
        $obj = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
        if (-not $obj) { throw 'Registry file is empty.' }
        if (-not $obj.ContainsKey('entries') -or -not $obj['entries']) { $obj['entries'] = @{} }
        return [pscustomobject]@{
            schema      = if ($obj.ContainsKey('schema'))      { $obj['schema'] }      else { 1 }
            description = if ($obj.ContainsKey('description')) { $obj['description'] } else { '' }
            generated   = if ($obj.ContainsKey('generated'))   { $obj['generated'] }   else { $null }
            entries     = [hashtable]$obj['entries']
        }
    }
    catch {
        Write-Warning "Failed to read registry at '$Path': $($_.Exception.Message). Starting fresh."
        return $empty
    }
}

function Write-IconRegistry {
    param(
        [Parameter(Mandatory)] $Registry,
        [Parameter(Mandatory)] [string] $Path
    )

    $Registry.generated = (Get-Date).ToUniversalTime().ToString('o')
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        [void](New-Item -ItemType Directory -Path $dir -Force)
    }

    # Sort entries alphabetically by PackageId for stable diffs.
    $sortedEntries = [ordered]@{}
    foreach ($key in ($Registry.entries.Keys | Sort-Object)) {
        $sortedEntries[$key] = $Registry.entries[$key]
    }

    $payload = [ordered]@{
        schema      = $Registry.schema
        description = $Registry.description
        generated   = $Registry.generated
        entries     = $sortedEntries
    }

    $payload | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-RegistryEntry {
    param($Registry, [string] $PackageId)
    if ($Registry.entries.ContainsKey($PackageId)) { return $Registry.entries[$PackageId] }
    return $null
}

function Set-RegistryEntry {
    param($Registry, [string] $PackageId, $Entry)
    $Registry.entries[$PackageId] = $Entry
}

function Test-EntryFresh {
    param(
        $Entry,
        [hashtable] $CandidateMeta,    # optional: { version, manifestSha, eligible, ... }
        [int] $RefreshAfterDays,
        [int] $RetryFailedAfterDays
    )

    if (-not $Entry) { return $false }
    if ($Entry -isnot [hashtable] -and -not ($Entry.PSObject.Properties['lastCheckedUtc'])) { return $false }

    $checkedRaw = if ($Entry -is [hashtable]) { $Entry['lastCheckedUtc'] } else { $Entry.lastCheckedUtc }
    $statusRaw  = if ($Entry -is [hashtable]) { $Entry['status'] }         else { $Entry.status }
    if (-not $checkedRaw) { return $false }

    $checked = $null
    try { $checked = [datetime]::Parse([string]$checkedRaw) } catch { return $false }
    $age = (Get-Date).ToUniversalTime() - $checked.ToUniversalTime()

    # Version-aware invalidation: if the candidate's version or manifest sha
    # differs from what we last recorded, the entry is stale regardless of age.
    if ($CandidateMeta) {
        $entryVer = Get-EntryField -Entry $Entry -Field 'packageVersion'
        $entrySha = Get-EntryField -Entry $Entry -Field 'manifestSha'
        $candVer  = if ($CandidateMeta.ContainsKey('version'))     { [string]$CandidateMeta['version'] }     else { '' }
        $candSha  = if ($CandidateMeta.ContainsKey('manifestSha')) { [string]$CandidateMeta['manifestSha'] } else { '' }
        if ($candVer -and $entryVer -and ($candVer -ne $entryVer)) { return $false }
        if ($candSha -and $entrySha -and ($candSha -ne $entrySha)) { return $false }
    }

    $terminalGood = @('HasIcon', 'NoIcon', 'Unsupported')
    $terminalBad  = @('InstallFailed', 'InstallTimeout', 'ExtractError')

    if ($statusRaw -in $terminalGood) { return $age.TotalDays -lt $RefreshAfterDays }
    if ($statusRaw -in $terminalBad)  { return $age.TotalDays -lt $RetryFailedAfterDays }
    return $false
}

function Get-EntryField {
    param($Entry, [string] $Field)
    if ($null -eq $Entry) { return $null }
    if ($Entry -is [hashtable]) {
        if ($Entry.ContainsKey($Field)) { return $Entry[$Field] } else { return $null }
    }
    if ($Entry.PSObject.Properties[$Field]) { return $Entry.$Field }
    return $null
}

function Get-FileSha256 {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

# -----------------------------------------------------------------------------
# Main loop
# -----------------------------------------------------------------------------

# Load registry up front (mutated as we go; written at the end).
$registry = Read-IconRegistry -Path $RegistryPath
$wingetVersion = ''
try {
    $wingetVersion = (& winget --version 2>$null) -replace '[\r\n]', ''
} catch { }

$skipped     = New-Object System.Collections.Generic.List[object]
$unsupported = New-Object System.Collections.Generic.List[string]
$todo        = New-Object System.Collections.Generic.List[string]

foreach ($pkg in $Packages) {
    $meta = if ($candidateMeta.ContainsKey($pkg)) { $candidateMeta[$pkg] } else { $null }

    # Pre-filter: candidate-flagged ineligible (msix/msstore/portable/zip/...).
    # Skip install entirely; record Unsupported in the registry so we never
    # retry until the manifest changes (manifestSha-driven).
    if ($meta -and ($meta.ContainsKey('eligible')) -and (-not $meta['eligible'])) {
        $unsupported.Add($pkg) | Out-Null
        continue
    }

    $entry = Get-RegistryEntry -Registry $registry -PackageId $pkg
    if (-not $IgnoreRegistry -and (Test-EntryFresh -Entry $entry -CandidateMeta $meta -RefreshAfterDays $RefreshAfterDays -RetryFailedAfterDays $RetryFailedAfterDays)) {
        $cachedIcons = Get-EntryField -Entry $entry -Field 'icons'
        $iconCount   = if ($cachedIcons) { @($cachedIcons).Count } else { 0 }
        $iconBytes   = if ($cachedIcons) { (@($cachedIcons) | Measure-Object -Property bytes -Sum).Sum } else { 0 }
        $skipped.Add([pscustomobject]@{
            PackageId       = $pkg
            Status          = 'Skipped'
            CachedStatus    = (Get-EntryField -Entry $entry -Field 'status')
            LastCheckedUtc  = (Get-EntryField -Entry $entry -Field 'lastCheckedUtc')
            IconCount       = $iconCount
            IconBytes       = if ($iconBytes) { $iconBytes } else { 0 }
            DurationSeconds = 0
        }) | Out-Null
        continue
    }
    $todo.Add($pkg) | Out-Null
}

# Materialize Unsupported entries into the registry now (cheap, O(unsupported)).
$nowIso = (Get-Date).ToUniversalTime().ToString('o')
foreach ($pkg in $unsupported) {
    $meta = $candidateMeta[$pkg]
    $prev = Get-RegistryEntry -Registry $registry -PackageId $pkg
    $prevFirstSeen = Get-EntryField -Entry $prev -Field 'firstSeenUtc'
    $entry = [ordered]@{
        status         = 'Unsupported'
        firstSeenUtc   = if ($prevFirstSeen) { $prevFirstSeen } else { $nowIso }
        lastCheckedUtc = $nowIso
        lastUpdatedUtc = (Get-EntryField -Entry $prev -Field 'lastUpdatedUtc')
        wingetVersion  = $wingetVersion
        packageVersion = if ($meta.ContainsKey('version'))       { $meta['version'] }       else { $null }
        manifestSha    = if ($meta.ContainsKey('manifestSha'))   { $meta['manifestSha'] }   else { $null }
        installerType  = if ($meta.ContainsKey('installerType')) { $meta['installerType'] } else { $null }
        notes          = "InstallerType pre-filter: $($meta['installerType'])"
        iconCount      = 0
        iconBytes      = 0
        icons          = @()
    }
    Set-RegistryEntry -Registry $registry -PackageId $pkg -Entry $entry
}

if ($MaxNew -gt 0 -and $todo.Count -gt $MaxNew) {
    Write-Host "Capping new packages this run to $MaxNew (of $($todo.Count) eligible)."
    $todo = [System.Collections.Generic.List[string]]@($todo[0..($MaxNew - 1)])
}

Write-Host ''
Write-Host "Output dir          : $OutDir"      -ForegroundColor Cyan
Write-Host "Summary file        : $SummaryPath" -ForegroundColor Cyan
if ($RegistryPath) {
    Write-Host "Registry file       : $RegistryPath" -ForegroundColor Cyan
}
if ($ShardCount -gt 1) {
    Write-Host "Shard               : $ShardIndex / $ShardCount" -ForegroundColor Cyan
}
Write-Host "Candidates          : $($Packages.Count + $unsupported.Count)" -ForegroundColor Cyan
Write-Host "Unsupported (filter): $($unsupported.Count)" -ForegroundColor Cyan
Write-Host "Skipped (cached)    : $($skipped.Count)" -ForegroundColor Cyan
Write-Host "To process this run : $($todo.Count)" -ForegroundColor Cyan
Write-Host "Uninstall after     : $UninstallAfter" -ForegroundColor Cyan
Write-Host "Per-pkg TO          : ${PerPackageTimeoutSeconds}s" -ForegroundColor Cyan
Write-Host "Uninstall TO        : ${UninstallTimeoutSeconds}s" -ForegroundColor Cyan
Write-Host "Refresh after       : ${RefreshAfterDays}d (HasIcon/NoIcon/Unsupported)" -ForegroundColor Cyan
Write-Host "Retry failed after  : ${RetryFailedAfterDays}d (Install*/Extract*)" -ForegroundColor Cyan
Write-Host ''

$results = New-Object System.Collections.Generic.List[object]
foreach ($s in $skipped) { $results.Add($s) | Out-Null }

$idx = 0
$total = $todo.Count

foreach ($pkg in $todo) {
    $idx++
    $started = Get-Date
    Write-Host ('=' * 70)
    Write-Host ("[{0}/{1}] {2}" -f $idx, $total, $pkg) -ForegroundColor Yellow

    $record = [ordered]@{
        PackageId          = $pkg
        Status             = 'Unknown'
        AlreadyInstalled   = $false
        InstallExitCode    = $null
        InstallTimedOut    = $false
        InstallStdErr      = ''
        InstalledByThisRun = $false
        InstallSeconds     = 0
        ExtractSeconds     = 0
        IconCount          = 0
        IconBytes          = 0
        IconFiles          = @()
        ExtractError       = ''
        UninstallExitCode  = $null
        UninstallTimedOut  = $false
        DurationSeconds    = 0
        StartedAt          = $started.ToUniversalTime().ToString('o')
    }

    try {
        $pkgOutDir = Join-Path $OutDir $pkg

        # Always warm the manifest FileCache up front so the extractor can read
        # ProductCode / DisplayName / Publisher hints even when the package was
        # preinstalled on the runner.
        Write-Host "  Warming manifest cache (winget show)..." -ForegroundColor Gray
        $null = Show-WinGetPackage -PackageId $pkg -TimeoutSeconds 60

        # Probe for an existing icon. Short-circuits for packages already
        # installed locally (e.g. dev box, preinstalled on runner).
        Write-Host "  Probing for existing icon..." -ForegroundColor Gray
        $extStart = Get-Date
        $probe = Invoke-IconExtraction -PackageId $pkg -PkgOutDir $pkgOutDir -Force:$Force
        $record.ExtractSeconds = [int]((Get-Date) - $extStart).TotalSeconds

        if ($probe.Files.Count -gt 0) {
            $record.AlreadyInstalled = $true
            $record.Status    = 'IconExtracted'
            $record.IconCount = $probe.Files.Count
            $record.IconBytes = ($probe.Files | Measure-Object Length -Sum).Sum
            $record.IconFiles = @($probe.Files | ForEach-Object { $_.Name })
            Write-Host ("  Already installed; got {0} file(s), {1} bytes." -f $probe.Files.Count, $record.IconBytes) -ForegroundColor Green
        }
        else {
            Write-Host "  Not installed (or no ARP icon yet); installing..." -ForegroundColor Gray
            $instStart = Get-Date
            $install = Install-WinGetPackage -PackageId $pkg -TimeoutSeconds $PerPackageTimeoutSeconds
            $record.InstallSeconds = [int]((Get-Date) - $instStart).TotalSeconds

            $record.InstallExitCode = $install.ExitCode
            $record.InstallTimedOut = $install.TimedOut
            if ($install.StdErr) {
                $record.InstallStdErr = ($install.StdErr.Substring(0, [Math]::Min(512, $install.StdErr.Length)))
            }

            # Treat "already installed" / "no applicable update" as success.
            $alreadyInstalledCodes = @(
                [int]0x8A15002B   # APPINSTALLER_CLI_ERROR_UPDATE_NOT_APPLICABLE
                [int]0x8A15010B   # APPINSTALLER_CLI_ERROR_PACKAGE_ALREADY_INSTALLED
            )

            if ($install.TimedOut) {
                Write-Warning "  Install TIMED OUT after ${PerPackageTimeoutSeconds}s."
                $record.Status = 'InstallTimeout'
            }
            elseif ($install.ExitCode -eq 0) {
                Write-Host ("  Install OK ({0}s)." -f $record.InstallSeconds) -ForegroundColor Green
                $record.Status = 'Installed'
                $record.InstalledByThisRun = $true
            }
            elseif ($alreadyInstalledCodes -contains $install.ExitCode) {
                Write-Host "  winget reports already installed." -ForegroundColor Gray
                $record.Status = 'AlreadyInstalled'
                $record.AlreadyInstalled = $true
            }
            else {
                Write-Warning ("  Install FAILED (exit 0x{0:X8})." -f ([uint32]$install.ExitCode))
                $record.Status = 'InstallFailed'
            }

            if ($record.Status -in @('Installed', 'AlreadyInstalled')) {
                Write-Host "  Extracting icon..." -ForegroundColor Gray
                $extStart = Get-Date
                $ex = Invoke-IconExtraction -PackageId $pkg -PkgOutDir $pkgOutDir -Force:$Force
                $record.ExtractSeconds = [int]((Get-Date) - $extStart).TotalSeconds
                if ($ex.Files.Count -gt 0) {
                    $record.IconCount = $ex.Files.Count
                    $record.IconBytes = ($ex.Files | Measure-Object Length -Sum).Sum
                    $record.IconFiles = @($ex.Files | ForEach-Object { $_.Name })
                    $record.Status = 'IconExtracted'
                    Write-Host ("  Got {0} file(s), {1} bytes." -f $ex.Files.Count, $record.IconBytes) -ForegroundColor Green
                }
                elseif ($ex.Error) {
                    $record.Status = 'ExtractError'
                    $record.ExtractError = ($ex.Error.Substring(0, [Math]::Min(512, $ex.Error.Length)))
                    Write-Warning "  Extractor threw: $($ex.Error)"
                }
                else {
                    $record.Status = 'NoIcon'
                    Write-Warning "  Extractor produced no .ico files."
                }
            }
        }

        # Best-effort uninstall (only if WE installed it).
        if ($UninstallAfter -and $record.InstalledByThisRun) {
            Write-Host "  Uninstalling..." -ForegroundColor Gray
            try {
                $uninst = Uninstall-WinGetPackage -PackageId $pkg -TimeoutSeconds $UninstallTimeoutSeconds
                $record.UninstallExitCode = $uninst.ExitCode
                $record.UninstallTimedOut = $uninst.TimedOut
                if ($uninst.TimedOut) {
                    Write-Warning "  Uninstall timed out (continuing)."
                } elseif ($uninst.ExitCode -ne 0) {
                    Write-Warning ("  Uninstall non-zero exit (0x{0:X8}); continuing." -f ([uint32]$uninst.ExitCode))
                } else {
                    Write-Host "  Uninstall OK." -ForegroundColor Gray
                }
            }
            catch {
                Write-Warning "  Uninstall threw (continuing): $($_.Exception.Message)"
            }
        }
    }
    catch {
        $record.Status = 'ExtractError'
        $record.ExtractError = $_.Exception.Message
        Write-Warning "  Iteration error: $($_.Exception.Message)"
    }
    finally {
        $record.DurationSeconds = [int]((Get-Date) - $started).TotalSeconds
        $results.Add([pscustomobject]$record) | Out-Null

        # Update registry. Keep an iteration-local copy of the previous entry's
        # 'firstSeenUtc' so we don't lose it on refresh.
        $prev = Get-RegistryEntry -Registry $registry -PackageId $pkg
        $prevFirstSeen     = Get-EntryField -Entry $prev -Field 'firstSeenUtc'
        $prevLastUpdated   = Get-EntryField -Entry $prev -Field 'lastUpdatedUtc'
        $firstSeen = if ($prevFirstSeen) { $prevFirstSeen } else { $record.StartedAt }

        # Map orchestrator status -> persistent status.
        $persistStatus = switch ($record.Status) {
            'IconExtracted'     { 'HasIcon' }
            'NoIcon'            { 'NoIcon' }
            'InstallFailed'     { 'InstallFailed' }
            'InstallTimeout'    { 'InstallTimeout' }
            'ExtractError'      { 'ExtractError' }
            default             { $record.Status }
        }

        $iconRecords = @()
        foreach ($f in $record.IconFiles) {
            $full = Join-Path $pkgOutDir $f
            if (Test-Path -LiteralPath $full) {
                $iconRecords += [pscustomobject]@{
                    name   = $f
                    bytes  = (Get-Item -LiteralPath $full).Length
                    sha256 = Get-FileSha256 -Path $full
                }
            }
        }

        $newEntry = [ordered]@{
            status              = $persistStatus
            firstSeenUtc        = $firstSeen
            lastCheckedUtc      = $record.StartedAt
            lastUpdatedUtc      = if ($persistStatus -eq 'HasIcon') { $record.StartedAt } else { $null }
            wingetVersion       = $wingetVersion
            packageVersion      = if ($candidateMeta.ContainsKey($pkg) -and $candidateMeta[$pkg].ContainsKey('version'))     { $candidateMeta[$pkg]['version'] }     else { (Get-EntryField -Entry $prev -Field 'packageVersion') }
            manifestSha         = if ($candidateMeta.ContainsKey($pkg) -and $candidateMeta[$pkg].ContainsKey('manifestSha')) { $candidateMeta[$pkg]['manifestSha'] } else { (Get-EntryField -Entry $prev -Field 'manifestSha') }
            installerType       = if ($candidateMeta.ContainsKey($pkg) -and $candidateMeta[$pkg].ContainsKey('installerType')) { $candidateMeta[$pkg]['installerType'] } else { (Get-EntryField -Entry $prev -Field 'installerType') }
            installSeconds      = $record.InstallSeconds
            extractSeconds      = $record.ExtractSeconds
            installExitCode     = $record.InstallExitCode
            installedByThisRun  = $record.InstalledByThisRun
            alreadyInstalled    = $record.AlreadyInstalled
            iconCount           = $record.IconCount
            iconBytes           = $record.IconBytes
            icons               = $iconRecords
            extractError        = if ($record.ExtractError) { $record.ExtractError } else { $null }
            installStdErr       = if ($record.InstallStdErr) { $record.InstallStdErr } else { $null }
        }

        # Preserve lastUpdatedUtc from previous entry when this run didn't
        # produce a HasIcon (e.g., transient failure shouldn't erase history).
        if ($persistStatus -ne 'HasIcon' -and $prevLastUpdated) {
            $newEntry['lastUpdatedUtc'] = $prevLastUpdated
        }

        Set-RegistryEntry -Registry $registry -PackageId $pkg -Entry $newEntry
    }
}

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------

$grouped = $results | Group-Object Status | Sort-Object Count -Descending

Write-Host ''
Write-Host ('=' * 70)
Write-Host 'Summary' -ForegroundColor Cyan
Write-Host ('=' * 70)
$grouped | ForEach-Object {
    Write-Host ("  {0,-18} {1,4}" -f $_.Name, $_.Count)
}
Write-Host ''

$payload = [ordered]@{
    GeneratedAt   = (Get-Date).ToUniversalTime().ToString('o')
    OutDir        = $OutDir
    RegistryPath  = $RegistryPath
    WingetVersion = $wingetVersion
    ShardIndex    = $ShardIndex
    ShardCount    = $ShardCount
    Total         = $results.Count
    Unsupported   = $unsupported.Count
    Skipped       = $skipped.Count
    Processed     = $todo.Count
    StatusCounts  = @{}
    Results       = $results
}
foreach ($g in $grouped) { $payload.StatusCounts[$g.Name] = $g.Count }

$payload | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $SummaryPath -Encoding UTF8
Write-Host "Summary written to: $SummaryPath" -ForegroundColor Cyan

if ($RegistryPath) {
    Write-IconRegistry -Registry $registry -Path $RegistryPath
    Write-Host "Registry written to: $RegistryPath" -ForegroundColor Cyan
}

# Emit results on the pipeline so callers can pipe into Format-Table etc.
$results


