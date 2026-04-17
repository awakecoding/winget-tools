<#
.SYNOPSIS
    Aggregates per-shard icon registries into a single public index, optionally
    uploading every HasIcon icon to a rolling GitHub Release.

.DESCRIPTION
    Inputs:
      -RegistryDir      : directory containing shard-NN.json files
      -IconsDir         : directory containing extracted icons (one subdir per
                          PackageId; filenames are arbitrary). Typically the
                          merged output of all per-shard artifacts downloaded
                          in the publish job.
      -OutputIndex      : where to write the merged icon-index.json
      -ReleaseTag       : rolling GitHub Release tag to upload assets to.
                          Default: icons-latest.
      -Repository       : owner/repo; required when -CommitAssets is set.
      -CommitAssets     : when set, uploads each .ico to the release as
                          <PackageId>.<sha8>.ico via 'gh release upload --clobber'.

    Output schema (icon-index.json):
      {
        schema:      1,
        generated:   "<ISO-UTC>",
        repository:  "owner/repo",
        releaseTag:  "icons-latest",
        baseUrl:     "https://github.com/<repo>/releases/download/<tag>/",
        count:       <int>,
        entries: {
          "<PackageId>": {
            version:     "<string>",
            sha256:      "<hex>",
            sizeBytes:   <int>,
            assetName:   "<PackageId>.<sha8>.ico",
            url:         "<baseUrl><assetName>",
            installerType: "<string>",
            publisher?:    "<string>",
            moniker?:      "<string>",
            updatedUtc:    "<ISO-UTC>"
          },
          ...
        },
        statusCounts: { HasIcon: N, NoIcon: N, Unsupported: N, ... }
      }

    Asset naming uses the first 8 hex chars of the icon's sha256 to keep URLs
    stable when content doesn't change but allow per-version cache busting
    when it does.

.EXAMPLE
    pwsh ./scripts/Build-IconIndex.ps1 `
        -RegistryDir ./data/registry `
        -IconsDir ./out/merged `
        -OutputIndex ./data/icon-index.json `
        -Repository awakecoding/winget-tools `
        -ReleaseTag icons-latest `
        -CommitAssets
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $RegistryDir,

    [string] $IconsDir,

    [Parameter(Mandatory)]
    [string] $OutputIndex,

    [string] $ReleaseTag = 'icons-latest',

    [string] $Repository,

    [switch] $CommitAssets
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$RegistryDir = [IO.Path]::GetFullPath($RegistryDir)
$OutputIndex = [IO.Path]::GetFullPath($OutputIndex)
if ($IconsDir) { $IconsDir = [IO.Path]::GetFullPath($IconsDir) }

if (-not (Test-Path -LiteralPath $RegistryDir -PathType Container)) {
    throw "RegistryDir not found: $RegistryDir"
}
if ($CommitAssets) {
    if (-not $Repository) { throw "-Repository is required when -CommitAssets is set." }
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw "gh CLI not found in PATH; required when -CommitAssets is set."
    }
}

# -----------------------------------------------------------------------------
# Load all shard registries
# -----------------------------------------------------------------------------

$shardFiles = Get-ChildItem -LiteralPath $RegistryDir -Filter 'shard-*.json' -File -ErrorAction SilentlyContinue
if (-not $shardFiles) {
    throw "No shard-*.json files found in $RegistryDir"
}

Write-Host ("Loading {0} shard registries..." -f $shardFiles.Count)

$merged = @{}
$statusCounts = @{}
foreach ($f in $shardFiles) {
    $obj = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
    if (-not $obj -or -not $obj.ContainsKey('entries') -or -not $obj['entries']) { continue }
    foreach ($key in $obj['entries'].Keys) {
        $entry = $obj['entries'][$key]
        # Last-write-wins by lastCheckedUtc when a packageId appears in two
        # shards (shouldn't happen given hash sharding, but be robust).
        if ($merged.ContainsKey($key)) {
            $existingChecked = if ($merged[$key].ContainsKey('lastCheckedUtc')) { [string]$merged[$key]['lastCheckedUtc'] } else { '' }
            $candChecked     = if ($entry.ContainsKey('lastCheckedUtc'))         { [string]$entry['lastCheckedUtc'] }         else { '' }
            if ($candChecked -le $existingChecked) { continue }
        }
        $merged[$key] = $entry

        $st = if ($entry.ContainsKey('status')) { [string]$entry['status'] } else { 'Unknown' }
        if (-not $statusCounts.ContainsKey($st)) { $statusCounts[$st] = 0 }
        $statusCounts[$st] = $statusCounts[$st] + 1
    }
}

Write-Host ("Merged {0} unique entries across all shards." -f $merged.Count)

# -----------------------------------------------------------------------------
# Build public index (HasIcon entries only)
# -----------------------------------------------------------------------------

$baseUrl = if ($Repository) { "https://github.com/$Repository/releases/download/$ReleaseTag/" } else { "" }

$indexEntries = [ordered]@{}
$assetsToUpload = New-Object System.Collections.Generic.List[object]

