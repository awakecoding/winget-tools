<#
.SYNOPSIS
    Sparse-clones microsoft/winget-pkgs and walks every package's installer
    manifest to build a candidate list with eligibility metadata.

.DESCRIPTION
    For every PackageIdentifier in winget-pkgs/manifests, picks the highest
    semantically-versioned folder, parses the *.installer.yaml file, and
    records:

      packageId, version, installerType (deduped union across architectures),
      eligible (true unless every installer uses a denied type), publisher,
      moniker, manifestSha (sha256 of the installer YAML).

    Denied installer types are skipped at the orchestrator level so we never
    attempt installs that the icon extractor cannot meaningfully process:
        msix, msstore, portable, zip, appx, burn-msu

    Output: data/candidates.json
        {
          schema: 1,
          generated: "<ISO-UTC>",
          source:    "microsoft/winget-pkgs@<sha>",
          count:     <n>,
          eligibleCount: <n>,
          entries: [
            { packageId, version, installerType, eligible,
              publisher?, moniker?, manifestSha }
          ]
        }

.PARAMETER OutputPath
    Where to write candidates.json. Default: ./data/candidates.json

.PARAMETER WorkDir
    Where to clone winget-pkgs. Default: temp dir; cleaned up on success.

.PARAMETER KeepClone
    Skip cleanup of -WorkDir. Useful for local debugging.

.PARAMETER MaxPackages
    Cap candidates emitted. 0 = no cap. Useful for smoke tests.

.PARAMETER Repository
    The winget-pkgs source repo. Default: microsoft/winget-pkgs.

.EXAMPLE
    pwsh ./scripts/Update-CandidateList.ps1 -OutputPath ./data/candidates.json

.EXAMPLE
    # Quick smoke
    pwsh ./scripts/Update-CandidateList.ps1 -OutputPath ./out/candidates.json -MaxPackages 100 -KeepClone
#>

[CmdletBinding()]
param(
    [string] $OutputPath,
    [string] $WorkDir,
    [switch] $KeepClone,
    [ValidateRange(0, 100000)]
    [int]    $MaxPackages = 0,
    [string] $Repository = 'microsoft/winget-pkgs'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutputPath) {
    $OutputPath = Join-Path $repoRoot 'data\candidates.json'
}
$OutputPath = [IO.Path]::GetFullPath($OutputPath)

# -----------------------------------------------------------------------------
# Yayaml dependency
# -----------------------------------------------------------------------------

if (-not (Get-Module -ListAvailable -Name Yayaml)) {
    Write-Host "Installing Yayaml module..."
    Install-Module -Name Yayaml -Scope CurrentUser -Force -AcceptLicense -Repository PSGallery
}
Import-Module Yayaml -ErrorAction Stop

# -----------------------------------------------------------------------------
# Sparse-clone winget-pkgs (manifests/ only, no blobs we don't need)
# -----------------------------------------------------------------------------

