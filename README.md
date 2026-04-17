# winget-tools

A small collection of PowerShell utilities for working with the Windows Package
Manager (winget) beyond what the official CLI exposes.

## Scripts

### `Get-WinGetManifest.ps1`

Fetches the raw, unlocalized WinGet manifest for a package — without going
through `winget show` (which reformats and localizes its output).

The script tries up to three strategies, in priority order, and exposes
knobs to force a specific one:

1. **FileCache** — reads the cached YAML manifest from
   `%TEMP%\WinGet\...\cache\V{1,2}_M\{SourceFamilyName}\...`. Fast and
   offline. Only populated for `Microsoft.PreIndexed.Package` sources after
   winget has already fetched that manifest.
2. **CDN** — issues a direct HTTP GET to the source's base URL using the
   winget PreIndexed path layout:
   `{base}/manifests/{c}/{Publisher}/{Package}/{Version}/{PackageId}.yaml`.
   Requires `-Version`. V2 hash-named manifests cannot be reached this way.
3. **REST API** — issues `GET {base}/packageManifests/{PackageId}` against
   a `Microsoft.Rest` source. Returns JSON natively.

#### Parameters

| Parameter | Description |
|---|---|
| `-PackageId` *(required)* | Exact WinGet identifier, e.g. `Git.Git`. |
| `-Version` | Specific version to fetch. Required for CDN strategy when FileCache is empty. |
| `-PathOnly` | Output only the path to the cached manifest file. Requires a FileCache hit. |
| `-WarmCache` | Run `winget show` first to populate the FileCache. |
| `-SourceName` | Target a non-default source (enterprise, self-hosted, REST). |
| `-AsYaml` / `-AsJson` | Force output format. Converts between YAML and JSON as needed (requires the `Yayaml` module). |
| `-Mode` | `Auto` (default), `FileCache` (offline), or `Online` (skip local cache). |

#### Examples

```powershell
# Default: FileCache first, fall back to online fetch
.\Get-WinGetManifest.ps1 -PackageId Git.Git

# Offline only — never touch the network
.\Get-WinGetManifest.ps1 -PackageId Git.Git -Mode FileCache

# Guaranteed local read (winget warms, then we read from disk)
.\Get-WinGetManifest.ps1 -PackageId Git.Git -Mode FileCache -WarmCache -PathOnly | Get-Content

# Force a fresh online fetch — skip whatever is cached
.\Get-WinGetManifest.ps1 -PackageId Git.Git -Version 2.47.1.2 -Mode Online

# Get JSON output from a YAML community source
.\Get-WinGetManifest.ps1 -PackageId Git.Git -AsJson

# Target a non-default REST source
.\Get-WinGetManifest.ps1 -PackageId Contoso.App -SourceName MyEnterpriseSource
```

## Requirements

- PowerShell 7+
- [winget](https://github.com/microsoft/winget-cli) installed (used for
  source discovery and cache warming)
- [`Yayaml`](https://www.powershellgallery.com/packages/Yayaml) PowerShell
  module — only required for `-AsYaml` / `-AsJson` cross-format conversion:

  ```powershell
  Install-Module Yayaml
  ```

## License

MIT
