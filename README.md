# winget-tools

A small collection of PowerShell utilities for working with the Windows Package
Manager (winget) beyond what the official CLI exposes.

## GitHub Actions batch extraction

The repository now includes a manual sandbox workflow at `.github/workflows/extract-icons.yml` for installing packages inside GitHub Actions, extracting icons there, and bringing the results back into git without installing those packages on your local machine.

The workflow is best-effort by design: package-level install or extraction failures are recorded in `metadata.json` for the affected package, but they do not block the rest of the batch from being published or auto-committed.

### Workflow inputs

| Input | Description |
|---|---|
| `package_ids_csv` | Required comma-separated list of exact winget package IDs. Maximum 25 package IDs per run. |
| `uninstall_after` | When `true`, the workflow uninstalls each package after extraction. |
| `per_package_timeout` | Install timeout in seconds for each package. |
| `auto_commit_results` | When `true`, the workflow also commits the refreshed package folders back to the repository. |

### Output layout

Every processed package gets its own folder under `winget-app-icons/<PackageId>/`.

Files written per package:

- `metadata.json` is always written. Its presence means that package has already gone through the extraction pipeline at least once.
- `app-icon.ico` is written only when the latest run extracted a canonical icon successfully.

`metadata.json` includes the latest attempt status, timestamps, install and extract timings, uninstall timing, exit codes, icon hashes, and other run details. If a package is refreshed and the new run does not find an icon, any stale `app-icon.ico` is removed so the folder reflects the latest result.

### Artifact-first import flow

The workflow always uploads a batch artifact containing:

- `winget-app-icons-batch-<run_id>.zip`
- `summary.json`
- `requested-packages.json`

The zip contains only the `winget-app-icons/<PackageId>/...` folders for that batch, so you can extract it at the repository root and overwrite the existing `winget-app-icons` tree.

When `auto_commit_results` is enabled, the workflow imports that same batch artifact and commits only the refreshed package folders.

## Scripts

### `unigetui/scripts/Generate-UniGetUiPackageDatabases.ps1`

Generates cleaned package-manager databases from
`unigetui/screenshot-database-v2.json`:

- `unigetui/choco-database.json`
- `unigetui/winget-database.json`
- `unigetui/scoop-database.json`
- `unigetui/python-database.json`
- `unigetui/npm-database.json`

Each output record keeps the original UniGetUI key under `unigetui`, the
manager-specific package ID for that database, the mapped package IDs in the
other supported managers when confident matches exist, and the original `icon`
/ `images` payload.

The script follows UniGetUI's documented normalized IDs:

- IDs are lowercased.
- Spaces, underscores, and dots are replaced with dashes.
- WinGet IDs drop the publisher segment before normalization.
- Chocolatey IDs drop `.install` and `.portable` before normalization.
- Scoop package IDs follow the general normalized-ID rules.
- Python package IDs follow PEP 503 canonicalization.
- npm package IDs drop the leading `@` on scoped packages for the UniGetUI key.

Matching order is intentionally conservative:

1. exact package ID match
2. exact normalized-ID match
3. separator-insensitive normalized fallback for cases like
  `xmediarecode` vs `xmedia-recode`
4. WinGet-only full-ID alias fallback for source keys that still include more
  of the original package ID than UniGetUI's standard Winget normalization

If multiple catalog packages still match after those steps, the cross-manager
field is left `null` instead of guessing.

#### Parameters

| Parameter | Description |
|---|---|
| `-SourcePath` | Source UniGetUI JSON file. Default: `unigetui/screenshot-database-v2.json`. |
| `-OutDir` | Output directory for the generated databases. Default: `unigetui/`. |
| `-ChocoOutputPath` | Optional explicit output path for `choco-database.json`. |
| `-WingetOutputPath` | Optional explicit output path for `winget-database.json`. |
| `-ScoopOutputPath` | Optional explicit output path for `scoop-database.json`. |
| `-PythonOutputPath` | Optional explicit output path for `python-database.json`. |
| `-NpmOutputPath` | Optional explicit output path for `npm-database.json`. |
| `-PassThru` | Emit a summary object with source and output counts. |

#### Example

```powershell
.\unigetui\scripts\Generate-UniGetUiPackageDatabases.ps1 -PassThru
```

#### Notes

- Chocolatey package IDs are pulled from the public OData feed.
- WinGet package IDs are pulled from the official `source.msix` index database.
- Scoop package IDs are pulled from the official Scoop buckets on GitHub.
- Python package IDs are filtered from the PyPI Simple API index.
- npm package IDs are filtered from the npm replicate catalog.
- The generated files are deterministic for a fixed source JSON and fixed
  upstream package catalogs.
- Ambiguous cross-manager mappings are intentionally preserved as `null`.

