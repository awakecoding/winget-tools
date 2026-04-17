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

.PARAMETER Force
    Forwarded to Get-WinGetIcon.ps1 to overwrite existing .ico files.

.EXAMPLE
    .\scripts\Invoke-BulkIconExtraction.ps1 `
        -PackageListFile .\tests\popular-packages.txt `
        -OutDir .\out\bulk-icons `
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

    [string] $OutDir,

    [string] $SummaryPath,

    [switch] $UninstallAfter,

    [ValidateRange(30, 7200)]
    [int]    $PerPackageTimeoutSeconds = 600,

    [ValidateRange(0, 10000)]
    [int]    $MaxPackages = 0,

    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

# -----------------------------------------------------------------------------
# Main loop
# -----------------------------------------------------------------------------

Write-Host ''
Write-Host "Output dir   : $OutDir"      -ForegroundColor Cyan
Write-Host "Summary file : $SummaryPath" -ForegroundColor Cyan
Write-Host "Packages     : $($Packages.Count)" -ForegroundColor Cyan
Write-Host "Uninstall    : $UninstallAfter" -ForegroundColor Cyan
Write-Host "Per-pkg TO   : ${PerPackageTimeoutSeconds}s" -ForegroundColor Cyan
Write-Host ''

$results = New-Object System.Collections.Generic.List[object]
$idx = 0
$total = $Packages.Count

foreach ($pkg in $Packages) {
    $idx++
    $started = Get-Date
    Write-Host ('=' * 70)
    Write-Host ("[{0}/{1}] {2}" -f $idx, $total, $pkg) -ForegroundColor Yellow

    $record = [ordered]@{
        PackageId        = $pkg
        Status           = 'Unknown'
        AlreadyInstalled = $false
        InstallExitCode  = $null
        InstallTimedOut  = $false
        InstallStdErr    = ''
        InstalledByThisRun = $false
        IconCount        = 0
        IconBytes        = 0
        IconFiles        = @()
        ExtractError     = ''
        UninstallExitCode = $null
        UninstallTimedOut = $false
        DurationSeconds  = 0
        StartedAt        = $started.ToUniversalTime().ToString('o')
    }

    try {
        $pkgOutDir = Join-Path $OutDir $pkg

        # Try extraction first. If the package is already installed AND has a
        # usable ARP icon, this short-circuits the whole install/uninstall
        # dance. Much faster than 'winget list --id' (which forks sources).
        Write-Host "  Probing for existing icon..." -ForegroundColor Gray
        $probe = Invoke-IconExtraction -PackageId $pkg -PkgOutDir $pkgOutDir -Force:$Force

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
            $install = Install-WinGetPackage -PackageId $pkg -TimeoutSeconds $PerPackageTimeoutSeconds

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
                Write-Host "  Install OK." -ForegroundColor Green
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
                $ex = Invoke-IconExtraction -PackageId $pkg -PkgOutDir $pkgOutDir -Force:$Force
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
                $uninst = Uninstall-WinGetPackage -PackageId $pkg -TimeoutSeconds $PerPackageTimeoutSeconds
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
    GeneratedAt = (Get-Date).ToUniversalTime().ToString('o')
    OutDir      = $OutDir
    Total       = $results.Count
    StatusCounts = @{}
    Results     = $results
}
foreach ($g in $grouped) { $payload.StatusCounts[$g.Name] = $g.Count }

$payload | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $SummaryPath -Encoding UTF8
Write-Host "Summary written to: $SummaryPath" -ForegroundColor Cyan

# Emit results on the pipeline so callers can pipe into Format-Table etc.
$results
