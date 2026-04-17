<#
.SYNOPSIS
    Fetches the raw, unlocalized WinGet manifest YAML for a package — without calling 'winget show'.

.DESCRIPTION
    'winget show' reads from a local manifest cache but formats/localizes its output.
    This script bypasses winget entirely and retrieves the raw manifest using three strategies:

      1. FileCache   — Check %TEMP%\WinGet\...\cache\V{1,2}_M\... (already on disk, fastest)
      2. CDN         — Direct HTTP GET from <sourceArg>/manifests/... (V1/PreIndexed sources only).
      3. REST API    — GET <sourceArg>/packageManifests/<PackageId> (Microsoft.Rest sources only).

    Use -Mode to control which strategies are attempted:
      Auto       (default)  FileCache first, then CDN or REST on miss. Best of both worlds.
      FileCache             Local cache only. Fast and offline. Fails if nothing is cached.
      Online                Skip the FileCache. Always fetch fresh from CDN or REST.

    For the default community source the CDN URL is:
      https://cdn.winget.microsoft.com/cache/manifests/{id[0]}/{Publisher}/{Package}/{Version}/{PackageId}.yaml

    Use -WarmCache to run 'winget show' first, which guarantees a FileCache hit on this and future runs.
    Use -SourceName to target a non-default source (enterprise, self-hosted, etc.).

.PARAMETER PackageId
    The exact WinGet package identifier, e.g. "Git.Git" or "Microsoft.Winget.CLI".

.PARAMETER Version
    Optional. The specific version to fetch. When omitted the script tries to discover the
    latest version from the FileCache or SQLite index. CDN download requires a version.

.PARAMETER PathOnly
    When set, outputs only the full path to the manifest file on disk and exits.
    Only works when the manifest is found in the local FileCache (Strategy 1).
    Useful for piping into Get-Content or other tools.

.PARAMETER WarmCache
    When set, runs 'winget show --id <PackageId> --exact' before checking the cache.
    This guarantees a FileCache hit on the current run and all subsequent runs.
    Combine with -PathOnly for a self-sufficient one-liner that always returns a path.
    Note: for Microsoft.Rest sources the FileCache is never populated by winget; -WarmCache
    has no effect on Strategy 1 for those sources.

.PARAMETER SourceName
    The registered winget source name to target (as shown by 'winget source list').
    When omitted, the script searches all known cache locations for the community source.
    When specified, the script discovers the source's SourceFamilyName and base URL via
    'winget source list --name <SourceName>' and uses them for all cache lookups and CDN URLs.
    Required when the package lives on a non-default (enterprise or self-hosted) source.

.PARAMETER Mode
    Controls which retrieval strategies are attempted. One of:
      Auto       (default)  Try FileCache, then fall back to CDN or REST API on miss.
      FileCache             Only read from the local FileCache. Fails if nothing is cached.
                            Combine with -WarmCache to guarantee a hit without going online
                            at query time (winget does the online fetch ahead of the read).
      Online                Skip the FileCache entirely. Always fetch from CDN or REST API.
                            Useful when the cached copy might be stale or for latency benchmarks.
                            -PathOnly is not supported in Online mode (no file on disk).

.EXAMPLE
    # Auto mode (default): FileCache first, then online fallback
    .\scripts\Get-WinGetManifest.ps1 -PackageId "Git.Git"

    # Local cache only — never touch the network
    .\scripts\Get-WinGetManifest.ps1 -PackageId "Git.Git" -Mode FileCache

    # Guaranteed local read, even on a cold cache (winget warms, then we read)
    .\scripts\Get-WinGetManifest.ps1 -PackageId "Git.Git" -Mode FileCache -WarmCache -PathOnly | Get-Content

    # Force a fresh online fetch — skip whatever is on disk
    .\scripts\Get-WinGetManifest.ps1 -PackageId "Git.Git" -Version "2.47.1.2" -Mode Online

    # Cross-format conversion (JSON output from a YAML community source)
    .\scripts\Get-WinGetManifest.ps1 -PackageId "Git.Git" -AsJson

    # Non-default source
    .\scripts\Get-WinGetManifest.ps1 -PackageId "Contoso.App" -SourceName "MyEnterpriseSource"
    .\scripts\Get-WinGetManifest.ps1 -PackageId "Contoso.App" -SourceName "MyEnterpriseSource" -Mode Online
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory, HelpMessage = 'Exact WinGet package identifier, e.g. Git.Git')]
    [string] $PackageId,

    [Parameter(HelpMessage = 'Specific version string. If omitted, the script discovers from cache/index.')]
    [string] $Version,

    [Parameter(HelpMessage = 'Output only the full path to the manifest file on disk. Requires a FileCache hit.')]
    [switch] $PathOnly,

    [Parameter(HelpMessage = 'Run winget show first to populate the FileCache. Guarantees a cache hit on this and subsequent runs.')]
    [switch] $WarmCache,

    [Parameter(HelpMessage = 'Registered winget source name to target, e.g. "MyEnterpriseSource". Omit to use the community source.')]
    [string] $SourceName,

    [Parameter(HelpMessage = 'Convert output to YAML format (requires the Yayaml module). Mutually exclusive with -AsJson.')]
    [switch] $AsYaml,

    [Parameter(HelpMessage = 'Convert output to JSON format (requires the Yayaml module for YAML sources). Mutually exclusive with -AsYaml.')]
    [switch] $AsJson,

    [Parameter(HelpMessage = 'Which strategies to try. Auto = FileCache then online. FileCache = local only. Online = skip local cache.')]
    [ValidateSet('Auto', 'FileCache', 'Online')]
    [string] $Mode = 'Auto'
)

