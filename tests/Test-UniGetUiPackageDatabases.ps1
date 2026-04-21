<#
.SYNOPSIS
    Focused validation for UniGetUI package database generation helpers.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'unigetui\scripts\Generate-UniGetUiPackageDatabases.ps1')

function Assert-Eq {
    param(
        [Parameter(Mandatory)] $Actual,
        [Parameter(Mandatory)] $Expected,
        [Parameter(Mandatory)][string] $Message
    )

    if ($Actual -ne $Expected) {
        throw "$Message Expected '$Expected' but got '$Actual'."
    }
}

function Assert-Null {
    param(
        [AllowNull()] $Actual,
        [Parameter(Mandatory)][string] $Message
    )

    if ($null -ne $Actual) {
        throw "$Message Expected <null> but got '$Actual'."
    }
}

Assert-Eq -Actual (Get-NormalizedChocolateyId -PackageId 'git.install') -Expected 'git' -Message 'Chocolatey meta-suffix normalization failed.'
Assert-Eq -Actual (Get-NormalizedChocolateyId -PackageId 'dotnet_desktopruntime.8') -Expected 'dotnet-desktopruntime-8' -Message 'Chocolatey punctuation normalization failed.'
Assert-Eq -Actual (Get-NormalizedWingetId -PackageId 'Git.Git') -Expected 'git' -Message 'WinGet publisher removal failed.'
Assert-Eq -Actual (Get-NormalizedWingetId -PackageId 'Microsoft.DotNet.DesktopRuntime.8') -Expected 'dotnet-desktopruntime-8' -Message 'WinGet normalized ID failed.'
Assert-Eq -Actual (Get-NormalizedWingetId -PackageId 'XMediaRecode.XMediaRecode') -Expected 'xmediarecode' -Message 'WinGet duplicate segment normalization failed.'
Assert-Eq -Actual (Get-NormalizedScoopId -PackageId 'Advanced_Renamer') -Expected 'advanced-renamer' -Message 'Scoop normalization failed.'
Assert-Eq -Actual (Get-NormalizedPythonId -PackageId 'zope.interface') -Expected 'zope-interface' -Message 'Python normalization failed.'
Assert-Eq -Actual (Get-NormalizedNpmId -PackageId '@Google/Gemini_CLI') -Expected 'google/gemini-cli' -Message 'npm normalization failed.'

$wingetIndex = New-CatalogIndex -PackageIds @(
    'Git.Git',
    'Microsoft.Git',
    'Microsoft.DotNet.DesktopRuntime.8',
    'XMediaRecode.XMediaRecode',
    'SoftPerfect.NetworkScanner',
    'Vendor.App'
) -Manager Winget

$chocoIndex = New-CatalogIndex -PackageIds @(
    'git',
    'git.install',
    'dotnet-desktopruntime-8',
    'xmedia-recode',
    'softperfectnetworkscanner',
    'app.portable'
) -Manager Choco

$pythonIndex = New-CatalogIndex -PackageIds @(
    'requests',
    'setuptools',
    'fastapi',
    'zope.interface'
) -Manager Python

$scoopIndex = New-CatalogIndex -PackageIds @(
  'advanced-renamer',
  'acmesharp',
  'allure'
) -Manager Scoop

$npmIndex = New-CatalogIndex -PackageIds @(
    '@google/gemini-cli',
    'npm',
    'pnpm'
) -Manager Npm

Assert-Null -Actual (Resolve-CatalogPackageId -LookupValue 'git' -CatalogIndex $wingetIndex) -Message 'Ambiguous WinGet normalized lookup should stay null.'
Assert-Eq -Actual (Resolve-CatalogPackageId -LookupValue 'dotnet-desktopruntime-8' -CatalogIndex $wingetIndex) -Expected 'Microsoft.DotNet.DesktopRuntime.8' -Message 'WinGet normalized lookup for dotnet failed.'
Assert-Eq -Actual (Resolve-CatalogPackageId -LookupValue 'git' -CatalogIndex $chocoIndex) -Expected 'git' -Message 'Chocolatey base package preference failed.'
Assert-Eq -Actual (Resolve-CatalogPackageId -LookupValue 'xmediarecode' -CatalogIndex $wingetIndex) -Expected 'XMediaRecode.XMediaRecode' -Message 'WinGet repeated-name lookup failed.'
Assert-Eq -Actual (Resolve-CatalogPackageId -LookupValue 'xmediarecode' -CatalogIndex $chocoIndex) -Expected 'xmedia-recode' -Message 'Chocolatey compact normalized fallback failed.'
Assert-Eq -Actual (Resolve-CatalogPackageId -LookupValue 'softperfectnetworkscanner' -CatalogIndex $wingetIndex) -Expected 'SoftPerfect.NetworkScanner' -Message 'WinGet full-ID alias fallback failed.'
Assert-Eq -Actual (Resolve-CatalogPackageId -LookupValue 'advancedrenamer' -CatalogIndex $scoopIndex) -Expected 'advanced-renamer' -Message 'Scoop compact normalized fallback failed.'
Assert-Eq -Actual (Resolve-CatalogPackageId -LookupValue 'requests' -CatalogIndex $pythonIndex) -Expected 'requests' -Message 'Python normalized lookup failed.'
Assert-Eq -Actual (Resolve-CatalogPackageId -LookupValue 'google/gemini-cli' -CatalogIndex $npmIndex) -Expected '@google/gemini-cli' -Message 'npm scoped package lookup failed.'

