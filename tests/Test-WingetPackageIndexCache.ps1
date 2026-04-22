[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$campaignScript = Join-Path $repoRoot 'scripts/Invoke-IconExtractionCampaign.ps1'

if (-not (Test-Path -LiteralPath $campaignScript)) {
    throw "Campaign script not found: $campaignScript"
}

function New-TestIndexJson {
    param([Parameter(Mandatory)] [string]$PackageId)

    return @(
        [pscustomobject]@{
            Name       = $PackageId
            PackageId  = $PackageId
            Version    = '1.0.0'
            Tags       = @('test')
            LastUpdate = '2026-04-22T00:00:00Z'
        }
    ) | ConvertTo-Json -Depth 5
}

function Get-FreeTcpPort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try {
        return ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    }
    finally {
        $listener.Stop()
    }
}

function Start-TestIndexServer {
    param(
        [Parameter(Mandatory)] [int]$Port,
        [Parameter(Mandatory)] [string]$JsonPayload
    )

    return Start-Job -ScriptBlock {
        param($ListenPort, $Payload)

        $listener = [System.Net.HttpListener]::new()
        $listener.Prefixes.Add("http://127.0.0.1:$ListenPort/")
        $listener.Start()
        try {
            $context = $listener.GetContext()
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($Payload)
            $context.Response.ContentType = 'application/json'
            $context.Response.ContentEncoding = [System.Text.Encoding]::UTF8
            $context.Response.ContentLength64 = $bytes.Length
            $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
            $context.Response.OutputStream.Close()
            $context.Response.Close()
        }
        finally {
            $listener.Stop()
            $listener.Close()
        }
    } -ArgumentList $Port, $JsonPayload
}

function Invoke-Plan {
    param(
        [Parameter(Mandatory)] [string]$CandidatePath,
        [Parameter(Mandatory)] [string]$CampaignPath,
        [Parameter(Mandatory)] [string]$IndexUrl,
        [Parameter(Mandatory)] [string]$IndexCachePath
    )

    $params = @{
        Mode                = 'plan'
        TargetCount         = 1
        BatchSize           = 1
        CandidatePath       = $CandidatePath
        CampaignPath        = $CampaignPath
        WingetIndexUrl      = $IndexUrl
        WingetIndexCachePath = $IndexCachePath
    }

    & pwsh -NoLogo -NoProfile -File $campaignScript @params

    if ($LASTEXITCODE -ne 0) {
        throw "Plan command failed with exit code $LASTEXITCODE."
    }
}

$testRoot = Join-Path $repoRoot 'out/tests/winget-index-cache'
Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
[void](New-Item -ItemType Directory -Path $testRoot -Force)

$freshPackageId = 'Contoso.FreshCache'
$freshCandidatePath = Join-Path $testRoot 'fresh-candidate.txt'
$freshCampaignPath = Join-Path $testRoot 'fresh-plan.json'
$freshCachePath = Join-Path $testRoot 'index-fresh.json'
Set-Content -LiteralPath $freshCandidatePath -Value $freshPackageId -Encoding UTF8
Set-Content -LiteralPath $freshCachePath -Value (New-TestIndexJson -PackageId $freshPackageId) -Encoding UTF8
(Get-Item -LiteralPath $freshCachePath).LastWriteTimeUtc = (Get-Date).ToUniversalTime()

Invoke-Plan -CandidatePath $freshCandidatePath -CampaignPath $freshCampaignPath -IndexUrl 'http://127.0.0.1:9/index.v2.json' -IndexCachePath $freshCachePath

$freshPlan = Get-Content -LiteralPath $freshCampaignPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($freshPlan.packages[0] -ne $freshPackageId) {
    throw "Fresh-cache scenario selected '$($freshPlan.packages[0])' instead of '$freshPackageId'."
}

$stalePackageId = 'Contoso.StaleCache'
$staleCandidatePath = Join-Path $testRoot 'stale-candidate.txt'
$staleCampaignPath = Join-Path $testRoot 'stale-plan.json'
$staleCachePath = Join-Path $testRoot 'index-stale.json'
Set-Content -LiteralPath $staleCandidatePath -Value $stalePackageId -Encoding UTF8
Set-Content -LiteralPath $staleCachePath -Value (New-TestIndexJson -PackageId 'Contoso.OldCache') -Encoding UTF8
(Get-Item -LiteralPath $staleCachePath).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddHours(-5)
$staleOriginalWriteTime = (Get-Item -LiteralPath $staleCachePath).LastWriteTimeUtc

$port = Get-FreeTcpPort
$serverJob = Start-TestIndexServer -Port $port -JsonPayload (New-TestIndexJson -PackageId $stalePackageId)
try {
    Invoke-Plan -CandidatePath $staleCandidatePath -CampaignPath $staleCampaignPath -IndexUrl "http://127.0.0.1:$port/index.v2.json" -IndexCachePath $staleCachePath
}
finally {
    Wait-Job -Job $serverJob | Out-Null
    Receive-Job -Job $serverJob | Out-Null
    Remove-Job -Job $serverJob -Force
}

$stalePlan = Get-Content -LiteralPath $staleCampaignPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($stalePlan.packages[0] -ne $stalePackageId) {
    throw "Stale-cache scenario selected '$($stalePlan.packages[0])' instead of '$stalePackageId'."
}

$staleUpdatedWriteTime = (Get-Item -LiteralPath $staleCachePath).LastWriteTimeUtc
if ($staleUpdatedWriteTime -le $staleOriginalWriteTime) {
    throw 'Stale-cache scenario did not refresh the cached JSON file.'
}

Write-Host 'Fresh-cache scenario: PASS' -ForegroundColor Green
Write-Host 'Stale-cache refresh scenario: PASS' -ForegroundColor Green