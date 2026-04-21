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
      Skipped           - blank/comment line in the input file

.PARAMETER Packages
    Inline list of WinGet PackageIds. Mutually exclusive with -PackageListFile.

.PARAMETER PackageListFile
    Path to a text file with one PackageId per line. '#' starts a comment.

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

.PARAMETER PackageStateRoot
    Root directory for the git-backed per-package output layout.
    Each processed package gets a folder at <PackageStateRoot>\<PackageId>\
    containing metadata.json and, when extraction succeeds, app-icon.ico.

.PARAMETER Force
    Forwarded to Get-WinGetIcon.ps1 to overwrite existing .ico files.

.EXAMPLE
    .\scripts\Invoke-BulkIconExtraction.ps1 `
        -PackageListFile .\tests\popular-packages.txt `
        -OutDir .\out\bulk-icons `
        -PackageStateRoot .\winget-app-icons `
        -UninstallAfter

.EXAMPLE
    # Smoke test against a couple of packages without touching install state:
    .\scripts\Invoke-BulkIconExtraction.ps1 `
        -Packages 'Git.Git','Docker.DockerDesktop' `
        -OutDir .\out\smoke
#>

[CmdletBinding(DefaultParameterSetName = 'Inline')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Inline')]
    [string[]] $Packages,

    [Parameter(Mandatory, ParameterSetName = 'File')]
    [string]   $PackageListFile,

    [string] $OutDir,

    [string] $SummaryPath,

    [string] $PackageStateRoot,

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

if (-not $Packages -or $Packages.Count -eq 0) {
    throw 'No packages to process.'
}

# Apply sharding BEFORE any truncation so each shard sees the same slice.
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
        $h = [int64]2166136261
        foreach ($b in $bytes) {
            $h = ((($h -bxor [int64]$b) * 16777619L) % 4294967296L)
        }
        if (($h % $ShardCount) -eq $ShardIndex) {
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

if ($PackageStateRoot) {
    $PackageStateRoot = [IO.Path]::GetFullPath($PackageStateRoot)
    [void](New-Item -ItemType Directory -Path $PackageStateRoot -Force)
}

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

function Invoke-IconExtraction {
    param(
        [Parameter(Mandatory)] [string] $PackageId,
        [Parameter(Mandatory)] [string] $PkgOutDir,
        [ValidateSet('User', 'Machine', 'Both')]
        [string] $Scope = 'Both',
        [switch] $RefreshManifest,
        [switch] $Force
    )

    # Returns @{ Files = FileInfo[]; Error = string }.
    [void](New-Item -ItemType Directory -Path $PkgOutDir -Force)
    $err = ''

    if ($RefreshManifest) {
        try {
            $null = Show-WinGetPackage -PackageId $PackageId -TimeoutSeconds 60
        }
        catch {
            Write-Verbose "Manifest refresh failed for '$PackageId': $($_.Exception.Message)"
        }
    }

    try {
        $null = & $script:iconScript -PackageId $PackageId -OutDir $PkgOutDir -Scope $Scope -Force:$Force 2>&1
    }
    catch {
        $err = Format-ExceptionDetails -ErrorRecord $_
    }
    $files = @(Get-ChildItem -LiteralPath $PkgOutDir -Filter '*.ico' -File -ErrorAction SilentlyContinue)
    return [pscustomobject]@{ Files = $files; Error = $err; Scope = $Scope }
}

function Resolve-WinGetPackageId {
    param([Parameter(Mandatory)] [string] $PackageId)

    if ($script:wingetPackageIdAliases.Contains($PackageId)) {
        return $script:wingetPackageIdAliases[$PackageId]
    }

    return $PackageId
}

function Format-ExceptionDetails {
    param([Parameter(Mandatory)] $ErrorRecord)

    $detailParts = New-Object System.Collections.Generic.List[string]
    $detailParts.Add($ErrorRecord.Exception.Message) | Out-Null
    if ($ErrorRecord.InvocationInfo -and $ErrorRecord.InvocationInfo.ScriptName) {
        $detailParts.Add(("Script={0}:{1}" -f $ErrorRecord.InvocationInfo.ScriptName, $ErrorRecord.InvocationInfo.ScriptLineNumber)) | Out-Null
    }
    if ($ErrorRecord.InvocationInfo -and $ErrorRecord.InvocationInfo.Line) {
        $detailParts.Add(("Line={0}" -f $ErrorRecord.InvocationInfo.Line.Trim())) | Out-Null
    }
    if ($ErrorRecord.ScriptStackTrace) {
        $detailParts.Add(("Stack={0}" -f ($ErrorRecord.ScriptStackTrace -replace "`r?`n", ' | '))) | Out-Null
    }

    return ($detailParts -join '; ')
}

function Get-IconExtractionFailureCategory {
    param([string] $Message)

    if ([string]::IsNullOrWhiteSpace($Message)) { return $null }
    if ($Message -like 'No ARP entries matched*') { return 'ArpNotFound' }
    if ($Message -like 'Could not retrieve manifest*') { return 'ManifestUnavailable' }
    if ($Message -like 'Manifest for *provides neither ProductCode*') { return 'UnsupportedPackage' }
    return 'Other'
}

function Invoke-IconExtractionWithRetry {
    param(
        [Parameter(Mandatory)] [string] $PackageId,
        [Parameter(Mandatory)] [string] $PkgOutDir,
        [switch] $Force,
        [switch] $AfterInstall
    )

    $attemptPlan = @(
        [pscustomobject]@{ Scope = 'Both'; DelaySeconds = 0; RefreshManifest = $false }
    )

    if ($AfterInstall) {
        $attemptPlan += @(
            [pscustomobject]@{ Scope = 'User'; DelaySeconds = 5; RefreshManifest = $true },
            [pscustomobject]@{ Scope = 'Machine'; DelaySeconds = 10; RefreshManifest = $false },
            [pscustomobject]@{ Scope = 'Both'; DelaySeconds = 15; RefreshManifest = $true }
        )
    }

    $attemptRecords = New-Object System.Collections.Generic.List[object]
    $last = $null
    try {
        foreach ($attempt in $attemptPlan) {
            if ($attempt.DelaySeconds -gt 0) {
                Write-Host ("  Waiting {0}s before extraction retry in scope '{1}'..." -f $attempt.DelaySeconds, $attempt.Scope) -ForegroundColor Gray
                Start-Sleep -Seconds $attempt.DelaySeconds
            }

            $result = Invoke-IconExtraction -PackageId $PackageId -PkgOutDir $PkgOutDir -Scope $attempt.Scope -RefreshManifest:$attempt.RefreshManifest -Force:$Force
            $last = $result
            $attemptError = $null
            if ($result.Error) {
                $attemptError = $result.Error
            }
            $attemptFailureCategory = Get-IconExtractionFailureCategory -Message $result.Error
            $attemptRecords.Add([pscustomobject]@{
                scope           = $attempt.Scope
                delaySeconds    = $attempt.DelaySeconds
                refreshManifest = [bool]$attempt.RefreshManifest
                filesFound      = $result.Files.Count
                failureCategory = $attemptFailureCategory
                error           = $attemptError
            }) | Out-Null

            if ($result.Files.Count -gt 0) {
                $successAttempts = @($attemptRecords.ToArray())
                return [pscustomobject]@{
                    Files           = $result.Files
                    Error           = $result.Error
                    Scope           = $result.Scope
                    FailureCategory = $attemptFailureCategory
                    Attempts        = $successAttempts
                }
            }

            if (-not $AfterInstall) {
                break
            }

            if ((Get-IconExtractionFailureCategory -Message $result.Error) -eq 'UnsupportedPackage') {
                break
            }
        }

        $finalFiles = @()
        $finalError = ''
        $finalScope = 'Both'
        $finalFailureCategory = $null
        if ($last) {
            $finalFiles = $last.Files
            $finalError = $last.Error
            $finalScope = $last.Scope
            $finalFailureCategory = Get-IconExtractionFailureCategory -Message $last.Error
        }

        $finalAttempts = @($attemptRecords.ToArray())

        return [pscustomobject]@{
            Files           = $finalFiles
            Error           = $finalError
            Scope           = $finalScope
            FailureCategory = $finalFailureCategory
            Attempts        = $finalAttempts
        }
    }
    catch {
        $caughtError = Format-ExceptionDetails -ErrorRecord $_
        $caughtAttempts = @($attemptRecords.ToArray())
        return [pscustomobject]@{
            Files           = @()
            Error           = $caughtError
            Scope           = 'Both'
            FailureCategory = 'Other'
            Attempts        = $caughtAttempts
        }
    }
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

        $trimmedStdOut = ''
        if ($stdout) {
            $trimmedStdOut = $stdout.Trim()
        }
        $trimmedStdErr = ''
        if ($stderr) {
            $trimmedStdErr = $stderr.Trim()
        }

        return [pscustomobject]@{
            Tag      = $Tag
            ExitCode = $exitCode
            TimedOut = $timedOut
            StdOut   = $trimmedStdOut
            StdErr   = $trimmedStdErr
        }
    }
    finally {
        if ($proc) { $proc.Dispose() }
        Remove-Item -LiteralPath $stdoutFile, $stderrFile -ErrorAction SilentlyContinue
    }
}

$script:wingetSourceErrorNames = [ordered]@{
    '-1978335221' = 'APPINSTALLER_CLI_ERROR_SOURCES_INVALID'
    '-1978335217' = 'APPINSTALLER_CLI_ERROR_SOURCE_DATA_MISSING'
    '-1978335211' = 'APPINSTALLER_CLI_ERROR_NO_SOURCES_DEFINED'
    '-1978335174' = 'APPINSTALLER_CLI_ERROR_RESTAPI_INTERNAL_ERROR'
    '-1978335169' = 'APPINSTALLER_CLI_ERROR_SOURCE_DATA_INTEGRITY_FAILURE'
    '-1978335163' = 'APPINSTALLER_CLI_ERROR_SOURCE_OPEN_FAILED'
    '-1978335157' = 'APPINSTALLER_CLI_ERROR_FAILED_TO_OPEN_ALL_SOURCES'
}

$script:wingetCommunitySourceName = 'winget'

$script:wingetPackageIdAliases = [ordered]@{
    '1Password.1Password'                 = 'AgileBits.1Password'
    'Signal.Signal'                      = 'OpenWhisperSystems.Signal'
    'GoogleCloudSDK.GoogleCloudSDK'      = 'Google.CloudSDK'
    'foobar2000.foobar2000'              = 'PeterPawlowski.foobar2000'
    'ProtonTechnologies.ProtonVPN'       = 'Proton.ProtonVPN'
    'Tracker-Software.PDF-XChangeEditor' = 'TrackerSoftware.PDF-XChangeEditor'
}

$script:wingetUnattendedArgs = @(
    '--accept-source-agreements',
    '--disable-interactivity'
)

$script:wingetInstallUnattendedArgs = @(
    '--accept-package-agreements'
) + $script:wingetUnattendedArgs

function Get-WinGetExitHex {
    param([Parameter(Mandatory)] [int] $ExitCode)

    return ('0x{0:X8}' -f ([uint32]([int64]$ExitCode -band 0xffffffffL)))
}

function Get-WinGetErrorName {
    param([Nullable[int]] $ExitCode)

    if ($null -eq $ExitCode) { return $null }
    $key = [string]$ExitCode
    if ($script:wingetSourceErrorNames.Contains($key)) {
        return $script:wingetSourceErrorNames[$key]
    }

    return $null
}

function Test-WinGetSourceError {
    param([Nullable[int]] $ExitCode)

    if ($null -eq $ExitCode) { return $false }
    return $script:wingetSourceErrorNames.Contains([string]$ExitCode)
}

function New-WinGetAttemptRecord {
    param([Parameter(Mandatory)] $Result)

    $attemptExitHex = $null
    if (-not $Result.TimedOut) {
        $attemptExitHex = Get-WinGetExitHex -ExitCode $Result.ExitCode
    }

    $attemptFailureCategory = 'Install'
    if ($Result.TimedOut) {
        $attemptFailureCategory = 'Timeout'
    }
    elseif (Test-WinGetSourceError -ExitCode $Result.ExitCode) {
        $attemptFailureCategory = 'Source'
    }
    elseif ($Result.ExitCode -eq 0) {
        $attemptFailureCategory = $null
    }

    return [pscustomobject]@{
        tag             = $Result.Tag
        exitCode        = $Result.ExitCode
        exitHex         = $attemptExitHex
        timedOut        = $Result.TimedOut
        errorName       = Get-WinGetErrorName -ExitCode $Result.ExitCode
        failureCategory = $attemptFailureCategory
    }
}

function New-WinGetOutcome {
    param(
        [Parameter(Mandatory)] $Result,
        [Parameter(Mandatory)] [object[]] $Attempts
    )

    $outcomeFailureCategory = 'Install'
    if ($Result.TimedOut) {
        $outcomeFailureCategory = 'Timeout'
    }
    elseif (Test-WinGetSourceError -ExitCode $Result.ExitCode) {
        $outcomeFailureCategory = 'Source'
    }
    elseif ($Result.ExitCode -eq 0) {
        $outcomeFailureCategory = $null
    }

    $outcomeAttempts = @($Attempts)

    return [pscustomobject]@{
        Tag             = $Result.Tag
        ExitCode        = $Result.ExitCode
        TimedOut        = $Result.TimedOut
        StdOut          = $Result.StdOut
        StdErr          = $Result.StdErr
        ExitCodeName    = Get-WinGetErrorName -ExitCode $Result.ExitCode
        FailureCategory = $outcomeFailureCategory
        Attempts        = $outcomeAttempts
    }
}

function Install-WinGetPackage {
    param(
        [Parameter(Mandatory)] [string] $PackageId,
        [Parameter(Mandatory)] [int]    $TimeoutSeconds
    )

    $commonArgs = @(
        'install', '--id', $PackageId, '--exact',
        '--source', $script:wingetCommunitySourceName,
        '--silent'
    )
    $commonArgs += $script:wingetInstallUnattendedArgs

    $attempts = New-Object System.Collections.Generic.List[object]
    $machineArgs = $commonArgs + @('--scope', 'machine')

    # Try the installer's default scope first. User-scoped EXE bootstrappers
    # often fail or hang when forced to machine scope, while extraction already
    # checks both HKCU and HKLM for ARP icons.
    $r = Invoke-WinGetCommand -Arguments $commonArgs `
                              -TimeoutSeconds $TimeoutSeconds `
                              -Tag 'install-default'
    $attempts.Add((New-WinGetAttemptRecord -Result $r)) | Out-Null

    if ($r.TimedOut) { return New-WinGetOutcome -Result $r -Attempts $attempts.ToArray() }
    if ($r.ExitCode -eq 0) { return New-WinGetOutcome -Result $r -Attempts $attempts.ToArray() }

    if (Test-WinGetSourceError -ExitCode $r.ExitCode) {
        $r = Invoke-WinGetCommand -Arguments $commonArgs `
                                  -TimeoutSeconds $TimeoutSeconds `
                                  -Tag 'install-default-retry'
        $attempts.Add((New-WinGetAttemptRecord -Result $r)) | Out-Null

        if ($r.TimedOut) { return New-WinGetOutcome -Result $r -Attempts $attempts.ToArray() }
        if ($r.ExitCode -eq 0) { return New-WinGetOutcome -Result $r -Attempts $attempts.ToArray() }
    }

    # Fall back to machine scope in case the default path chose a user install
    # but the package really needs elevation or explicit machine scope.
    $r2 = Invoke-WinGetCommand -Arguments $machineArgs `
                               -TimeoutSeconds $TimeoutSeconds `
                               -Tag 'install-machine'
    $attempts.Add((New-WinGetAttemptRecord -Result $r2)) | Out-Null

    if ((-not $r2.TimedOut) -and (Test-WinGetSourceError -ExitCode $r2.ExitCode)) {
        $r2 = Invoke-WinGetCommand -Arguments $machineArgs `
                                   -TimeoutSeconds $TimeoutSeconds `
                                   -Tag 'install-machine-retry'
        $attempts.Add((New-WinGetAttemptRecord -Result $r2)) | Out-Null
    }

    return New-WinGetOutcome -Result $r2 -Attempts $attempts.ToArray()
}

function Uninstall-WinGetPackage {
    param(
        [Parameter(Mandatory)] [string] $PackageId,
        [Parameter(Mandatory)] [int]    $TimeoutSeconds
    )

    $uninstallArgs = @(
        'uninstall', '--id', $PackageId, '--exact',
        '--silent'
    )
    $uninstallArgs += $script:wingetUnattendedArgs
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
        '--source', $script:wingetCommunitySourceName
    )
    $showArgs += $script:wingetUnattendedArgs
    return Invoke-WinGetCommand -Arguments $showArgs -TimeoutSeconds $TimeoutSeconds -Tag 'show'
}