if ($AsYaml -and $AsJson) {
    throw '-AsYaml and -AsJson are mutually exclusive.'
}

if ($Mode -eq 'Online' -and $PathOnly) {
    throw '-PathOnly is not supported with -Mode Online (no file on disk). Use -Mode Auto or FileCache, optionally with -WarmCache.'
}

if ($Mode -eq 'Online' -and $WarmCache) {
    # Warming populates the FileCache via winget, but Online skips the FileCache.
    # The warm step still runs (it hits the source and fills the cache) but has no
    # effect on this invocation's output. Warn rather than block — user may want
    # both a fresh pull AND a populated cache for a later -Mode FileCache call.
    Write-Warning '-WarmCache populates the FileCache but -Mode Online bypasses it. Warming will run but will not affect this run.'
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Colour helpers -----------------------------------------------------------
function Write-Step  ([string]$msg) { Write-Host "`n== $msg" -ForegroundColor Cyan }
function Write-Found ([string]$msg) { Write-Host "  [FOUND] $msg" -ForegroundColor Green }
function Write-Miss  ([string]$msg) { Write-Host "  [miss]  $msg" -ForegroundColor DarkGray }
function Write-Warn  ([string]$msg) { Write-Host "  [warn]  $msg" -ForegroundColor Yellow }
function Write-Log   ([string]$msg, [ConsoleColor]$Color = 'White') { Write-Host $msg -ForegroundColor $Color }

# Silence all logging when only the path is needed (makes piping clean)
if ($PathOnly) {
    function Write-Step  ([string]$msg) {}
    function Write-Found ([string]$msg) {}
    function Write-Miss  ([string]$msg) {}
    function Write-Warn  ([string]$msg) {}
    function Write-Log   ([string]$msg, [ConsoleColor]$Color = 'White') {}
}

# --- Source defaults (community source) -------------------------------------
$SourceFamilyName = 'Microsoft.Winget.Source_8wekyb3d8bbwe'
$CdnBase          = 'https://cdn.winget.microsoft.com/cache'
$isRestSource     = $false   # Microsoft.Rest sources never write FileCache entries

# --- Derive path components from the package identifier ----------------------
#   PackageId = "Publisher.PackageName"  e.g.  Git.Git  ->  Git / Git
#   CDN path  = manifests/{id[0]}/{Publisher}/{PackageName}/{Version}/{PackageId}.yaml
$firstChar = $PackageId[0].ToString().ToLower()
$dotIdx    = $PackageId.IndexOf('.')
if ($dotIdx -ge 0) {
    $publisher   = $PackageId.Substring(0, $dotIdx)
    $packageName = $PackageId.Substring($dotIdx + 1)
} else {
    Write-Warn "Package ID '$PackageId' contains no dot — treating entire ID as both publisher and package name."
    $publisher   = $PackageId
    $packageName = $PackageId
}

# =============================================================================
# SOURCE DISCOVERY (when -SourceName is specified)
# =============================================================================
# Run 'winget source list --name <SourceName>' and parse the output to discover:
#   - Source type (Microsoft.PreIndexed.Package vs Microsoft.Rest)
#   - Argument / base URL  (used as CDN base for PreIndexed sources)
#   - Data field           (= Package Family Name = SourceFamilyName for PreIndexed sources)
#
# Parsing is done by value patterns rather than field labels so it works regardless
# of the display language of the Windows UI.

if ($SourceName) {
    Write-Step "Discovering source info for '$SourceName'"

    $sourceListOutput = & winget source list --name $SourceName 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Error "winget source list failed (exit $LASTEXITCODE). Is '$SourceName' a registered source? Run: winget source list"
        exit 1
    }

    $sourceListText = $sourceListOutput -join "`n"

    # Detect source type: look for the type string anywhere in the output
    if ($sourceListText -match 'Microsoft\.Rest\b') {
        $isRestSource = $true
        Write-Warn "Source '$SourceName' is type Microsoft.Rest. Manifests are NOT cached to disk by this source type."
        Write-Warn 'Strategy 1 (FileCache) will always miss. Use -WarmCache to fetch via winget show, but -PathOnly will not work.'
    } elseif ($sourceListText -match 'Microsoft\.PreIndexed\.Package\b') {
        $isRestSource = $false
        Write-Found "Source type: Microsoft.PreIndexed.Package"
    } else {
        Write-Warn "Could not determine source type from winget source list output. Proceeding with PreIndexed assumptions."
    }

    # Discover base URL: find the first http(s) URL in the output
    if ($sourceListText -match '(https?://[^\s]+)') {
        $CdnBase = $Matches[1].TrimEnd('/')
        Write-Found "Source base URL: $CdnBase"
    } else {
        Write-Warn "Could not extract base URL from winget source list output."
    }

    # Discover SourceFamilyName: find a Package Family Name pattern (word_13alphanum)
    # PFN format: <Name>_<13-char publisher ID>  e.g. Microsoft.Winget.Source_8wekyb3d8bbwe
    if ($sourceListText -match '([\w.]+_[a-z0-9]{13})') {
        $SourceFamilyName = $Matches[1]
        Write-Found "Source family name: $SourceFamilyName"
    } else {
        Write-Warn "Could not extract SourceFamilyName (Package Family Name) from winget source list output."
        Write-Warn "FileCache lookups may fail. Check: winget source list --name '$SourceName'"
    }
}

