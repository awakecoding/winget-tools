<#
.SYNOPSIS
    Summarizes UniGetUI source entries that are still unmatched after database generation.

.DESCRIPTION
    Reads `unigetui/screenshot-database-v2.json` and one or more generated
    package-manager databases, computes which UniGetUI source keys are still not
    represented by any generated package record, and emits a compact report.

    The report is intended to answer the next-step question after generation:
    whether the remaining gaps look like alias/variant normalization misses or a
    missing package-manager source.
#>

[CmdletBinding()]
param(
    [string] $SourcePath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'screenshot-database-v2.json'),
    [string[]] $DatabasePaths = @(
        (Join-Path (Split-Path -Parent $PSScriptRoot) 'choco-database.json'),
        (Join-Path (Split-Path -Parent $PSScriptRoot) 'winget-database.json'),
        (Join-Path (Split-Path -Parent $PSScriptRoot) 'scoop-database.json'),
        (Join-Path (Split-Path -Parent $PSScriptRoot) 'python-database.json'),
        (Join-Path (Split-Path -Parent $PSScriptRoot) 'npm-database.json')
    ),
    [string] $ReportPath,
    [int] $SampleCount = 20,
    [switch] $PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-UniGetUiNormalizedKey {
    param([AllowNull()][string] $Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ''
    }

    return (($Value.ToLowerInvariant() -replace '[\s._]+', '-') -replace '(^-+|-+$)', '')
}

function Get-UniGetUiSourceKeys {
    param([Parameter(Mandatory)][string] $Path)

    $payload = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -Depth 100
    if (-not $payload.Contains('icons_and_screenshots')) {
        throw "Source file '$Path' does not contain icons_and_screenshots."
    }

    return @(
        $payload['icons_and_screenshots'].Keys |
            Where-Object { $_ -ne '__test_entry_DO_NOT_EDIT_PLEASE' } |
            Sort-Object -Unique
    )
}

function Get-UniGetUiKnownKeys {
    param([Parameter(Mandatory)][string[]] $Paths)

    $known = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($path in $Paths) {
        if (-not (Test-Path -LiteralPath $path)) {
            throw "Database file '$path' was not found."
        }

        $payload = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -Depth 100
        if (-not $payload.Contains('packages')) {
            continue
        }

        foreach ($record in $payload['packages'].Values) {
            $key = [string]$record['unigetui']
            if (-not [string]::IsNullOrWhiteSpace($key)) {
                $null = $known.Add($key)
            }
        }
    }

    return $known
}

function Get-UniGetUiVariantBaseCandidate {
    param([AllowNull()][string] $Key)

    $candidate = Get-UniGetUiNormalizedKey -Value $Key
    if (-not $candidate) {
        return ''
    }

    $original = $candidate
    $suffixPattern = '(-|_)(alpha|beta|portable|install|exe|msi|helper|cli|nightly|preview|stable|lts|x64|x86|gtk|qt)$'
    do {
        $previous = $candidate
        $candidate = $candidate -replace $suffixPattern, ''
    } while ($candidate -ne $previous)

    if (-not $candidate -or $candidate -eq $original) {
        return ''
    }

    return $candidate
}

function New-UniGetUiUnmatchedReport {
    param(
        [Parameter(Mandatory)][string] $SourcePath,
        [Parameter(Mandatory)][string[]] $DatabasePaths,
        [Parameter(Mandatory)][int] $SampleCount
    )

    $sourceKeys = Get-UniGetUiSourceKeys -Path $SourcePath
    $knownKeys = Get-UniGetUiKnownKeys -Paths $DatabasePaths
    $unmatchedKeys = @($sourceKeys | Where-Object { -not $knownKeys.Contains($_) } | Sort-Object)

    $aliasExamples = New-Object 'System.Collections.Generic.List[object]'
    foreach ($key in $unmatchedKeys) {
        $baseCandidate = Get-UniGetUiVariantBaseCandidate -Key $key
        if (-not $baseCandidate) {
            continue
        }

        if ($knownKeys.Contains($baseCandidate)) {
            $aliasExamples.Add([pscustomobject]@{
                key           = $key
                baseCandidate = $baseCandidate
            }) | Out-Null
        }
    }

    $firstCharacterGroups = @(
        $unmatchedKeys |
            Group-Object { if ($_.Length -gt 0) { $_.Substring(0, 1) } else { '<empty>' } } |
            Sort-Object @{ Expression = { $_.Count }; Descending = $true }, @{ Expression = { $_.Name }; Descending = $false } |
            Select-Object -First ([Math]::Min($SampleCount, 10)) |
            ForEach-Object {
                [ordered]@{
                    character = $_.Name
                    count     = $_.Count
                }
            }
    )

    return [ordered]@{
        generatedAtUtc       = (Get-Date).ToUniversalTime().ToString('o')
        sourcePath           = $SourcePath
        databasePaths        = @($DatabasePaths)
        sourceEntryCount     = $sourceKeys.Count
        matchedEntryCount    = $sourceKeys.Count - $unmatchedKeys.Count
        unmatchedEntryCount  = $unmatchedKeys.Count
        categoryCounts       = [ordered]@{
            startsWithDigit          = @($unmatchedKeys | Where-Object { $_ -match '^[0-9]' }).Count
            containsSlash            = @($unmatchedKeys | Where-Object { $_ -like '*/*' }).Count
            containsDot              = @($unmatchedKeys | Where-Object { $_ -like '*.*' }).Count
            containsUnderscore       = @($unmatchedKeys | Where-Object { $_ -like '*_*' }).Count
            containsUppercase        = @($unmatchedKeys | Where-Object { $_ -cmatch '[A-Z]' }).Count
            likelyAliasOfKnownKey    = $aliasExamples.Count
        }
        likelyAliasExamples  = @($aliasExamples | Select-Object -First $SampleCount)
        firstCharacterGroups = $firstCharacterGroups
        unmatchedSample      = @($unmatchedKeys | Select-Object -First $SampleCount)
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $report = New-UniGetUiUnmatchedReport -SourcePath $SourcePath -DatabasePaths $DatabasePaths -SampleCount $SampleCount

    if ($ReportPath) {
        $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ReportPath -Encoding UTF8
    }

    if ($PassThru) {
        return [pscustomobject]$report
    }

    $report | ConvertTo-Json -Depth 8
}