function Read-PackageStateMetadata {
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $PackageId
    )

    $pkgStateDir = Get-PackageStateDirPath -Root $Root -PackageId $PackageId
    $metadataPath = Join-Path $pkgStateDir 'metadata.json'
    if (-not (Test-Path -LiteralPath $metadataPath)) {
        return $null
    }

    try {
        return Get-Content -LiteralPath $metadataPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        Write-Warning "Failed to read package metadata at '$metadataPath': $($_.Exception.Message)"
        return $null
    }
}

function Get-EntryField {
    param($Entry, [string] $Field)
    if ($null -eq $Entry) { return $null }
    if ($Entry -is [hashtable]) {
        if ($Entry.ContainsKey($Field)) { return $Entry[$Field] } else { return $null }
    }
    if ($Entry -is [System.Collections.Specialized.OrderedDictionary]) {
        if ($Entry.Contains($Field)) { return $Entry[$Field] } else { return $null }
    }
    if ($Entry.PSObject.Properties[$Field]) { return $Entry.$Field }
    return $null
}

function Get-FileSha256 {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-PackageStateDirPath {
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $PackageId
    )

    $invalidChars = [IO.Path]::GetInvalidFileNameChars()
    if ($PackageId.IndexOfAny($invalidChars) -ge 0 -or $PackageId.EndsWith(' ') -or $PackageId.EndsWith('.')) {
        throw "PackageId '$PackageId' cannot be used as a folder name under '$Root'."
    }

    return Join-Path $Root $PackageId
}

