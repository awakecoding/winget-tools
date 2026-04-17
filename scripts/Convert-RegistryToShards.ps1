<#
.SYNOPSIS
    Migrates a flat icon-registry.json into hash-sharded shard-NN.json files.

.DESCRIPTION
    Reads -SourceRegistry, hashes each PackageId with FNV-1a (UTF-8) modulo
    -ShardCount, and writes one shard-NN.json per shard under -OutputDir.
    The hashing must match the orchestrator (Invoke-BulkIconExtraction.ps1)
    so future runs land in the right shard.

    Re-runnable: existing shard files are overwritten.

.EXAMPLE
    pwsh ./scripts/Convert-RegistryToShards.ps1 `
        -SourceRegistry ./data/icon-registry.json `
        -OutputDir ./data/registry `
        -ShardCount 10
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $SourceRegistry,

    [Parameter(Mandatory)]
    [string] $OutputDir,

    [ValidateRange(1, 1000)]
    [int] $ShardCount = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$SourceRegistry = [IO.Path]::GetFullPath($SourceRegistry)
$OutputDir      = [IO.Path]::GetFullPath($OutputDir)

if (-not (Test-Path -LiteralPath $SourceRegistry)) {
    throw "Source registry not found: $SourceRegistry"
}
if (-not (Test-Path -LiteralPath $OutputDir)) {
    [void](New-Item -ItemType Directory -Path $OutputDir -Force)
}

function Get-ShardIndex {
    param([string] $Key, [int] $Count)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Key)
    $h = [int64]2166136261
    foreach ($b in $bytes) {
        $h = ((($h -bxor [int64]$b) * 16777619L) % 4294967296L)
    }
    return [int]($h % $Count)
}

Write-Host "Loading $SourceRegistry..."
$source = Get-Content -LiteralPath $SourceRegistry -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
if (-not $source -or -not $source.ContainsKey('entries')) {
    throw "Source registry has no 'entries' object."
}

$entries = $source['entries']
Write-Host ("Source has {0} entries; sharding into {1} files..." -f $entries.Count, $ShardCount)

# Initialize shard buckets
$buckets = @{}
for ($i = 0; $i -lt $ShardCount; $i++) {
    $buckets[$i] = @{}
}

foreach ($key in $entries.Keys) {
    $idx = Get-ShardIndex -Key $key -Count $ShardCount
    $buckets[$idx][$key] = $entries[$key]
}

$nowIso = (Get-Date).ToUniversalTime().ToString('o')
for ($i = 0; $i -lt $ShardCount; $i++) {
    $payload = [ordered]@{
        schema      = 1
        description = "Per-package WinGet icon-extraction registry (shard {0}/{1}). Migrated from {2}." -f $i, $ShardCount, (Split-Path -Leaf $SourceRegistry)
        generated   = $nowIso
        shardIndex  = $i
        shardCount  = $ShardCount
        entries     = $buckets[$i]
    }
    $outPath = Join-Path $OutputDir ("shard-{0:D2}.json" -f $i)
    $payload | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $outPath -Encoding UTF8
    Write-Host ("  shard-{0:D2}.json -> {1,5} entries" -f $i, $buckets[$i].Count)
}

Write-Host "Done."
