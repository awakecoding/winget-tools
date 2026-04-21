<#
.SYNOPSIS
    Generates cleaned package-manager databases from UniGetUI's screenshot
    database.

.DESCRIPTION
    Reads `unigetui/screenshot-database-v2.json`, resolves package IDs against
    the current Chocolatey, WinGet, Scoop, Python, and npm catalogs, and writes five
    derived files:

        unigetui/choco-database.json
        unigetui/winget-database.json
        unigetui/scoop-database.json
        unigetui/python-database.json
        unigetui/npm-database.json

    The matching model follows UniGetUI's documented normalized IDs:
    - lowercase IDs
    - spaces, underscores, and dots replaced with dashes
    - WinGet IDs drop the publisher segment
    - Chocolatey IDs drop `.install` and `.portable`
    - Scoop package IDs follow the general normalized-ID rules
    - Python package IDs follow PEP 503 canonicalization
    - npm package IDs drop the leading `@` on scoped packages for the UniGetUI key
#>

[CmdletBinding()]
param(
    [string] $SourcePath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'screenshot-database-v2.json'),
    [string] $OutDir = (Split-Path -Parent $PSScriptRoot),
    [string] $ChocoOutputPath,
    [string] $WingetOutputPath,
    [string] $ScoopOutputPath,
    [string] $PythonOutputPath,
    [string] $NpmOutputPath,
    [switch] $PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-SimpleNormalizedId {
    param([AllowNull()][string] $Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ''
    }

    return (($Value.ToLowerInvariant() -replace '[\s._]+', '-') -replace '(^-+|-+$)', '')
}

function Get-NormalizedChocolateyId {
    param([AllowNull()][string] $PackageId)

    if ([string]::IsNullOrWhiteSpace($PackageId)) {
        return ''
    }

    $value = $PackageId.ToLowerInvariant() -replace '\.(install|portable)$', ''
    return Get-SimpleNormalizedId -Value $value
}

function Get-NormalizedWingetId {
    param([AllowNull()][string] $PackageId)

    if ([string]::IsNullOrWhiteSpace($PackageId)) {
        return ''
    }

    $value = $PackageId -replace '^Winget\.', ''
    $separatorIndex = $value.IndexOf('.')
    if ($separatorIndex -ge 0 -and $separatorIndex -lt ($value.Length - 1)) {
        $value = $value.Substring($separatorIndex + 1)
    }

    return Get-SimpleNormalizedId -Value $value
}

function Get-NormalizedScoopId {
    param([AllowNull()][string] $PackageId)

    return Get-SimpleNormalizedId -Value $PackageId
}

function Get-NormalizedPythonId {
    param([AllowNull()][string] $PackageId)

    if ([string]::IsNullOrWhiteSpace($PackageId)) {
        return ''
    }

    return (($PackageId.ToLowerInvariant()) -replace '[-_.\s]+', '-') -replace '(^-+|-+$)', ''
}