if (-not $PathOnly) {
    Write-Host "Package ID   : $PackageId"   -ForegroundColor White
    Write-Host "Publisher    : $publisher"   -ForegroundColor White
    Write-Host "Package name : $packageName" -ForegroundColor White
    Write-Host "CDN key char : $firstChar"   -ForegroundColor White
    if ($SourceName) {
        Write-Host "Source       : $SourceName  ($SourceFamilyName)" -ForegroundColor White
    }
    if ($Version) {
        Write-Host "Version      : $Version" -ForegroundColor White
    } else {
        Write-Host "Version      : (to be discovered)" -ForegroundColor DarkGray
    }
}

function Get-RelativePath ([string]$ver) {
    "manifests/$firstChar/$publisher/$packageName/$ver/$PackageId.yaml"
}

$manifestYaml    = $null
$manifestSource  = $null
$manifestFilePath = $null          # set only when the manifest comes from a file on disk
$manifestFormat  = $null           # 'yaml' or 'json' — the native format of $manifestYaml

# =============================================================================
# WARM CACHE (optional)
# =============================================================================
# Run 'winget show' to force winget to fetch and cache the manifest before
# we try to read it.  This makes Strategy 1 succeed even on a cold cache.

if ($WarmCache) {
    Write-Step 'Warming cache via winget show'
    $wingetArgs = @('show', '--id', $PackageId, '--exact', '--accept-source-agreements')
    if ($Version)    { $wingetArgs += @('--version', $Version) }
    if ($SourceName) { $wingetArgs += @('--source',  $SourceName) }
    Write-Log "  Running: winget $($wingetArgs -join ' ')" DarkCyan
    if ($isRestSource) {
        Write-Warn 'Source is Microsoft.Rest — winget show will not write a FileCache file.'
        Write-Warn '-PathOnly will not work after warming a REST source.'
    }
    & winget @wingetArgs | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "winget show exited with code $LASTEXITCODE — cache may not have been populated."
    } else {
        Write-Found 'winget show completed — cache should now be warm.'
    }
}