foreach ($key in ($merged.Keys | Sort-Object)) {
    $entry = $merged[$key]
    $st = if ($entry.ContainsKey('status')) { [string]$entry['status'] } else { '' }
    if ($st -ne 'HasIcon') { continue }

    $icons = if ($entry.ContainsKey('icons') -and $entry['icons']) { @($entry['icons']) } else { @() }
    if ($icons.Count -eq 0) { continue }

    # Pick the largest icon as the canonical one (most pixels => best quality).
    $best = $icons | Sort-Object -Property @{ Expression = { if ($_ -is [hashtable]) { $_['bytes'] } else { $_.bytes } }; Descending = $true } | Select-Object -First 1
    $bestName  = if ($best -is [hashtable]) { $best['name'] }   else { $best.name }
    $bestBytes = if ($best -is [hashtable]) { $best['bytes'] }  else { $best.bytes }
    $bestSha   = if ($best -is [hashtable]) { $best['sha256'] } else { $best.sha256 }
    if (-not $bestSha) { continue }

    $sha8 = $bestSha.Substring(0, 8)
    $safeId = $key -replace '[^A-Za-z0-9._-]', '_'
    $assetName = "$safeId.$sha8.ico"

    $idxEntry = [ordered]@{
        version     = if ($entry.ContainsKey('packageVersion')) { $entry['packageVersion'] } else { $null }
        sha256      = $bestSha
        sizeBytes   = $bestBytes
        assetName   = $assetName
        url         = if ($baseUrl) { $baseUrl + $assetName } else { $null }
    }
    if ($entry.ContainsKey('installerType') -and $entry['installerType']) { $idxEntry['installerType'] = $entry['installerType'] }
    if ($entry.ContainsKey('publisher')     -and $entry['publisher'])     { $idxEntry['publisher']     = $entry['publisher'] }
    if ($entry.ContainsKey('moniker')       -and $entry['moniker'])       { $idxEntry['moniker']       = $entry['moniker'] }
    $idxEntry['updatedUtc'] = if ($entry.ContainsKey('lastUpdatedUtc')) { $entry['lastUpdatedUtc'] } else { $entry['lastCheckedUtc'] }

    $indexEntries[$key] = $idxEntry

    if ($IconsDir) {
        $localPath = Join-Path (Join-Path $IconsDir $key) $bestName
        if (Test-Path -LiteralPath $localPath) {
            $assetsToUpload.Add([pscustomobject]@{ Path = $localPath; Asset = $assetName }) | Out-Null
        }
        else {
            Write-Verbose "Local icon missing for $key (looked at: $localPath)"
        }
    }
}

# -----------------------------------------------------------------------------
# Write index
# -----------------------------------------------------------------------------

$payload = [ordered]@{
    schema       = 1
    generated    = (Get-Date).ToUniversalTime().ToString('o')
    repository   = $Repository
    releaseTag   = $ReleaseTag
    baseUrl      = $baseUrl
    count        = $indexEntries.Count
    statusCounts = $statusCounts
    entries      = $indexEntries
}

$outDir = Split-Path -Parent $OutputIndex
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
    [void](New-Item -ItemType Directory -Path $outDir -Force)
}
$payload | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutputIndex -Encoding UTF8
Write-Host ("Wrote index with {0} HasIcon entries to: {1}" -f $indexEntries.Count, $OutputIndex)

Write-Host ''
Write-Host 'Status counts:'
foreach ($k in ($statusCounts.Keys | Sort-Object)) {
    Write-Host ("  {0,-20} {1,5}" -f $k, $statusCounts[$k])
}

# -----------------------------------------------------------------------------
# Upload to GitHub Release
# -----------------------------------------------------------------------------

if ($CommitAssets) {
    if ($assetsToUpload.Count -eq 0) {
        Write-Warning "No local assets to upload (IconsDir was empty or missing files)."
    }
    else {
        Write-Host ''
        Write-Host ("Uploading {0} assets to release '{1}' in {2}..." -f $assetsToUpload.Count, $ReleaseTag, $Repository)

        # Ensure the release exists (create if missing). gh exits non-zero when
        # the release doesn't exist and we're trying to upload.
        $existing = & gh release view $ReleaseTag --repo $Repository 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Release '$ReleaseTag' does not exist; creating..."
            & gh release create $ReleaseTag --repo $Repository `
                --title "WinGet icon database (rolling)" `
                --notes "Rolling release of extracted icons. See data/icon-index.json for the asset map. Updated automatically by .github/workflows/extract-icons.yml."
            if ($LASTEXITCODE -ne 0) { throw "gh release create failed (exit $LASTEXITCODE)." }
        }

        # Stage assets in a temp dir with their final names to avoid uploading
        # the wrong basename.
        $stage = Join-Path ([IO.Path]::GetTempPath()) ("icons-upload-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        [void](New-Item -ItemType Directory -Path $stage -Force)
        try {
            $stagedPaths = @()
            foreach ($a in $assetsToUpload) {
                $dest = Join-Path $stage $a.Asset
                Copy-Item -LiteralPath $a.Path -Destination $dest -Force
                $stagedPaths += $dest
            }

            # Upload in batches of 100 to avoid massive single command lines.
            $batchSize = 100
            for ($i = 0; $i -lt $stagedPaths.Count; $i += $batchSize) {
                $batch = $stagedPaths[$i..([Math]::Min($i + $batchSize - 1, $stagedPaths.Count - 1))]
                Write-Host ("  Uploading batch {0}-{1}..." -f ($i + 1), ($i + $batch.Count))
                & gh release upload $ReleaseTag --repo $Repository --clobber @batch
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "gh release upload returned $LASTEXITCODE for batch starting at $i; continuing."
                }
            }
        }
        finally {
            try { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue } catch { }
        }

        Write-Host "Upload complete."
    }
}