function Get-NormalizedNpmId {
    param([AllowNull()][string] $PackageId)

    if ([string]::IsNullOrWhiteSpace($PackageId)) {
        return ''
    }

    $value = $PackageId.ToLowerInvariant()
    if ($value.StartsWith('@', [System.StringComparison]::Ordinal)) {
        $value = $value.Substring(1)
    }

    $segments = @($value -split '/')
    $normalizedSegments = foreach ($segment in $segments) {
        Get-SimpleNormalizedId -Value $segment
    }

    return (($normalizedSegments | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join '/')
}

function Get-NormalizedIdForManager {
    param(
        [Parameter(Mandatory)][ValidateSet('Choco', 'Winget', 'Scoop', 'Python', 'Npm')][string] $Manager,
        [AllowNull()][string] $PackageId
    )

    switch ($Manager) {
        'Choco' { return Get-NormalizedChocolateyId -PackageId $PackageId }
        'Winget' { return Get-NormalizedWingetId -PackageId $PackageId }
        'Scoop' { return Get-NormalizedScoopId -PackageId $PackageId }
        'Python' { return Get-NormalizedPythonId -PackageId $PackageId }
        'Npm' { return Get-NormalizedNpmId -PackageId $PackageId }
    }
}

function Add-IndexValue {
    param(
        [Parameter(Mandatory)] $Index,
        [Parameter(Mandatory)][string] $Key,
        [Parameter(Mandatory)][string] $Value
    )

    if (-not $Key) {
        return
    }

    if (-not $Index.Contains($Key)) {
        $Index[$Key] = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    }

    $null = $Index[$Key].Add($Value)
}

function New-CatalogIndex {
    param(
        [Parameter(Mandatory)][string[]] $PackageIds,
        [Parameter(Mandatory)][ValidateSet('Choco', 'Winget', 'Scoop', 'Python', 'Npm')][string] $Manager
    )

    $normalize = switch ($Manager) {
        'Choco' { ${function:Get-NormalizedChocolateyId} }
        'Winget' { ${function:Get-NormalizedWingetId} }
        'Scoop' { ${function:Get-NormalizedScoopId} }
        'Python' { ${function:Get-NormalizedPythonId} }
        'Npm' { ${function:Get-NormalizedNpmId} }
    }

    $index = [ordered]@{
        Manager          = $Manager
        CanonicalByLower = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
        ByNormalized     = New-Object 'System.Collections.Hashtable'
        ByCompact        = New-Object 'System.Collections.Hashtable'
        ByFullAlias      = New-Object 'System.Collections.Hashtable'
        ByFullCompact    = New-Object 'System.Collections.Hashtable'
    }

    foreach ($packageId in ($PackageIds | Sort-Object -Unique)) {
        $lower = $packageId.ToLowerInvariant()
        if (-not $index.CanonicalByLower.ContainsKey($lower)) {
            $index.CanonicalByLower[$lower] = $packageId
        }

        $normalized = & $normalize $packageId
        Add-IndexValue -Index $index.ByNormalized -Key $normalized -Value $packageId
        Add-IndexValue -Index $index.ByCompact -Key ($normalized -replace '-', '') -Value $packageId

        $fullAlias = Get-SimpleNormalizedId -Value $packageId
        Add-IndexValue -Index $index.ByFullAlias -Key $fullAlias -Value $packageId
        Add-IndexValue -Index $index.ByFullCompact -Key ($fullAlias -replace '-', '') -Value $packageId
    }

    return $index
}

function Select-CatalogCandidate {
    param(
        [Parameter(Mandatory)][string[]] $Candidates,
        [Parameter(Mandatory)] $CatalogIndex,
        [Parameter(Mandatory)][string] $LookupValue
    )

    if ($Candidates.Count -eq 0) {
        return $null
    }

    if ($Candidates.Count -eq 1) {
        return $Candidates[0]
    }

    $lookupLower = $LookupValue.ToLowerInvariant()
    $exactMatches = @($Candidates | Where-Object { $_.ToLowerInvariant() -eq $lookupLower })
    if ($exactMatches.Count -eq 1) {
        return $exactMatches[0]
    }

    if ($CatalogIndex.Manager -eq 'Choco') {
        $baseCandidates = @($Candidates | Where-Object { $_ -notmatch '\.(install|portable)$' })
        if ($baseCandidates.Count -eq 1) {
            return $baseCandidates[0]
        }
    }

    return $null
}

function Resolve-CatalogPackageId {
    param(
        [Parameter(Mandatory)][string] $LookupValue,
        [Parameter(Mandatory)] $CatalogIndex,
        [switch] $LookupIsNormalized
    )

    $lookupLower = $LookupValue.ToLowerInvariant()
    if ($CatalogIndex.CanonicalByLower.ContainsKey($lookupLower)) {
        return $CatalogIndex.CanonicalByLower[$lookupLower]
    }

    $normalizedLookup = if ($LookupIsNormalized) {
        $lookupLower
    }
    else {
        Get-NormalizedIdForManager -Manager $CatalogIndex.Manager -PackageId $LookupValue
    }

    if (-not $normalizedLookup) {
        return $null
    }

    if (-not $CatalogIndex.ByNormalized.Contains($normalizedLookup)) {
        $compactLookup = $normalizedLookup -replace '-', ''
        if ($CatalogIndex.ByCompact.Contains($compactLookup)) {
            return Select-CatalogCandidate -Candidates @($CatalogIndex.ByCompact[$compactLookup]) -CatalogIndex $CatalogIndex -LookupValue $LookupValue
        }

        if ($CatalogIndex.Manager -eq 'Winget') {
            $fullAliasLookup = Get-SimpleNormalizedId -Value $LookupValue
            if ($CatalogIndex.ByFullAlias.Contains($fullAliasLookup)) {
                return Select-CatalogCandidate -Candidates @($CatalogIndex.ByFullAlias[$fullAliasLookup]) -CatalogIndex $CatalogIndex -LookupValue $LookupValue
            }

            $fullCompactLookup = $fullAliasLookup -replace '-', ''
            if ($CatalogIndex.ByFullCompact.Contains($fullCompactLookup)) {
                return Select-CatalogCandidate -Candidates @($CatalogIndex.ByFullCompact[$fullCompactLookup]) -CatalogIndex $CatalogIndex -LookupValue $LookupValue
            }
        }

        return $null
    }

    return Select-CatalogCandidate -Candidates @($CatalogIndex.ByNormalized[$normalizedLookup]) -CatalogIndex $CatalogIndex -LookupValue $LookupValue
}

function New-TargetNormalizedIdSet {
    param(
        [Parameter(Mandatory)][object[]] $Entries,
        [Parameter(Mandatory)][ValidateSet('Python', 'Npm')][string] $Manager
    )

    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $Entries) {
        if ($entry.IsExplicitWinget) {
            continue
        }

        $normalized = Get-NormalizedIdForManager -Manager $Manager -PackageId $entry.UnigetuiName
        if ($normalized) {
            $null = $set.Add($normalized)
        }
    }

    return $set
}