# =============================================================================
# STRATEGY 1 — Local FileCache
# =============================================================================
# WinGet caches raw YAML manifests under %TEMP%\WinGet\[defaultState\]\cache\
# The layout differs between Store-installed (packaged) and portable builds:
#
#   Unpackaged / portable  ->  %TEMP%\WinGet\defaultState\cache\{V1_M|V2_M}\{source}\
#   Store-installed        ->  %TEMP%\WinGet\cache\{V1_M|V2_M}\{source}\
#
# Both V1_M and V2_M directories contain plain, uncompressed YAML.
# Files are only present if winget has previously fetched that manifest
# (after any: winget show, winget install, winget upgrade, etc.).
#
# Skipped entirely when -Mode Online is requested.

if ($Mode -eq 'Online') {
    Write-Step 'Strategy 1 — Local FileCache  [skipped: -Mode Online]'
}

if ($Mode -ne 'Online') {

Write-Step 'Strategy 1 — Local FileCache'

$cacheVariants = @(
    @{ Label = 'Unpackaged V1'; Path = [IO.Path]::Combine($env:TEMP, 'WinGet', 'defaultState', 'cache', 'V1_M', $SourceFamilyName) }
    @{ Label = 'Unpackaged V2'; Path = [IO.Path]::Combine($env:TEMP, 'WinGet', 'defaultState', 'cache', 'V2_M', $SourceFamilyName) }
    @{ Label = 'Store V1';      Path = [IO.Path]::Combine($env:TEMP, 'WinGet', 'cache', 'V1_M', $SourceFamilyName) }
    @{ Label = 'Store V2';      Path = [IO.Path]::Combine($env:TEMP, 'WinGet', 'cache', 'V2_M', $SourceFamilyName) }
)

foreach ($variant in $cacheVariants) {
    $root     = $variant.Path
    $isV2     = $variant.Label -match 'V2'   # V2 manifests use a hash as filename (no .yaml)
    Write-Verbose "  [$($variant.Label)] $root"

    if (-not (Test-Path $root)) {
        Write-Miss "[$($variant.Label)] directory not found"
        continue
    }

    if ($Version) {
        # Exact version known — check the version subdirectory.
        # V1: file is named {PackageId}.yaml
        # V2: file is named with the SHA256 hash (no extension) — scan for any single file
        $versionDir = [IO.Path]::Combine($root, "manifests\$firstChar\$publisher\$packageName\$Version")
        Write-Verbose "    Checking: $versionDir"

        if ($isV2) {
            $hit = Get-ChildItem -Path $versionDir -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($hit) {
                Write-Found "[$($variant.Label)] exact-version hit (hash-named):`n    $($hit.FullName)"
                $manifestYaml     = [IO.File]::ReadAllText($hit.FullName)
                $manifestSource   = "FileCache [$($variant.Label)]: $($hit.FullName)"
                $manifestFilePath = $hit.FullName
                $manifestFormat   = 'yaml'
                break
            } else {
                Write-Miss "[$($variant.Label)] not cached for this version"
            }
        } else {
            $filePath = [IO.Path]::Combine($versionDir, "$PackageId.yaml")
            Write-Verbose "    Looking for: $filePath"
            if (Test-Path $filePath) {
                Write-Found "[$($variant.Label)] exact-version hit:`n    $filePath"
                $manifestYaml     = Get-Content $filePath -Raw
                $manifestSource   = "FileCache [$($variant.Label)]: $filePath"
                $manifestFilePath = $filePath
                $manifestFormat   = 'yaml'
                break
            } else {
                Write-Miss "[$($variant.Label)] not cached for this version"
            }
        }
    } else {
        # No version specified — scan for any cached version of this package.
        # Each version subdirectory contains exactly one manifest file.
        $scanBase = [IO.Path]::Combine($root, "manifests\$firstChar\$publisher\$packageName")
        Write-Verbose "    Scanning: $scanBase"
        if (-not (Test-Path $scanBase)) {
            Write-Miss "[$($variant.Label)] no cached data for this package"
            continue
        }

        # Collect one manifest file per version directory (any filename for V2, *.yaml for V1)
        $hits = @(
            Get-ChildItem -Path $scanBase -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                $verDir = $_.FullName
                $ver    = $_.Name
                if ($isV2) {
                    $f = Get-ChildItem -Path $verDir -File -ErrorAction SilentlyContinue | Select-Object -First 1
                } else {
                    $f = Get-Item -Path (Join-Path $verDir "$PackageId.yaml") -ErrorAction SilentlyContinue
                }
                if ($f) { [PSCustomObject]@{ Version = $ver; File = $f; LastWriteTime = $f.LastWriteTime } }
            } | Sort-Object LastWriteTime -Descending
        )

        if ($hits.Count -eq 0) {
            Write-Miss "[$($variant.Label)] no cached manifests found for this package"
            continue
        }

        Write-Found "[$($variant.Label)] found $($hits.Count) cached version(s):"
        foreach ($h in $hits) {
            Write-Log "      $($h.Version)  —  $($h.File.FullName)  [$(Get-Date $h.LastWriteTime -Format 'yyyy-MM-dd HH:mm')]" DarkGreen
        }

        $best = $hits[0]
        Write-Found "Using most-recently-fetched (v$($best.Version)): $($best.File.FullName)"
        $manifestYaml     = [IO.File]::ReadAllText($best.File.FullName)
        $manifestSource   = "FileCache [$($variant.Label)] v$($best.Version): $($best.File.FullName)"
        $manifestFilePath = $best.File.FullName
        $manifestFormat   = 'yaml'
        break
    }
}

}  # end if ($Mode -ne 'Online')