### `unigetui/scripts/Get-UniGetUiUnmatchedReport.ps1`

Summarizes which UniGetUI source keys still are not represented by any generated
database record after running the database generator.

The report is intentionally lightweight and helps separate two broad cases:

- likely alias or package-variant keys such as `7zip-alpha-exe` whose base form
  may already be covered
- likely unsupported-manager or genuinely unmapped keys that still need another
  source or a manual alias rule

#### Parameters

| Parameter | Description |
|---|---|
| `-SourcePath` | Source UniGetUI JSON file. Default: `unigetui/screenshot-database-v2.json`. |
| `-DatabasePaths` | Generated databases to compare against. Defaults to the five package-manager outputs under `unigetui/`. |
| `-ReportPath` | Optional JSON output path for the generated report. |
| `-SampleCount` | Number of sample items to emit for unmatched keys and alias examples. Default: `20`. |
| `-PassThru` | Emit the report object instead of printing JSON text. |

#### Example

```powershell
.\unigetui\scripts\Get-UniGetUiUnmatchedReport.ps1 -PassThru
```

### `scripts/Get-WinGetManifest.ps1`

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
.\scripts\Get-WinGetManifest.ps1 -PackageId Git.Git

# Offline only — never touch the network
.\scripts\Get-WinGetManifest.ps1 -PackageId Git.Git -Mode FileCache

# Guaranteed local read (winget warms, then we read from disk)
.\scripts\Get-WinGetManifest.ps1 -PackageId Git.Git -Mode FileCache -WarmCache -PathOnly | Get-Content

# Force a fresh online fetch — skip whatever is cached
.\scripts\Get-WinGetManifest.ps1 -PackageId Git.Git -Version 2.47.1.2 -Mode Online

# Get JSON output from a YAML community source
.\scripts\Get-WinGetManifest.ps1 -PackageId Git.Git -AsJson

# Target a non-default REST source
.\scripts\Get-WinGetManifest.ps1 -PackageId Contoso.App -SourceName MyEnterpriseSource
```

### `scripts/Get-WinGetIcon.ps1`

Extracts the raw `.ico` of an installed WinGet package — the same way winget
itself does it (see winget-cli's `IconExtraction.cpp` and `ARPHelper.cpp`),
but exposed as a stand-alone script. Uses `Get-WinGetManifest.ps1` to resolve
the WinGet PackageId to one or more correlation hints (ProductCode and/or
DisplayName + Publisher), walks the Uninstall registry hives across both
WOW64 views to find matching ARP entries, and then reproduces the C++ icon
extraction:

- MSI installs → `MsiGetProductInfoW(ProductIcon)`
- Everything else → the ARP `DisplayIcon` value
- Path is unquoted + index parsed via `shlwapi`, env vars expanded
- `.ico` files are copied verbatim
- `.exe` / `.dll` sources are walked via `EnumResourceNamesEx(RT_GROUP_ICON, …)`
  and reassembled into a proper `ICONDIR` + `ICONDIRENTRY` + concatenated
  `RT_ICON` payloads, byte-for-byte matching `ExtractIconFromBinaryFile`

Native work is done in a small C# helper compiled on first call via
`Add-Type` — the script stays a single drop-in `.ps1`.

#### Parameters

| Parameter | Description |
|---|---|
| `-PackageId` *(required)* | Exact WinGet identifier, e.g. `Git.Git`. |
| `-Scope` | `User`, `Machine`, or `Both` (default). Picks which Uninstall hives to search. |
| `-OutDir` | Output directory. Default: `$env:TEMP\winget-icons`. |
| `-Force` | Overwrite existing files. |

Output filename pattern: `{SanitizedDisplayName}.{ProductCode}.ico`.
Each emitted PSCustomObject has `PackageId, ProductCode, DisplayName,
Publisher, Hive, MatchKind, Source, IconIndex, IconPath, SizeBytes`.

#### Examples

```powershell
# Default: extract icon for an installed package
.\scripts\Get-WinGetIcon.ps1 -PackageId Git.Git

# Machine-scope only, custom output directory
.\scripts\Get-WinGetIcon.ps1 -PackageId Docker.DockerDesktop -Scope Machine -OutDir .\icons -Force

# Pipe the result for downstream use
.\scripts\Get-WinGetIcon.ps1 -PackageId Git.Git | Select-Object DisplayName, IconPath, SizeBytes
```

#### Notes

- Requires the package to be installed locally — there's no out-of-the-box
  way to extract an icon for a package that has only been downloaded.
- MSIX / Microsoft Store packages are out of scope (no ARP entry; winget's
  own `IconExtraction` doesn't handle them either).
- Some MSI packages legitimately have no `ProductIcon` set; the script
  warns and exits 0 (faithful to winget's behavior).

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