function Get-ChocolateyPackageIds {
    [CmdletBinding()]
    param()

    $progressPreference = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        $nextUrl = 'https://community.chocolatey.org/api/v2/Packages()?$select=Id&$filter=IsLatestVersion%20eq%20true%20and%20IsPrerelease%20eq%20false&$orderby=Id&$top=500'
        $ids = New-Object 'System.Collections.Generic.List[string]'

        while ($nextUrl) {
            [xml] $xml = (Invoke-WebRequest -UseBasicParsing -Uri $nextUrl).Content
            $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
            $ns.AddNamespace('a', 'http://www.w3.org/2005/Atom')

            foreach ($entry in $xml.SelectNodes('//a:entry', $ns)) {
                $titleNode = $entry.SelectSingleNode('a:title', $ns)
                if ($titleNode -and -not [string]::IsNullOrWhiteSpace($titleNode.InnerText)) {
                    $ids.Add($titleNode.InnerText) | Out-Null
                }
            }

            $nextNode = $xml.SelectSingleNode('//a:link[@rel="next"]', $ns)
            $nextUrl = if ($nextNode) { $nextNode.href } else { $null }
        }

        return @($ids | Sort-Object -Unique)
    }
    finally {
        $ProgressPreference = $progressPreference
    }
}

function Get-WinGetPackageIds {
    [CmdletBinding()]
    param()

    $tempRoot = Join-Path $env:TEMP ('winget-source-' + [guid]::NewGuid().ToString())
    [void](New-Item -ItemType Directory -Path $tempRoot -Force)
    try {
        $msixPath = Join-Path $tempRoot 'source.msix'
        $expandedPath = Join-Path $tempRoot 'pkg'
        Invoke-WebRequest -UseBasicParsing -Uri 'https://cdn.winget.microsoft.com/cache/source.msix' -OutFile $msixPath
        Expand-Archive -LiteralPath $msixPath -DestinationPath $expandedPath -Force

        $dbPath = Join-Path $expandedPath 'Public\index.db'
        if (-not (Test-Path -LiteralPath $dbPath)) {
            throw "WinGet source index.db not found at '$dbPath'."
        }

        $python = Get-Command python -ErrorAction SilentlyContinue
        if ($python) {
            $code = @'
import sqlite3
import sys

connection = sqlite3.connect(sys.argv[1])
cursor = connection.cursor()
for (package_id,) in cursor.execute("select id from ids order by id"):
    print(package_id)
'@
            return @(& $python.Source -c $code $dbPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }

        $sqlite = Get-Command sqlite3 -ErrorAction SilentlyContinue
        if ($sqlite) {
            return @(& $sqlite.Source $dbPath 'select id from ids order by id;' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }

        throw 'Neither python nor sqlite3 is available to read the WinGet SQLite index.'
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force
        }
    }
}

function Get-PythonPackageIds {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $TargetNormalizedIds
    )

    if ($TargetNormalizedIds.Count -eq 0) {
        return @()
    }

    $progressPreference = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        $payload = Invoke-RestMethod -UseBasicParsing -Uri 'https://pypi.org/simple/' -Headers @{ Accept = 'application/vnd.pypi.simple.v1+json' }
        $ids = New-Object 'System.Collections.Generic.List[string]'
        $projects = if ($payload -is [System.Collections.IDictionary]) { $payload['projects'] } else { $payload.projects }

        foreach ($project in @($projects)) {
            $name = if ($project -is [System.Collections.IDictionary]) { [string]$project['name'] } else { [string]$project.name }
            $normalized = Get-NormalizedPythonId -PackageId $name
            if ($normalized -and $TargetNormalizedIds.Contains($normalized)) {
                $ids.Add($name) | Out-Null
            }
        }

        return @($ids | Sort-Object -Unique)
    }
    finally {
        $ProgressPreference = $progressPreference
    }
}