function Write-PackageState {
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $PackageId,
        [Parameter(Mandatory)] $Entry,
        [Parameter(Mandatory)] $Record,
        [Parameter(Mandatory)] [string] $PkgOutDir
    )

    $pkgStateDir = Get-PackageStateDirPath -Root $Root -PackageId $PackageId
    [void](New-Item -ItemType Directory -Path $pkgStateDir -Force)

    $metadataPath = Join-Path $pkgStateDir 'metadata.json'
    $canonicalIconPath = Join-Path $pkgStateDir 'app-icon.ico'
    $currentIcons = @()
    if (Test-Path -LiteralPath $PkgOutDir) {
        $currentIcons = @(
            Get-ChildItem -LiteralPath $PkgOutDir -Filter '*.ico' -File -ErrorAction SilentlyContinue |
                Sort-Object -Property @{ Expression = 'Length'; Descending = $true }, @{ Expression = 'Name'; Descending = $false }
        )
    }

    $canonicalIcon = if ($currentIcons.Count -gt 0) { $currentIcons[0] } else { $null }
    if ($canonicalIcon) {
        Copy-Item -LiteralPath $canonicalIcon.FullName -Destination $canonicalIconPath -Force
    }
    elseif (Test-Path -LiteralPath $canonicalIconPath) {
        Remove-Item -LiteralPath $canonicalIconPath -Force
    }

    $hasIcon = Test-Path -LiteralPath $canonicalIconPath
    $metadata = [ordered]@{
        schema                  = 1
        packageId               = $PackageId
        resolvedPackageId       = if ($Record.ResolvedPackageId -and ($Record.ResolvedPackageId -ne $PackageId)) { $Record.ResolvedPackageId } else { $null }
        status                  = (Get-EntryField -Entry $Entry -Field 'status')
        hasIcon                 = $hasIcon
        firstSeenUtc            = (Get-EntryField -Entry $Entry -Field 'firstSeenUtc')
        lastCheckedUtc          = (Get-EntryField -Entry $Entry -Field 'lastCheckedUtc')
        lastUpdatedUtc          = (Get-EntryField -Entry $Entry -Field 'lastUpdatedUtc')
        wingetVersion           = (Get-EntryField -Entry $Entry -Field 'wingetVersion')
        packageVersion          = (Get-EntryField -Entry $Entry -Field 'packageVersion')
        manifestSha             = (Get-EntryField -Entry $Entry -Field 'manifestSha')
        installerType           = (Get-EntryField -Entry $Entry -Field 'installerType')
        alreadyInstalled        = $Record.AlreadyInstalled
        installedByThisRun      = $Record.InstalledByThisRun
        installSeconds          = $Record.InstallSeconds
        extractSeconds          = $Record.ExtractSeconds
        uninstallSeconds        = $Record.UninstallSeconds
        durationSeconds         = $Record.DurationSeconds
        installExitCode         = $Record.InstallExitCode
        installTimedOut         = $Record.InstallTimedOut
        uninstallExitCode       = $Record.UninstallExitCode
        uninstallTimedOut       = $Record.UninstallTimedOut
        failureCategory         = if ($Record.FailureCategory) { $Record.FailureCategory } else { $null }
        installAttemptTag       = if ($Record.InstallAttemptTag) { $Record.InstallAttemptTag } else { $null }
        extractAttemptCount     = $Record.ExtractAttemptCount
        extractAttemptScopes    = if ($Record.ExtractAttemptScopes.Count -gt 0) { @($Record.ExtractAttemptScopes) } else { $null }
        extractFailureCategory  = if ($Record.ExtractFailureCategory) { $Record.ExtractFailureCategory } else { $null }
        iconCount               = (Get-EntryField -Entry $Entry -Field 'iconCount')
        iconBytes               = (Get-EntryField -Entry $Entry -Field 'iconBytes')
        appIconFile             = if ($hasIcon) { 'app-icon.ico' } else { $null }
        canonicalIconSourceName = if ($canonicalIcon) { $canonicalIcon.Name } else { $null }
        canonicalIconBytes      = if ($canonicalIcon) { $canonicalIcon.Length } else { $null }
        canonicalIconSha256     = if ($hasIcon) { Get-FileSha256 -Path $canonicalIconPath } else { $null }
        extractError            = if ($Record.ExtractError) { $Record.ExtractError } else { $null }
        installStdErr           = if ($Record.InstallStdErr) { $Record.InstallStdErr } else { $null }
        installAttempts         = if ($Record.InstallAttempts.Count -gt 0) { @($Record.InstallAttempts) } else { $null }
        icons                   = (Get-EntryField -Entry $Entry -Field 'icons')
        run                     = [ordered]@{
            startedAtUtc = $Record.StartedAt
            runId        = if ($env:GITHUB_RUN_ID) { $env:GITHUB_RUN_ID } else { $null }
            runAttempt   = if ($env:GITHUB_RUN_ATTEMPT) { $env:GITHUB_RUN_ATTEMPT } else { $null }
            repository   = if ($env:GITHUB_REPOSITORY) { $env:GITHUB_REPOSITORY } else { $null }
        }
    }

    $metadata | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $metadataPath -Encoding UTF8
}

