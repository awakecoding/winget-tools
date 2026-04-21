<#
.SYNOPSIS
    Focused validation for the UniGetUI unmatched report helper.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'unigetui\scripts\Get-UniGetUiUnmatchedReport.ps1')

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

$tempRoot = Join-Path $env:TEMP ('unigetui-unmatched-' + [guid]::NewGuid().ToString())
[void](New-Item -ItemType Directory -Path $tempRoot -Force)

try {
    $sourcePath = Join-Path $tempRoot 'source.json'
    $dbPath = Join-Path $tempRoot 'db.json'

    @'
{
  "icons_and_screenshots": {
    "__test_entry_DO_NOT_EDIT_PLEASE": {
      "icon": "ignore",
      "images": []
    },
    "git": {
      "icon": "",
      "images": []
    },
    "7zip": {
      "icon": "",
      "images": []
    },
    "7zip-alpha-exe": {
      "icon": "",
      "images": []
    },
    "abiword": {
      "icon": "",
      "images": []
    },
    "google/gemini-cli": {
      "icon": "",
      "images": []
    }
  }
}
'@ | Set-Content -LiteralPath $sourcePath -Encoding UTF8

    @'
{
  "schema": 1,
  "packages": {
    "git": {
      "unigetui": "git"
    },
    "7zip": {
      "unigetui": "7zip"
    },
    "gemini": {
      "unigetui": "google/gemini-cli"
    }
  }
}
'@ | Set-Content -LiteralPath $dbPath -Encoding UTF8

    Assert-Eq -Actual (Get-UniGetUiVariantBaseCandidate -Key '7zip-alpha-exe') -Expected '7zip' -Message 'Variant base detection failed.'
    Assert-Eq -Actual (Get-UniGetUiVariantBaseCandidate -Key 'abiword') -Expected '' -Message 'Plain key should not fabricate a variant base.'

    $report = New-UniGetUiUnmatchedReport -SourcePath $sourcePath -DatabasePaths @($dbPath) -SampleCount 10
    Assert-Eq -Actual $report.sourceEntryCount -Expected 5 -Message 'Source entry count was incorrect.'
    Assert-Eq -Actual $report.matchedEntryCount -Expected 3 -Message 'Matched entry count was incorrect.'
    Assert-Eq -Actual $report.unmatchedEntryCount -Expected 2 -Message 'Unmatched entry count was incorrect.'
    Assert-Eq -Actual $report.categoryCounts.startsWithDigit -Expected 1 -Message 'Digit-start classification was incorrect.'
    Assert-Eq -Actual $report.categoryCounts.containsSlash -Expected 0 -Message 'Slash classification was incorrect.'
    Assert-Eq -Actual $report.categoryCounts.likelyAliasOfKnownKey -Expected 1 -Message 'Alias-of-known classification was incorrect.'
    Assert-Eq -Actual $report.likelyAliasExamples[0].key -Expected '7zip-alpha-exe' -Message 'Alias example key was incorrect.'
    Assert-Eq -Actual $report.likelyAliasExamples[0].baseCandidate -Expected '7zip' -Message 'Alias example base candidate was incorrect.'
    Assert-Eq -Actual $report.unmatchedSample[0] -Expected '7zip-alpha-exe' -Message 'Unmatched sample ordering was incorrect.'
    Assert-Eq -Actual $report.unmatchedSample[1] -Expected 'abiword' -Message 'Unmatched sample ordering was incorrect.'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}

Write-Host 'UniGetUI unmatched report tests passed.' -ForegroundColor Green