function Get-NpmPackageIds {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $TargetNormalizedIds
    )

    if ($TargetNormalizedIds.Count -eq 0) {
        return @()
    }

    $progressPreference = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        $pageSize = 10000
        $lastId = $null
        $ids = New-Object 'System.Collections.Generic.List[string]'

        while ($true) {
            $url = "https://replicate.npmjs.com/_all_docs?limit=$pageSize"
            if ($lastId) {
                $startKey = '"' + $lastId + '"'
                $url += '&startkey=' + [uri]::EscapeDataString($startKey)
            }

            $page = Invoke-RestMethod -UseBasicParsing -Uri $url
            $rows = @($page.rows)
            if ($rows.Count -eq 0) {
                break
            }

            if ($lastId -and $rows[0].id -eq $lastId) {
                if ($rows.Count -eq 1) {
                    break
                }

                $rows = @($rows | Select-Object -Skip 1)
            }

            foreach ($row in $rows) {
                $id = [string]$row.id
                if ([string]::IsNullOrWhiteSpace($id) -or $id.StartsWith('_', [System.StringComparison]::Ordinal)) {
                    continue
                }

                $normalized = Get-NormalizedNpmId -PackageId $id
                if ($normalized -and $TargetNormalizedIds.Contains($normalized)) {
                    $ids.Add($id) | Out-Null
                }
            }

            if ($rows.Count -lt $pageSize) {
                break
            }

            $lastId = [string]$rows[-1].id
        }

        return @($ids | Sort-Object -Unique)
    }
    finally {
        $ProgressPreference = $progressPreference
    }
}