# =============================================================================
# STRATEGY 2 — CDN Direct Download
# =============================================================================
# The public WinGet CDN serves manifests at predictable URLs — no auth required.
# Requires -Version to be known (either passed explicitly or found in the FileCache).
#
#   https://cdn.winget.microsoft.com/cache/manifests/{id[0]}/{Publisher}/{Package}/{Version}/{PackageId}.yaml
#
# Note: this URL works for V1-indexed (PreIndexed.Package) sources only. V2/hash-named
# manifests and Microsoft.Rest sources cannot be fetched this way.
# Use -WarmCache to let winget populate the FileCache directly.
#
# Skipped entirely when -Mode FileCache is requested.

if ($Mode -eq 'FileCache') {
    Write-Step 'Strategy 2 — CDN Direct Download  [skipped: -Mode FileCache]'
} elseif (-not $manifestYaml) {
    Write-Step 'Strategy 2 — CDN Direct Download'

    if ($isRestSource) {
        Write-Warn 'Skipping CDN strategy: source is Microsoft.Rest — will try REST API next.'
    } elseif (-not $Version) {
        Write-Warn 'Version is still unknown — cannot construct CDN URL.'
        Write-Warn 'Options: specify -Version explicitly or use -WarmCache to populate via winget.'
    } else {
        $relPath = Get-RelativePath $Version
        $url     = "$CdnBase/$relPath"
        Write-Log "  Trying: $url" DarkCyan

        try {
            $response       = Invoke-WebRequest -Uri $url -UseBasicParsing -ErrorAction Stop
            $manifestYaml   = $response.Content
            $manifestSource = "CDN: $url"
            $manifestFormat = 'yaml'
            Write-Found "Downloaded $([Math]::Round($manifestYaml.Length / 1KB, 1)) KB"
        } catch {
            Write-Miss "CDN miss ($(($_.Exception.Message -split ':')[0].Trim()))"
            Write-Warn 'Possible causes: misspelled ID, wrong version, V2/hash-named source (use -WarmCache), or non-default source.'
        }
    }
}

# =============================================================================
# STRATEGY 3 — REST API packageManifests endpoint
# =============================================================================
# Microsoft.Rest sources expose a WinGet REST API. The packageManifests endpoint
# returns JSON containing the full manifest for a given package identifier.
#
#   GET {sourceArg}/packageManifests/{PackageId}[?version={Version}]
#
# $CdnBase is set to the source argument (base URL) during source discovery.
# -PathOnly is not supported via this strategy (no local file).
#
# Skipped entirely when -Mode FileCache is requested.

