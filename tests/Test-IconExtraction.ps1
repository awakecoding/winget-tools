<#
.SYNOPSIS
    Extracts icons for a predefined list of WinGet packages into a structured
    output directory, one folder per PackageId.

.DESCRIPTION
    Calls scripts/Get-WinGetIcon.ps1 in a loop and lays out the result as:

        <OutDir>/
            Git.Git/
                Git.Git_is1.ico
            Docker.DockerDesktop/
                Docker Desktop.Docker Desktop.ico
            ...

    A summary table is printed at the end with one row per package
    (Status / Files / TotalBytes / Notes).

.PARAMETER OutDir
    Root output directory. Default: ./out/icons (relative to repo root).

.PARAMETER Packages
    Override the built-in package list.

.PARAMETER Force
    Forwarded to Get-WinGetIcon.ps1 to overwrite existing files.

.EXAMPLE
    .\tests\Test-IconExtraction.ps1

.EXAMPLE
    .\tests\Test-IconExtraction.ps1 -OutDir .\artifacts -Force
#>

[CmdletBinding()]
param(
    [string]   $OutDir,
    [string[]] $Packages,
    [switch]   $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot   = Split-Path -Parent $PSScriptRoot
$iconScript = Join-Path $repoRoot 'scripts\Get-WinGetIcon.ps1'

if (-not (Test-Path -LiteralPath $iconScript)) {
    throw "Get-WinGetIcon.ps1 not found at: $iconScript"
}

if (-not $OutDir) {
    $OutDir = Join-Path $repoRoot 'out\icons'
}
$OutDir = [IO.Path]::GetFullPath($OutDir)

if (-not $Packages -or $Packages.Count -eq 0) {
    # Default test set: mix of installer types likely to be installed on a dev box.
    # Adjust freely; missing packages are reported as 'NotInstalled' rather than failing.
    $Packages = @(
        'Git.Git'                  # Inno Setup .exe -> DisplayIcon = .ico file
        'Docker.DockerDesktop'     # .exe DisplayIcon -> RT_GROUP_ICON path
        'Microsoft.PowerShell'     # MSI -> MsiGetProductInfoW(ProductIcon)
        'SweetScape.010Editor'     # .exe DisplayIcon
        'MHNexus.HxD'              # .exe DisplayIcon
        'MoritzBunkus.MKVToolNix'  # .exe DisplayIcon
    )
}

Write-Host ""
Write-Host "Output dir : $OutDir" -ForegroundColor Cyan
Write-Host "Packages   : $($Packages.Count)" -ForegroundColor Cyan
Write-Host ""

[void](New-Item -ItemType Directory -Path $OutDir -Force)

$summary = New-Object System.Collections.Generic.List[object]

foreach ($pkg in $Packages) {
    Write-Host ("=" * 70)
    Write-Host " $pkg" -ForegroundColor Yellow
    Write-Host ("=" * 70)

    $pkgDir = Join-Path $OutDir $pkg
    [void](New-Item -ItemType Directory -Path $pkgDir -Force)

    $status = 'OK'
    $notes  = ''
    $results = @()

    try {
        $params = @{
            PackageId = $pkg
            OutDir    = $pkgDir
        }
        if ($Force) { $params['Force'] = $true }

        # Suppress non-terminating warnings into the notes column instead of the host.
        $warnings = @()
        $results = & $iconScript @params -WarningVariable warnings -WarningAction SilentlyContinue
        if ($warnings) {
            $notes = ($warnings | ForEach-Object { $_.ToString() }) -join ' | '
        }
        if (-not $results -or @($results).Count -eq 0) {
            $status = 'NoOutput'
            if (-not $notes) { $notes = 'Script returned no objects.' }
        }
    }
    catch {
        $msg = $_.Exception.Message
        if ($msg -match 'No ARP entries matched') {
            $status = 'NotInstalled'
        } elseif ($msg -match 'neither ProductCode nor') {
            $status = 'Unsupported'
        } else {
            $status = 'Error'
        }
        $notes = $msg
    }

    $files = @(Get-ChildItem -LiteralPath $pkgDir -Filter *.ico -ErrorAction SilentlyContinue)
    $totalBytes = 0
    if ($files.Count -gt 0) { $totalBytes = ($files | Measure-Object Length -Sum).Sum }

    $row = [pscustomobject]@{
        PackageId  = $pkg
        Status     = $status
        Files      = $files.Count
        TotalBytes = $totalBytes
        OutputDir  = $pkgDir
        Notes      = $notes
    }
    $summary.Add($row) | Out-Null

    if ($files.Count -gt 0) {
        foreach ($f in $files) {
            $b = [IO.File]::ReadAllBytes($f.FullName)
            $magic = if ($b.Length -ge 4) {
                ($b[0..3] | ForEach-Object { $_.ToString('X2') }) -join ' '
            } else { '<short>' }
            $valid = if ($magic -eq '00 00 01 00') { 'OK' } else { 'BAD' }
            Write-Host ("  {0,-3} {1,10:N0}  {2}  {3}" -f $valid, $f.Length, $magic, $f.Name)
        }
    } else {
        Write-Host ("  [{0}] {1}" -f $status, $notes) -ForegroundColor DarkYellow
    }
    Write-Host ""
}

Write-Host ("=" * 70)
Write-Host " Summary" -ForegroundColor Cyan
Write-Host ("=" * 70)
$summary | Format-Table PackageId, Status, Files, TotalBytes, Notes -AutoSize -Wrap

# Emit objects on the pipeline too, so callers can pipe / assert.
$summary
