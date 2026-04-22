# winget-tools

A small collection of PowerShell utilities for working with the Windows Package
Manager (winget) beyond what the official CLI exposes.

## GitHub Actions batch extraction

The repository now includes a manual sandbox workflow at `.github/workflows/extract-icons.yml` for installing packages inside GitHub Actions, extracting icons there, and bringing the results back into git without installing those packages on your local machine.

The workflow is best-effort by design: package-level install or extraction failures are recorded in `metadata.json` for the affected package, but they do not block the rest of the batch from being published or auto-committed.

### Agent skills

The repository now also includes project skills under `.agents/skills/` for prompt-driven extraction campaigns and fast package-index lookups.

The extraction skill at `.agents/skills/extract-winget-icons/` is intended to let an agent handle the whole loop from a simple request such as “extract 10 more winget app icons”:

- select the next unprocessed package IDs from `tests/popular-packages.txt`
- wait for existing `extract-icons.yml` workflow-dispatch runs to finish instead of piling onto the queue
- dispatch new batches with traceable request labels and dispatch tokens
- wait for each workflow run to finish
- rely on workflow auto-commit to update `winget-app-icons/`
- fast-forward local `master` after each batch so the next batch selection sees the latest repo state

The skill wrapper script is `.agents/skills/extract-winget-icons/scripts/run-default-campaign.ps1`, which calls `scripts/Invoke-IconExtractionCampaign.ps1` with repository-friendly defaults.

The index skill at `.agents/skills/winget-package-index/` uses `svrooij/winget-pkgs-index` as a fast availability source instead of local `winget show` probes. Its wrapper script is `.agents/skills/winget-package-index/scripts/run-index-backed-campaign.ps1`, which calls the same campaign runner with `-ValidationSource svrooij-index-v2`.

### Workflow inputs

| Input | Description |
|---|---|
| `package_ids_csv` | Required comma-separated list of exact winget package IDs. Maximum 25 package IDs per run. |
| `uninstall_after` | When `true`, the workflow uninstalls each package after extraction. |
| `per_package_timeout` | Install timeout in seconds for each package. |
| `auto_commit_results` | When `true`, the workflow also commits the refreshed package folders back to the repository. |
| `campaign_id` | Optional automation-supplied campaign identifier used to label and correlate runs. |
| `batch_index` / `batch_total` | Optional automation metadata for multi-batch campaigns. |
| `dispatch_token` | Optional unique token used by the campaign runner to match a workflow-dispatch call to the resulting Actions run. |
| `request_label` | Optional run label shown in the Actions UI and workflow summaries. |

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

### `scripts/Invoke-IconExtractionCampaign.ps1`

Builds and optionally executes a repeatable GitHub Actions extraction campaign
for a large package set (for example, 100 packages split into 10-package
batches).

What it does:

- Parses candidate IDs from a text file (defaults to `tests/popular-packages.txt`).
- Excludes IDs already present under `winget-app-icons/` unless
  `-IncludeExisting` is set.
- Validates each selected package ID either with `winget show --id <PackageId> --exact` or with `svrooij/winget-pkgs-index` via `-ValidationSource svrooij-index-v2`.
- Writes a campaign plan JSON file containing selected IDs and batch CSV payloads.
- Writes a status TSV alongside the plan so automation can summarize batch
  outcomes without scraping multiple terminals.
- In `run` mode, dispatches `.github/workflows/extract-icons.yml` per batch.
- Waits for existing workflow-dispatch runs to finish before dispatching the
  next batch, then correlates each batch via `dispatch_token` and
  `request_label`.
- Optional: downloads each workflow artifact, expands
  `winget-app-icons-batch-<run_id>.zip` at repo root, then commits only the
  requested package folders.

#### Key parameters

| Parameter | Description |
|---|---|
| `-Mode plan|run` | `plan` validates and writes campaign JSON only; `run` also dispatches workflow runs. |
| `-TargetCount` | Number of validated IDs to include (default `100`). |
| `-BatchSize` | Packages per workflow run (default `10`, max `25`). |
| `-ValidationSource` | `winget-show` (default) or `svrooij-index-v2` for faster index-backed validation. |
| `-CampaignPath` | Output JSON plan path (default `out/icon-campaign-100.json`). |
| `-StatusPath` | Optional explicit path for the status TSV written during plan/run flows. |
| `-CampaignId` | Optional explicit campaign identifier used in local status files and workflow inputs. |
| `-DownloadAndImportArtifacts` | After each run, downloads artifact and imports extracted package folders locally. |
| `-PushAfterCommit` | With import mode, pushes each local commit to `origin/master`. |

#### Examples

```powershell
# Create a validated 100-package, 10-batch plan only
.\scripts\Invoke-IconExtractionCampaign.ps1 -Mode plan

# Execute the campaign with manual artifact import + local commit/push
.\scripts\Invoke-IconExtractionCampaign.ps1 -Mode run -DownloadAndImportArtifacts -PushAfterCommit

# Execute with workflow auto-commit enabled (no local artifact import)
.\scripts\Invoke-IconExtractionCampaign.ps1 -Mode run -AutoCommitResults $true

# Plan with the external svrooij package index instead of winget show
.\scripts\Invoke-IconExtractionCampaign.ps1 -Mode plan -ValidationSource svrooij-index-v2 -RefreshWingetIndexCache
```

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