# -----------------------------------------------------------------------------
# Main loop
# -----------------------------------------------------------------------------

$wingetVersion = ''
try {
    $wingetVersion = (& winget --version 2>$null) -replace '[\r\n]', ''
} catch { }

$todo        = New-Object System.Collections.Generic.List[string]

foreach ($pkg in $Packages) {
    $todo.Add($pkg) | Out-Null
}

Write-Host ''
Write-Host "Output dir          : $OutDir"      -ForegroundColor Cyan
Write-Host "Summary file        : $SummaryPath" -ForegroundColor Cyan
if ($ShardCount -gt 1) {
    Write-Host "Shard               : $ShardIndex / $ShardCount" -ForegroundColor Cyan
}
Write-Host "Requested packages  : $($Packages.Count)" -ForegroundColor Cyan
Write-Host "To process this run : $($todo.Count)" -ForegroundColor Cyan
Write-Host "Uninstall after     : $UninstallAfter" -ForegroundColor Cyan
Write-Host "Per-pkg TO          : ${PerPackageTimeoutSeconds}s" -ForegroundColor Cyan
Write-Host "Uninstall TO        : ${UninstallTimeoutSeconds}s" -ForegroundColor Cyan
Write-Host ''

$results = New-Object System.Collections.Generic.List[object]