if ($Mode -eq 'FileCache' -and $isRestSource) {
    Write-Step 'Strategy 3 — REST API packageManifests  [skipped: -Mode FileCache]'
} elseif ($Mode -ne 'FileCache' -and -not $manifestYaml -and $isRestSource) {
    Write-Step 'Strategy 3 — REST API packageManifests'

    if (-not $CdnBase -or $CdnBase -eq 'https://cdn.winget.microsoft.com/cache') {
        Write-Warn 'No REST source base URL discovered — specify -SourceName to target a REST source.'
    } else {
        $restUrl = "$CdnBase/packageManifests/$PackageId"
        if ($Version) { $restUrl += "?version=$([Uri]::EscapeDataString($Version))" }
        Write-Log "  Trying: $restUrl" DarkCyan

        try {
            $response = Invoke-WebRequest -Uri $restUrl -UseBasicParsing -ErrorAction Stop `
                -Headers @{ Accept = 'application/json' }
            $parsed = $response.Content | ConvertFrom-Json
            if ($parsed.Data) {
                # Always store REST data as JSON natively; conversion happens at output.
                $manifestYaml   = $parsed.Data | ConvertTo-Json -Depth 20
                $manifestSource = "REST API: $restUrl"
                $manifestFormat = 'json'
                Write-Found "Received manifest from REST API ($([Math]::Round($manifestYaml.Length / 1KB, 1)) KB)"
            } else {
                Write-Miss "REST API returned no Data field"
            }
        } catch {
            Write-Miss "REST API miss ($(($_.Exception.Message -split ':')[0].Trim()))"
        }
    }
}

# =============================================================================
# Output
# =============================================================================
if ($manifestYaml) {
    # Apply format conversion if requested and different from native format
    $targetFormat = if ($AsYaml) { 'yaml' } elseif ($AsJson) { 'json' } else { $manifestFormat }

    if ($targetFormat -ne $manifestFormat) {
        if (-not (Get-Module -ListAvailable -Name Yayaml)) {
            Write-Warn "Yayaml module not found — cannot convert from $manifestFormat to $targetFormat. Install with: Install-Module Yayaml"
            Write-Warn 'Falling back to native format.'
        } else {
            Import-Module Yayaml -ErrorAction Stop
            if ($targetFormat -eq 'json') {
                # YAML -> JSON
                $obj = $manifestYaml | ConvertFrom-Yaml
                $manifestYaml = $obj | ConvertTo-Json -Depth 20
            } else {
                # JSON -> YAML
                $obj = $manifestYaml | ConvertFrom-Json
                $manifestYaml = $obj | ConvertTo-Yaml -Depth 20
            }
        }
    }

    if ($PathOnly) {
        if ($manifestFilePath) {
            # Resolve-Path returns a PathInfo object whose .Path property binds to
            # Get-Content / Copy-Item / etc. via ByPropertyName, and displays as
            # a plain path string when printed to the console.
            Resolve-Path -LiteralPath $manifestFilePath
        } else {
            Write-Error '-PathOnly requires a FileCache hit, but the manifest was downloaded from the CDN. Re-run without -PathOnly to print the YAML, or run "winget show $PackageId" first to populate the cache.'
            exit 1
        }
    } else {
        Write-Host ''
        Write-Host ('-' * 60) -ForegroundColor Green
        Write-Host " SOURCE: $manifestSource" -ForegroundColor Green
        Write-Host ('-' * 60) -ForegroundColor Green
        Write-Host ''
        $manifestYaml   # raw YAML to stdout — pipeline-friendly
    }
} else {
    Write-Host ''
    Write-Error "Could not find manifest for '$PackageId'$(if ($Version) { " v$Version" })."
    $triedList = switch ($Mode) {
        'FileCache' { 'FileCache only (-Mode FileCache)' }
        'Online'    { 'CDN / REST API only (-Mode Online)' }
        default     { 'FileCache -> CDN -> REST API' }
    }
    Write-Host "Tried: $triedList." -ForegroundColor Red
    Write-Host 'Suggestions:' -ForegroundColor Yellow
    $sourceArg = if ($SourceName) { " -SourceName '$SourceName'" } else { '' }
    Write-Host "  1. Verify the ID:     winget search --id '$PackageId' --exact$(if ($SourceName) { " --source '$SourceName'" })" -ForegroundColor Yellow
    Write-Host '  2. Update sources:    winget source update' -ForegroundColor Yellow
    if ($Mode -eq 'FileCache') {
        Write-Host "  3. Warm the cache:    .\Get-WinGetManifest.ps1 -PackageId '$PackageId'$sourceArg -Mode FileCache -WarmCache" -ForegroundColor Yellow
        Write-Host "  4. Or go online:      .\Get-WinGetManifest.ps1 -PackageId '$PackageId'$sourceArg -Mode Online" -ForegroundColor Yellow
    } elseif ($Mode -eq 'Online') {
        Write-Host "  3. Specify -Version:  the CDN strategy requires a version when the source is PreIndexed." -ForegroundColor Yellow
    } else {
        Write-Host "  3. Warm the cache:    .\Get-WinGetManifest.ps1 -PackageId '$PackageId'$sourceArg -WarmCache" -ForegroundColor Yellow
    }
    exit 1
}