$cleanupClone = $false
if (-not $WorkDir) {
    $WorkDir = Join-Path ([IO.Path]::GetTempPath()) ("winget-pkgs-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    $cleanupClone = -not $KeepClone
}
$WorkDir = [IO.Path]::GetFullPath($WorkDir)

$cloneRoot = Join-Path $WorkDir 'winget-pkgs'
$manifestsRoot = Join-Path $cloneRoot 'manifests'

if (Test-Path -LiteralPath $manifestsRoot) {
    Write-Host "Reusing existing clone at $cloneRoot"
    Push-Location $cloneRoot
    try {
        & git fetch --depth 1 origin master 2>&1 | Out-Null
        & git reset --hard FETCH_HEAD 2>&1 | Out-Null
    }
    finally { Pop-Location }
}
else {
    Write-Host "Sparse-cloning $Repository into $cloneRoot..."
    [void](New-Item -ItemType Directory -Path $WorkDir -Force)

    & git clone --filter=blob:none --no-checkout --depth 1 "https://github.com/$Repository.git" $cloneRoot
    if ($LASTEXITCODE -ne 0) { throw "git clone failed (exit $LASTEXITCODE)." }

    Push-Location $cloneRoot
    try {
        & git sparse-checkout init --cone
        if ($LASTEXITCODE -ne 0) { throw "git sparse-checkout init failed (exit $LASTEXITCODE)." }
        & git sparse-checkout set manifests
        if ($LASTEXITCODE -ne 0) { throw "git sparse-checkout set failed (exit $LASTEXITCODE)." }
        & git checkout
        if ($LASTEXITCODE -ne 0) { throw "git checkout failed (exit $LASTEXITCODE)." }
    }
    finally { Pop-Location }
}

if (-not (Test-Path -LiteralPath $manifestsRoot)) {
    throw "manifests/ not found under $cloneRoot."
}

$cloneSha = ''
Push-Location $cloneRoot
try {
    $cloneSha = (& git rev-parse HEAD 2>$null).Trim()
} finally { Pop-Location }

# -----------------------------------------------------------------------------
# Walk packages
# -----------------------------------------------------------------------------

$deniedInstallerTypes = @('msix', 'msstore', 'portable', 'zip', 'appx', 'burn-msu')

function ConvertTo-Semver {
    param([string] $Version)
    # Accept "1.2.3", "1.2.3.4", "1.2.3-rc.1", etc. Normalize for sort.
    # Strip a leading 'v' or 'V'.
    $v = $Version -replace '^[vV]', ''
    # Best-effort: pull leading numeric segments.
    $coreMatch = [regex]::Match($v, '^(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:\.(\d+))?')
    if (-not $coreMatch.Success) { return $null }
    $parts = @(0, 0, 0, 0)
    for ($i = 1; $i -le 4; $i++) {
        $g = $coreMatch.Groups[$i]
        if ($g.Success -and $g.Value) {
            $parsed = 0
            if (-not [int]::TryParse($g.Value, [ref]$parsed)) {
                return $null
            }
            $parts[$i - 1] = $parsed
        }
    }
    return [version]::new($parts[0], $parts[1], $parts[2], $parts[3])
}

function Get-LatestVersionDir {
    param([string] $PackageDir)

    $versionDirs = @(Get-ChildItem -LiteralPath $PackageDir -Directory -ErrorAction SilentlyContinue)
    if ($versionDirs.Count -eq 0) { return $null }

    $ranked = foreach ($d in $versionDirs) {
        $sv = ConvertTo-Semver -Version $d.Name
        [pscustomobject]@{ Dir = $d; Version = $d.Name; SemVer = $sv }
    }
    # Prefer entries with parseable semver; fall back to lexical.
    $withSemver = $ranked | Where-Object { $_.SemVer }
    if ($withSemver) {
        return ($withSemver | Sort-Object SemVer -Descending | Select-Object -First 1)
    }
    return ($ranked | Sort-Object Version -Descending | Select-Object -First 1)
}

# winget-pkgs layout: manifests/<letter>/<Publisher>/<Pkg>[/<Sub>...]/<version>/<...yaml>
# A "package" is a directory whose immediate children are version directories
# that themselves contain a *.installer.yaml.

Write-Host "Walking $manifestsRoot ..."
$packageDirs = New-Object System.Collections.Generic.List[string]

# Iterate first-letter shards.
$letterDirs = Get-ChildItem -LiteralPath $manifestsRoot -Directory -ErrorAction SilentlyContinue
foreach ($letter in $letterDirs) {
    # Walk down: each leaf-ish dir whose subdirs look like versions.
    Get-ChildItem -LiteralPath $letter.FullName -Directory -Recurse -ErrorAction SilentlyContinue |
        ForEach-Object {
            $sub = $_
            # Heuristic: a package dir contains at least one immediate child dir
            # that itself contains a *.installer.yaml.
            $childDirs = Get-ChildItem -LiteralPath $sub.FullName -Directory -ErrorAction SilentlyContinue
            if (-not $childDirs) { return }
            foreach ($cd in $childDirs) {
                $hasInstaller = Get-ChildItem -LiteralPath $cd.FullName -Filter '*.installer.yaml' -File -ErrorAction SilentlyContinue
                if ($hasInstaller) {
                    $packageDirs.Add($sub.FullName) | Out-Null
                    break
                }
            }
        }
}

# Dedupe (a package dir can be hit multiple times during traversal).
$packageDirs = @([System.Linq.Enumerable]::Distinct([string[]]$packageDirs.ToArray()) | Sort-Object)

Write-Host ("Found {0} candidate package directories." -f $packageDirs.Count)

$entries = New-Object System.Collections.Generic.List[object]
$processed = 0
$skipped   = 0

foreach ($pkgDir in $packageDirs) {
    if ($MaxPackages -gt 0 -and $entries.Count -ge $MaxPackages) { break }
    $latest = Get-LatestVersionDir -PackageDir $pkgDir
    if (-not $latest) { $skipped++; continue }

    $installerYaml = Get-ChildItem -LiteralPath $latest.Dir.FullName -Filter '*.installer.yaml' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $installerYaml) { $skipped++; continue }

    try {
        $rawYaml  = Get-Content -LiteralPath $installerYaml.FullName -Raw -Encoding UTF8
        $manifest = $rawYaml | ConvertFrom-Yaml
    } catch {
        $skipped++
        continue
    }
    if (-not $manifest) { $skipped++; continue }

    # Derive PackageIdentifier from the path when missing in YAML.
    # manifests/<letter>/<segment>/<segment>/<...>/<version>
    $relRoot = $manifestsRoot.TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    $relPath = $pkgDir.Substring($relRoot.Length)
    $segs    = @($relPath -split '[\\/]+' | Where-Object { $_ })
    if ($segs.Count -lt 2) { $skipped++; continue }
    $idFromPath = ($segs[1..($segs.Count - 1)] -join '.')

    $packageId = if ($manifest.PSObject.Properties['PackageIdentifier']) { [string]$manifest.PackageIdentifier } else { $idFromPath }
    if (-not $packageId) { $packageId = $idFromPath }

    $version = if ($manifest.PSObject.Properties['PackageVersion']) { [string]$manifest.PackageVersion } else { $latest.Version }

    # Collect installer types (root-level + per-installer overrides).
    $types = New-Object System.Collections.Generic.HashSet[string]
    if ($manifest.PSObject.Properties['InstallerType'] -and $manifest.InstallerType) {
        [void]$types.Add(([string]$manifest.InstallerType).ToLowerInvariant())
    }
    if ($manifest.PSObject.Properties['Installers'] -and $manifest.Installers) {
        foreach ($inst in @($manifest.Installers)) {
            if ($inst -and $inst.PSObject.Properties['InstallerType'] -and $inst.InstallerType) {
                [void]$types.Add(([string]$inst.InstallerType).ToLowerInvariant())
            }
            elseif ($inst -and $inst.PSObject.Properties['NestedInstallerType'] -and $inst.NestedInstallerType) {
                [void]$types.Add(([string]$inst.NestedInstallerType).ToLowerInvariant())
            }
        }
    }
    if ($types.Count -eq 0) { [void]$types.Add('unknown') }

    # Eligibility: at least one supported (non-denied) installer type.
    $eligible = $false
    foreach ($t in $types) { if ($t -notin $deniedInstallerTypes) { $eligible = $true; break } }

    # Publisher / moniker (from the optional default-locale manifest in the
    # same version dir if present; fall back to installer YAML).
    $publisher = $null
    $moniker   = $null
    $defaultLocaleYaml = Get-ChildItem -LiteralPath $latest.Dir.FullName -Filter '*.locale.*.yaml' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $defaultLocaleYaml) {
        $defaultLocaleYaml = Get-ChildItem -LiteralPath $latest.Dir.FullName -Filter '*.yaml' -File -ErrorAction SilentlyContinue |
                             Where-Object { $_.Name -notmatch '\.installer\.yaml$' -and $_.Name -notmatch '\.version\.yaml$' } |
                             Select-Object -First 1
    }
    if ($defaultLocaleYaml) {
        try {
            $loc = Get-Content -LiteralPath $defaultLocaleYaml.FullName -Raw -Encoding UTF8 | ConvertFrom-Yaml
            if ($loc) {
                if ($loc.PSObject.Properties['Publisher'] -and $loc.Publisher) { $publisher = [string]$loc.Publisher }
                if ($loc.PSObject.Properties['Moniker']   -and $loc.Moniker)   { $moniker   = [string]$loc.Moniker }
            }
        } catch { }
    }

    $manifestSha = (Get-FileHash -LiteralPath $installerYaml.FullName -Algorithm SHA256).Hash.ToLowerInvariant()

    $entry = [ordered]@{
        packageId     = $packageId
        version       = $version
        installerType = ($types | Sort-Object) -join ','
        eligible      = $eligible
    }
    if ($publisher) { $entry['publisher'] = $publisher }
    if ($moniker)   { $entry['moniker']   = $moniker }
    $entry['manifestSha'] = $manifestSha

    $entries.Add([pscustomobject]$entry) | Out-Null
    $processed++

    if (($processed % 500) -eq 0) {
        Write-Host ("  processed {0} packages..." -f $processed)
    }
}

Write-Host ("Processed {0} packages, skipped {1}." -f $processed, $skipped)

# Sort by packageId for stable diffs.
$sorted = @($entries | Sort-Object packageId)

$eligibleCount = @($sorted | Where-Object { $_.eligible }).Count

$payload = [ordered]@{
    schema        = 1
    generated     = (Get-Date).ToUniversalTime().ToString('o')
    source        = "${Repository}@${cloneSha}"
    count         = $sorted.Count
    eligibleCount = $eligibleCount
    deniedInstallerTypes = $deniedInstallerTypes
    entries       = $sorted
}

$outDir = Split-Path -Parent $OutputPath
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
    [void](New-Item -ItemType Directory -Path $outDir -Force)
}

$payload | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
Write-Host "Wrote $($sorted.Count) entries ($eligibleCount eligible) to: $OutputPath"

if ($cleanupClone) {
    Write-Host "Cleaning up clone at $WorkDir ..."
    try { Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}