$idx = 0
$total = $todo.Count

foreach ($pkg in $todo) {
    $idx++
    $started = Get-Date
    Write-Host ('=' * 70)
    Write-Host ("[{0}/{1}] {2}" -f $idx, $total, $pkg) -ForegroundColor Yellow

    $record = [ordered]@{
        PackageId          = $pkg
        ResolvedPackageId  = ''
        Status             = 'Unknown'
        FailureCategory    = ''
        AlreadyInstalled   = $false
        InstallExitCode    = $null
        InstallTimedOut    = $false
        InstallAttemptTag  = ''
        InstallAttempts    = @()
        InstallStdErr      = ''
        InstalledByThisRun = $false
        InstallSeconds     = 0
        ExtractSeconds     = 0
        ExtractAttemptCount = 0
        ExtractAttemptScopes = @()
        ExtractFailureCategory = ''
        IconCount          = 0
        IconBytes          = 0
        IconFiles          = @()
        ExtractError       = ''
        UninstallExitCode  = $null
        UninstallTimedOut  = $false
        UninstallSeconds   = 0
        DurationSeconds    = 0
        StartedAt          = $started.ToUniversalTime().ToString('o')
    }

    $resolvedPackageId = Resolve-WinGetPackageId -PackageId $pkg
    $record.ResolvedPackageId = $resolvedPackageId
    if ($resolvedPackageId -ne $pkg) {
        Write-Host ("  Resolved legacy ID '{0}' -> '{1}'" -f $pkg, $resolvedPackageId) -ForegroundColor DarkGray
    }

    $pkgOutDir = Join-Path $OutDir $pkg

    try {
        # Always warm the manifest FileCache up front so the extractor can read
        # ProductCode / DisplayName / Publisher hints even when the package was
        # preinstalled on the runner.
        Write-Host "  Warming manifest cache (winget show)..." -ForegroundColor Gray
        $null = Show-WinGetPackage -PackageId $resolvedPackageId -TimeoutSeconds 60

        # Probe for an existing icon. Short-circuits for packages already
        # installed locally (e.g. dev box, preinstalled on runner).
        Write-Host "  Probing for existing icon..." -ForegroundColor Gray
        $extStart = Get-Date
        $probe = Invoke-IconExtractionWithRetry -PackageId $resolvedPackageId -PkgOutDir $pkgOutDir -Force:$Force
        $record.ExtractSeconds = [int]((Get-Date) - $extStart).TotalSeconds
        $record.ExtractAttemptCount = @($probe.Attempts).Count
        $record.ExtractAttemptScopes = @($probe.Attempts | ForEach-Object { $_.scope })
        $record.ExtractFailureCategory = if ($probe.FailureCategory) { $probe.FailureCategory } else { '' }

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
            $install = Install-WinGetPackage -PackageId $resolvedPackageId -TimeoutSeconds $PerPackageTimeoutSeconds
            $record.InstallSeconds = [int]((Get-Date) - $instStart).TotalSeconds

            $record.InstallExitCode = $install.ExitCode
            $record.InstallTimedOut = $install.TimedOut
            $record.InstallAttemptTag = $install.Tag
            $record.InstallAttempts = @($install.Attempts)
            $record.FailureCategory = if ($install.FailureCategory) { $install.FailureCategory } else { '' }
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
                $record.FailureCategory = 'Timeout'
            }
            elseif ($install.ExitCode -eq 0) {
                Write-Host ("  Install OK ({0}s)." -f $record.InstallSeconds) -ForegroundColor Green
                $record.Status = 'Installed'
                $record.InstalledByThisRun = $true
                $record.FailureCategory = ''
            }
            elseif ($alreadyInstalledCodes -contains $install.ExitCode) {
                Write-Host "  winget reports already installed." -ForegroundColor Gray
                $record.Status = 'AlreadyInstalled'
                $record.AlreadyInstalled = $true
                $record.FailureCategory = ''
            }
            else {
                $installHex = Get-WinGetExitHex -ExitCode $install.ExitCode
                if (Test-WinGetSourceError -ExitCode $install.ExitCode) {
                    Write-Warning ("  Install FAILED due to WinGet source error ({0}; {1})." -f $installHex, $install.ExitCodeName)
                    $record.FailureCategory = 'Source'
                }
                else {
                    Write-Warning ("  Install FAILED (exit {0})." -f $installHex)
                    if (-not $record.FailureCategory) {
                        $record.FailureCategory = 'Install'
                    }
                }
                $record.Status = 'InstallFailed'
            }

            $shouldVerifyInstallFailure = (
                ($record.Status -eq 'InstallFailed') -and
                (-not $install.TimedOut) -and
                (-not (Test-WinGetSourceError -ExitCode $install.ExitCode)) -and
                (-not $install.StdErr) -and
                (($install.ExitCode -eq -1) -or ($probe.FailureCategory -eq 'ArpNotFound'))
            )

            if ($shouldVerifyInstallFailure) {
                Write-Host "  Verifying whether install registered despite non-zero exit..." -ForegroundColor Gray
            }

            if (($record.Status -in @('Installed', 'AlreadyInstalled')) -or $shouldVerifyInstallFailure) {
                Write-Host "  Extracting icon..." -ForegroundColor Gray
                $extStart = Get-Date
                $ex = Invoke-IconExtractionWithRetry -PackageId $resolvedPackageId -PkgOutDir $pkgOutDir -Force:$Force -AfterInstall
                $record.ExtractSeconds = [int]((Get-Date) - $extStart).TotalSeconds
                $record.ExtractAttemptCount = @($ex.Attempts).Count
                $record.ExtractAttemptScopes = @($ex.Attempts | ForEach-Object { $_.scope })
                $record.ExtractFailureCategory = if ($ex.FailureCategory) { $ex.FailureCategory } else { '' }
                if ($ex.Files.Count -gt 0) {
                    $record.IconCount = $ex.Files.Count
                    $record.IconBytes = ($ex.Files | Measure-Object Length -Sum).Sum
                    $record.IconFiles = @($ex.Files | ForEach-Object { $_.Name })
                    $record.Status = 'IconExtracted'
                    if ($shouldVerifyInstallFailure) {
                        $record.InstalledByThisRun = $true
                        $record.FailureCategory = ''
                    }
                    Write-Host ("  Got {0} file(s), {1} bytes." -f $ex.Files.Count, $record.IconBytes) -ForegroundColor Green
                }
                elseif ($ex.Error -and (-not $shouldVerifyInstallFailure)) {
                    $record.Status = 'ExtractError'
                    if (-not $record.FailureCategory) {
                        $record.FailureCategory = 'Extraction'
                    }
                    $record.ExtractError = ($ex.Error.Substring(0, [Math]::Min(512, $ex.Error.Length)))
                    Write-Warning "  Extractor threw: $($ex.Error)"
                }
                elseif (-not $shouldVerifyInstallFailure) {
                    $record.Status = 'NoIcon'
                    Write-Warning "  Extractor produced no .ico files."
                }
            }
        }

        # Best-effort uninstall (only if WE installed it).
        if ($UninstallAfter -and $record.InstalledByThisRun) {
            Write-Host "  Uninstalling..." -ForegroundColor Gray
            try {
                $uninstallStart = Get-Date
                $uninst = Uninstall-WinGetPackage -PackageId $resolvedPackageId -TimeoutSeconds $UninstallTimeoutSeconds
                $record.UninstallSeconds = [int]((Get-Date) - $uninstallStart).TotalSeconds
                $record.UninstallExitCode = $uninst.ExitCode
                $record.UninstallTimedOut = $uninst.TimedOut
                if ($uninst.TimedOut) {
                    Write-Warning "  Uninstall timed out (continuing)."
                } elseif ($uninst.ExitCode -ne 0) {
                    $uninstallHex = '{0:X8}' -f ([uint32]([int64]$uninst.ExitCode -band 0xffffffffL))
                    Write-Warning ("  Uninstall non-zero exit (0x{0}); continuing." -f $uninstallHex)
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
        if (-not $record.FailureCategory) {
            $record.FailureCategory = 'Extraction'
        }
        $record.ExtractError = Format-ExceptionDetails -ErrorRecord $_
        Write-Warning "  Iteration error: $($record.ExtractError)"
    }
    finally {
        $record.DurationSeconds = [int]((Get-Date) - $started).TotalSeconds
        $results.Add([pscustomobject]$record) | Out-Null

        # Update registry. Keep an iteration-local copy of the previous entry's
        # 'firstSeenUtc' so we don't lose it on refresh.
        $prev = if ($PackageStateRoot) { Read-PackageStateMetadata -Root $PackageStateRoot -PackageId $pkg } else { $null }
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
            packageVersion      = (Get-EntryField -Entry $prev -Field 'packageVersion')
            manifestSha         = (Get-EntryField -Entry $prev -Field 'manifestSha')
            installerType       = (Get-EntryField -Entry $prev -Field 'installerType')
            installSeconds      = $record.InstallSeconds
            extractSeconds      = $record.ExtractSeconds
            uninstallSeconds    = $record.UninstallSeconds
            installExitCode     = $record.InstallExitCode
            uninstallExitCode   = $record.UninstallExitCode
            uninstallTimedOut   = $record.UninstallTimedOut
            installedByThisRun  = $record.InstalledByThisRun
            alreadyInstalled    = $record.AlreadyInstalled
            durationSeconds     = $record.DurationSeconds
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

        if ($PackageStateRoot) {
            try {
                Write-PackageState -Root $PackageStateRoot -PackageId $pkg -Entry $newEntry -Record ([pscustomobject]$record) -PkgOutDir $pkgOutDir
            }
            catch {
                Write-Warning "  Failed to write package state for '$pkg': $($_.Exception.Message)"
            }
        }
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
    WingetVersion = $wingetVersion
    ShardIndex    = $ShardIndex
    ShardCount    = $ShardCount
    Total         = $results.Count
    Unsupported   = 0
    Skipped       = 0
    Processed     = $todo.Count
    StatusCounts  = @{}
    FailureCategoryCounts = @{}
    Results       = $results
}
foreach ($g in $grouped) { $payload.StatusCounts[$g.Name] = $g.Count }
foreach ($g in ($results | Where-Object { $_.FailureCategory } | Group-Object FailureCategory | Sort-Object Name)) {
    $payload.FailureCategoryCounts[$g.Name] = $g.Count
}

$payload | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $SummaryPath -Encoding UTF8
Write-Host "Summary written to: $SummaryPath" -ForegroundColor Cyan

# Emit results on the pipeline so callers can pipe into Format-Table etc.
# Package-level failures are recorded in the results and metadata.json.
# Do not leak the last winget native exit code out as a step failure.
$global:LASTEXITCODE = 0
$results