function Get-ScoopPackageIds {
    [CmdletBinding()]
    param()

    $progressPreference = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        $repos = @('Main', 'Extras', 'Versions', 'Java', 'Nonportable')
        $headers = @{
            Accept     = 'application/vnd.github+json'
            'User-Agent' = 'winget-tools'
        }
        $ids = New-Object 'System.Collections.Generic.List[string]'

        foreach ($repo in $repos) {
            try {
                $repoInfo = Invoke-RestMethod -UseBasicParsing -Uri ("https://api.github.com/repos/ScoopInstaller/{0}" -f $repo) -Headers $headers
            }
            catch {
                $statusCode = $null
                if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
                    $statusCode = [int]$_.Exception.Response.StatusCode
                }

                if ($statusCode -eq 404) {
                    Write-Verbose "Skipping unavailable Scoop bucket repo ScoopInstaller/$repo."
                    continue
                }

                throw
            }

            $defaultBranch = [string]$repoInfo.default_branch
            if ([string]::IsNullOrWhiteSpace($defaultBranch)) {
                throw "Unable to determine default branch for ScoopInstaller/$repo."
            }

            $tree = Invoke-RestMethod -UseBasicParsing -Uri ("https://api.github.com/repos/ScoopInstaller/{0}/git/trees/{1}?recursive=1" -f $repo, $defaultBranch) -Headers $headers
            foreach ($item in @($tree.tree)) {
                if ($item.type -ne 'blob' -or $item.path -notlike 'bucket/*.json') {
                    continue
                }

                $leafName = Split-Path -Path ([string]$item.path) -Leaf
                if ([string]::IsNullOrWhiteSpace($leafName)) {
                    continue
                }

                $ids.Add([IO.Path]::GetFileNameWithoutExtension($leafName)) | Out-Null
            }
        }

        return @($ids | Sort-Object -Unique)
    }
    finally {
        $ProgressPreference = $progressPreference
    }
}

function Get-UniGetUiSourceEntries {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Path
    )

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -Depth 100
    if (-not $raw.Contains('icons_and_screenshots')) {
        throw "Source file '$Path' does not contain icons_and_screenshots."
    }

    $entries = New-Object 'System.Collections.Generic.List[object]'
    foreach ($pair in $raw['icons_and_screenshots'].GetEnumerator()) {
        if ($pair.Key -eq '__test_entry_DO_NOT_EDIT_PLEASE') {
            continue
        }

        $record = $pair.Value
        $entries.Add([pscustomobject]@{
            UnigetuiName     = $pair.Key
            IsExplicitWinget = $pair.Key.StartsWith('Winget.', [System.StringComparison]::OrdinalIgnoreCase)
            Icon             = if ($record.Contains('icon')) { [string]$record['icon'] } else { '' }
            Images           = if ($record.Contains('images')) { @($record['images']) } else { @() }
        }) | Out-Null
    }

    return $entries.ToArray()
}

function New-ResolvedSourceRecord {
    param(
        [Parameter(Mandatory)] $Entry,
        [Parameter(Mandatory)] $ChocoIndex,
        [Parameter(Mandatory)] $WingetIndex,
        [Parameter(Mandatory)] $ScoopIndex,
        [Parameter(Mandatory)] $PythonIndex,
        [Parameter(Mandatory)] $NpmIndex
    )

    $wingetPackage = $null
    $chocoPackage = $null
    $scoopPackage = $null
    $pythonPackage = $null
    $npmPackage = $null

    if ($Entry.IsExplicitWinget) {
        $wingetPackage = $Entry.UnigetuiName.Substring(7)
        $normalizedWingetLookup = Get-NormalizedWingetId -PackageId $wingetPackage
        if ($normalizedWingetLookup) {
            $chocoPackage = Resolve-CatalogPackageId -LookupValue $normalizedWingetLookup -CatalogIndex $ChocoIndex -LookupIsNormalized
            $scoopPackage = Resolve-CatalogPackageId -LookupValue $normalizedWingetLookup -CatalogIndex $ScoopIndex -LookupIsNormalized
        }
    }
    else {
        $chocoPackage = Resolve-CatalogPackageId -LookupValue $Entry.UnigetuiName -CatalogIndex $ChocoIndex
        $wingetPackage = Resolve-CatalogPackageId -LookupValue $Entry.UnigetuiName -CatalogIndex $WingetIndex
        $scoopPackage = Resolve-CatalogPackageId -LookupValue $Entry.UnigetuiName -CatalogIndex $ScoopIndex
        $pythonPackage = Resolve-CatalogPackageId -LookupValue $Entry.UnigetuiName -CatalogIndex $PythonIndex
        $npmPackage = Resolve-CatalogPackageId -LookupValue $Entry.UnigetuiName -CatalogIndex $NpmIndex
    }

    return [pscustomobject]@{
        UnigetuiName     = $Entry.UnigetuiName
        IsExplicitWinget = $Entry.IsExplicitWinget
        Icon             = $Entry.Icon
        Images           = @($Entry.Images)
        ChocoPackage     = $chocoPackage
        WingetPackage    = $wingetPackage
        ScoopPackage     = $scoopPackage
        PythonPackage    = $pythonPackage
        NpmPackage       = $npmPackage
    }
}