$tempPath = Join-Path $env:TEMP ('unigetui-source-' + [guid]::NewGuid().ToString() + '.json')
try {
    @'
{
  "package_count": {
    "packages_with_icon": 1
  },
  "icons_and_screenshots": {
    "__test_entry_DO_NOT_EDIT_PLEASE": {
      "icon": "ignore",
      "images": []
    },
    "git": {
      "icon": "https://example.test/git.png",
      "images": []
    },
    "requests": {
      "icon": "https://example.test/requests.png",
      "images": []
    },
    "advancedrenamer": {
      "icon": "https://example.test/advancedrenamer.png",
      "images": []
    },
    "google/gemini-cli": {
      "icon": "https://example.test/gemini-cli.png",
      "images": []
    },
    "Winget.XMediaRecode.XMediaRecode": {
      "icon": "https://example.test/xmediarecode.png",
      "images": [
        "https://example.test/xmediarecode-1.png"
      ]
    }
  }
}
'@ | Set-Content -LiteralPath $tempPath -Encoding UTF8

    $entries = Get-UniGetUiSourceEntries -Path $tempPath
  Assert-Eq -Actual $entries.Count -Expected 5 -Message 'Source entry filtering failed.'

    $gitEntry = $entries | Where-Object { $_.UnigetuiName -eq 'git' } | Select-Object -First 1
    $requestsEntry = $entries | Where-Object { $_.UnigetuiName -eq 'requests' } | Select-Object -First 1
  $scoopEntry = $entries | Where-Object { $_.UnigetuiName -eq 'advancedrenamer' } | Select-Object -First 1
    $npmEntry = $entries | Where-Object { $_.UnigetuiName -eq 'google/gemini-cli' } | Select-Object -First 1
    $wingetEntry = $entries | Where-Object { $_.UnigetuiName -eq 'Winget.XMediaRecode.XMediaRecode' } | Select-Object -First 1

    Assert-Eq -Actual $gitEntry.UnigetuiName -Expected 'git' -Message 'Git source entry missing.'
    Assert-Eq -Actual $wingetEntry.IsExplicitWinget -Expected $true -Message 'Explicit Winget classification failed.'

    $pythonResolved = New-ResolvedSourceRecord -Entry $requestsEntry -ChocoIndex $chocoIndex -WingetIndex $wingetIndex -ScoopIndex $scoopIndex -PythonIndex $pythonIndex -NpmIndex $npmIndex
    Assert-Eq -Actual $pythonResolved.PythonPackage -Expected 'requests' -Message 'Python source record should resolve to PyPI.'

    $scoopResolved = New-ResolvedSourceRecord -Entry $scoopEntry -ChocoIndex $chocoIndex -WingetIndex $wingetIndex -ScoopIndex $scoopIndex -PythonIndex $pythonIndex -NpmIndex $npmIndex
    Assert-Eq -Actual $scoopResolved.ScoopPackage -Expected 'advanced-renamer' -Message 'Scoop source record should resolve to Scoop.'

    $npmResolved = New-ResolvedSourceRecord -Entry $npmEntry -ChocoIndex $chocoIndex -WingetIndex $wingetIndex -ScoopIndex $scoopIndex -PythonIndex $pythonIndex -NpmIndex $npmIndex
    Assert-Eq -Actual $npmResolved.NpmPackage -Expected '@google/gemini-cli' -Message 'npm source record should resolve to npm.'

    $wingetResolved = New-ResolvedSourceRecord -Entry $wingetEntry -ChocoIndex $chocoIndex -WingetIndex $wingetIndex -ScoopIndex $scoopIndex -PythonIndex $pythonIndex -NpmIndex $npmIndex
    Assert-Eq -Actual $wingetResolved.WingetPackage -Expected 'XMediaRecode.XMediaRecode' -Message 'Explicit Winget package should preserve its real ID.'
    Assert-Eq -Actual $wingetResolved.ChocoPackage -Expected 'xmedia-recode' -Message 'Explicit Winget record should map to Chocolatey via compact normalized ID.'
    Assert-Null -Actual $wingetResolved.ScoopPackage -Message 'Explicit Winget record should stay null for Scoop when no matching Scoop package exists.'
    Assert-Null -Actual $wingetResolved.PythonPackage -Message 'Explicit Winget record should not resolve to Python.'
    Assert-Null -Actual $wingetResolved.NpmPackage -Message 'Explicit Winget record should not resolve to npm.'
}
finally {
    if (Test-Path -LiteralPath $tempPath) {
        Remove-Item -LiteralPath $tempPath -Force
    }
}

Write-Host 'UniGetUI package database tests passed.' -ForegroundColor Green