function Select-PreferredRecord {
    param(
        [Parameter(Mandatory)][object[]] $Records,
        [Parameter(Mandatory)][ValidateSet('Choco', 'Winget', 'Scoop', 'Python', 'Npm')][string] $PrimaryManager
    )

    $sorted = if ($PrimaryManager -eq 'Winget') {
        $Records | Sort-Object @{ Expression = { if ($_.IsExplicitWinget) { 0 } else { 1 } } }, @{ Expression = { $_.UnigetuiName.ToLowerInvariant() } }
    }
    else {
        $Records | Sort-Object @{ Expression = { if ($_.IsExplicitWinget) { 1 } else { 0 } } }, @{ Expression = { $_.UnigetuiName.ToLowerInvariant() } }
    }

    return $sorted[0]
}

function Convert-ToPackageDatabaseRecord {
    param(
        [Parameter(Mandatory)] $Record,
        [Parameter(Mandatory)][ValidateSet('Choco', 'Winget', 'Scoop', 'Python', 'Npm')][string] $PrimaryManager
    )

    return [ordered]@{
        unigetui = $Record.UnigetuiName
        choco    = $Record.ChocoPackage
        winget   = $Record.WingetPackage
        scoop    = $Record.ScoopPackage
        python   = $Record.PythonPackage
        npm      = $Record.NpmPackage
        icon     = $Record.Icon
        images   = @($Record.Images)
    }
}

function Write-PackageDatabase {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][ValidateSet('Choco', 'Winget', 'Scoop', 'Python', 'Npm')][string] $PrimaryManager,
        [Parameter(Mandatory)][object[]] $Records,
        [Parameter(Mandatory)][string] $SourceFileName
    )

    $packages = [ordered]@{}
    foreach ($record in $Records) {
        switch ($PrimaryManager) {
            'Choco' { $primaryId = $record.ChocoPackage }
            'Winget' { $primaryId = $record.WingetPackage }
            'Scoop' { $primaryId = $record.ScoopPackage }
            'Python' { $primaryId = $record.PythonPackage }
            'Npm' { $primaryId = $record.NpmPackage }
        }

        $packages[$primaryId] = Convert-ToPackageDatabaseRecord -Record $record -PrimaryManager $PrimaryManager
    }

    $payload = [ordered]@{
        schema         = 1
        generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        source         = $SourceFileName
        packageCount   = $packages.Count
        packages       = $packages
    }

    $payload | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Invoke-UniGetUiPackageDatabaseGeneration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $SourcePath,
        [Parameter(Mandatory)][string] $OutDir,
        [string] $ChocoOutputPath,
        [string] $WingetOutputPath,
        [string] $ScoopOutputPath,
        [string] $PythonOutputPath,
        [string] $NpmOutputPath,
        [switch] $PassThru
    )

    if (-not $ChocoOutputPath) {
        $ChocoOutputPath = Join-Path $OutDir 'choco-database.json'
    }

    if (-not $WingetOutputPath) {
        $WingetOutputPath = Join-Path $OutDir 'winget-database.json'
    }

    if (-not $ScoopOutputPath) {
        $ScoopOutputPath = Join-Path $OutDir 'scoop-database.json'
    }

    if (-not $PythonOutputPath) {
        $PythonOutputPath = Join-Path $OutDir 'python-database.json'
    }

    if (-not $NpmOutputPath) {
        $NpmOutputPath = Join-Path $OutDir 'npm-database.json'
    }

    [void](New-Item -ItemType Directory -Path $OutDir -Force)

    $entries = Get-UniGetUiSourceEntries -Path $SourcePath
    $chocoIndex = New-CatalogIndex -PackageIds (Get-ChocolateyPackageIds) -Manager Choco
    $wingetIndex = New-CatalogIndex -PackageIds (Get-WinGetPackageIds) -Manager Winget
    $scoopIndex = New-CatalogIndex -PackageIds (Get-ScoopPackageIds) -Manager Scoop
    $pythonTargets = New-TargetNormalizedIdSet -Entries $entries -Manager Python
    $npmTargets = New-TargetNormalizedIdSet -Entries $entries -Manager Npm
    $pythonIndex = New-CatalogIndex -PackageIds (Get-PythonPackageIds -TargetNormalizedIds $pythonTargets) -Manager Python
    $npmIndex = New-CatalogIndex -PackageIds (Get-NpmPackageIds -TargetNormalizedIds $npmTargets) -Manager Npm

    $resolved = foreach ($entry in $entries) {
        New-ResolvedSourceRecord -Entry $entry -ChocoIndex $chocoIndex -WingetIndex $wingetIndex -ScoopIndex $scoopIndex -PythonIndex $pythonIndex -NpmIndex $npmIndex
    }

    $chocoRecords = @(
        $resolved |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_.ChocoPackage) } |
            Group-Object -Property ChocoPackage |
            ForEach-Object { Select-PreferredRecord -Records $_.Group -PrimaryManager Choco }
    ) | Sort-Object ChocoPackage

    $wingetRecords = @(
        $resolved |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_.WingetPackage) } |
            Group-Object -Property WingetPackage |
            ForEach-Object { Select-PreferredRecord -Records $_.Group -PrimaryManager Winget }
    ) | Sort-Object WingetPackage

    $scoopRecords = @(
        $resolved |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_.ScoopPackage) } |
            Group-Object -Property ScoopPackage |
            ForEach-Object { Select-PreferredRecord -Records $_.Group -PrimaryManager Scoop }
    ) | Sort-Object ScoopPackage

    $pythonRecords = @(
        $resolved |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_.PythonPackage) } |
            Group-Object -Property PythonPackage |
            ForEach-Object { Select-PreferredRecord -Records $_.Group -PrimaryManager Python }
    ) | Sort-Object PythonPackage

    $npmRecords = @(
        $resolved |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_.NpmPackage) } |
            Group-Object -Property NpmPackage |
            ForEach-Object { Select-PreferredRecord -Records $_.Group -PrimaryManager Npm }
    ) | Sort-Object NpmPackage

    Write-PackageDatabase -Path $ChocoOutputPath -PrimaryManager Choco -Records $chocoRecords -SourceFileName ([IO.Path]::GetFileName($SourcePath))
    Write-PackageDatabase -Path $WingetOutputPath -PrimaryManager Winget -Records $wingetRecords -SourceFileName ([IO.Path]::GetFileName($SourcePath))
    Write-PackageDatabase -Path $ScoopOutputPath -PrimaryManager Scoop -Records $scoopRecords -SourceFileName ([IO.Path]::GetFileName($SourcePath))
    Write-PackageDatabase -Path $PythonOutputPath -PrimaryManager Python -Records $pythonRecords -SourceFileName ([IO.Path]::GetFileName($SourcePath))
    Write-PackageDatabase -Path $NpmOutputPath -PrimaryManager Npm -Records $npmRecords -SourceFileName ([IO.Path]::GetFileName($SourcePath))

    if ($PassThru) {
        return [pscustomobject]@{
            SourceEntries      = $entries.Count
            ChocoPackageCount  = $chocoRecords.Count
            WingetPackageCount = $wingetRecords.Count
            ScoopPackageCount  = $scoopRecords.Count
            PythonPackageCount = $pythonRecords.Count
            NpmPackageCount    = $npmRecords.Count
            ChocoOutputPath    = $ChocoOutputPath
            WingetOutputPath   = $WingetOutputPath
            ScoopOutputPath    = $ScoopOutputPath
            PythonOutputPath   = $PythonOutputPath
            NpmOutputPath      = $NpmOutputPath
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-UniGetUiPackageDatabaseGeneration -SourcePath $SourcePath -OutDir $OutDir -ChocoOutputPath $ChocoOutputPath -WingetOutputPath $WingetOutputPath -ScoopOutputPath $ScoopOutputPath -PythonOutputPath $PythonOutputPath -NpmOutputPath $NpmOutputPath -PassThru:$PassThru
}