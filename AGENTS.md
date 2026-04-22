# AGENTS.md

## Purpose

This repository builds and maintains a git-backed catalog of application icons
for WinGet packages.

The extraction model is intentionally sandboxed inside GitHub Actions so package
installation does not happen on a contributor's local machine unless they are
explicitly doing local script testing.

## Source Of Truth

The source of truth is `winget-app-icons/<PackageId>/`.

The `unigetui/` directory is a separate auxiliary dataset used for UniGetUI
package-manager mapping work. Within that subtree:

- `unigetui/screenshot-database-v2.json` is the input dataset
- `unigetui/*-database.json` files are generated artifacts

Do not treat `unigetui/` as part of the durable WinGet icon registry.

Each package directory should contain:

- `metadata.json` for the latest recorded extraction attempt
- `app-icon.ico` only when the latest attempt produced a usable icon

Folder presence means the package has been processed at least once.

Do not reintroduce the old shard/index pipeline under `data/`.

## Current Workflow Model

The main workflow is `.github/workflows/extract-icons.yml`.

Key expectations:

- Manual `workflow_dispatch` only
- Input is a comma-separated list of package IDs
- Maximum batch size is 25 package IDs per run
- Best-effort batch behavior: individual package failures must be recorded in
  `metadata.json`, but must not fail the entire workflow run
- Artifact-first output always exists
- Optional workflow auto-commit writes refreshed package folders back to git

When iterating quickly, prefer batches of 10 packages.

## Important Rules For Agents

1. Treat `winget-app-icons/` as the durable registry.
2. Do not recreate `data/candidates.json`, `data/icon-index.json`, shard files,
   or related publish logic unless the user explicitly asks to resurrect that
   old design.
3. Keep package processing best-effort.
4. A package install failure, manifest/source failure, timeout, or extraction
   failure should become package metadata, not a workflow-level failure.
5. Preserve stable overwrite semantics:
   - refresh `metadata.json` on every processed package
   - replace `app-icon.ico` when a new icon is found
   - remove stale `app-icon.ico` when the latest run produces no icon
6. Prefer GitHub Actions for real extraction runs over local installs.
7. Keep local edits focused; do not mix workflow logic changes with large-scale
   catalog refreshes unless the task requires both.

## Key Files

- `AGENTS.md`: repository guidance for coding agents
- `README.md`: user-facing workflow and repository overview
- `.github/workflows/extract-icons.yml`: batch extraction and optional auto-commit
- `scripts/Invoke-IconExtractionCampaign.ps1`: queue-aware campaign runner for
   plan/run flows, workflow correlation, status TSV output, and optional
   index-backed candidate validation
- `scripts/Invoke-BulkIconExtraction.ps1`: orchestration for install, extract,
  uninstall, metadata emission, and summary generation
- `scripts/Get-WinGetIcon.ps1`: installed-package icon extraction logic
- `scripts/Get-WinGetManifest.ps1`: manifest lookup helper
- `.agents/skills/winget-extract-icons/`: prompt-driven extraction skill for
   GitHub Actions-based icon population
- `.agents/skills/winget-package-index/`: prompt-driven skill for fast
   svrooij/winget-pkgs-index-backed package discovery and campaign validation
- `unigetui/README.md`: overview of UniGetUI source and generated data files
- `unigetui/scripts/Generate-UniGetUiPackageDatabases.ps1`: generates manager-specific
   UniGetUI package databases
- `unigetui/scripts/Get-UniGetUiUnmatchedReport.ps1`: classifies remaining
   UniGetUI source keys that do not map to any generated database

## Editing Guidance

When changing `scripts/Invoke-IconExtractionCampaign.ps1`:

- Preserve sequential, queue-aware dispatch behavior for `extract-icons.yml`
- Preserve dispatch-token and request-label correlation between local automation
   and GitHub Actions runs
- Keep `svrooij-index-v2` support focused on candidate validation only; do not
   let it change the durable extraction contract under `winget-app-icons/`
- For `svrooij-index-v2`, prefer the cached `index.v2.json` file under `out/`, parsed in PowerShell, and refresh it only when explicitly requested, missing, malformed, or older than 4 hours
- Preserve the status TSV output because it is the agent-facing summary surface

When changing PowerShell scripts or examples:

- Prefer cross-platform PowerShell 7 (`pwsh`) compatible syntax, cmdlets, and examples unless the task is intentionally Windows-only
- Avoid Windows PowerShell-only APIs or syntax in new code when a PowerShell 7-compatible alternative is available

When changing `.agents/skills/*`:

- Keep skill descriptions explicit about what they do and when they should fire
- Prefer concise overview guidance in `SKILL.md` and move deeper operational
   detail into referenced files or wrapper scripts
- Include concrete wrapper-script examples when the skill is intended to drive
   repo automation
- Re-run the local skill review command after edits:
   - `$Env:TESSL_WINDOWS='1'; 'C:\Users\mamoreau\AppData\Local\tessl\bin\tessl.exe' skill review D:/dev/winget-tools/.agents/skills/<skill-dir>`

When changing `scripts/Invoke-BulkIconExtraction.ps1`:

- Preserve the per-package output contract under `winget-app-icons/<PackageId>/`
- Preserve non-fatal package-level handling
- Keep `metadata.json` fields stable unless there is a clear migration reason
- Avoid introducing hidden cache/state outside the package directory model

When changing `unigetui/scripts/*.ps1`:

- Keep `unigetui/screenshot-database-v2.json` as the input dataset
- Treat `unigetui/*-database.json` files as generated outputs
- Preserve the current multi-manager output schema unless an intentional migration
   is required
- Update focused tests and `unigetui/README.md` when script behavior changes

When changing `.github/workflows/extract-icons.yml`:

- Keep artifact upload working even if some packages fail
- Keep auto-commit optional
- Prefer simple, explicit PowerShell over clever YAML expressions
- Validate changes with a small manual batch before running a larger batch

## Validation Expectations

For code-only changes, run at minimum:

- PowerShell 7 parse validation for edited `.ps1` files
- `git diff --check`
- workflow/schema error checks if the workflow file changed

For skill changes, also run at minimum:

- the local `tessl.exe skill review` command for each changed skill directory
- focused wrapper-script parse validation when a skill script changed

For UniGetUI generator/report changes, also prefer:

- focused test execution for the UniGetUI scripts under `tests/`
- regeneration of the affected `unigetui/*-database.json` outputs when behavior changes

For workflow behavior changes, prefer this sequence:

1. Run a 1 to 3 package smoke batch with `auto_commit_results=false`
2. Inspect artifact contents and `summary.json`
3. If the workflow path looks correct, run a second smoke batch with
   `auto_commit_results=true`

## Batch Population Guidance

When the user asks to populate more entries:

- Build batches from the cached `svrooij/winget-pkgs-index` catalog unless the user provides explicit package IDs or a custom candidate file
- Exclude package IDs that already exist under `winget-app-icons/`
- Prefer 10-package batches for faster iteration and easier diagnosis
- After each successful auto-commit run, fast-forward local `master` before
  deciding the next batch
- Stop as soon as the requested target count is reached

## Avoid

- Reintroducing scheduled full-catalog sweeps by default
- Treating missing icons as workflow failures
- Treating WinGet source or package metadata problems as reasons to discard the
  rest of the batch
- Reformatting large PowerShell files without a task-specific reason
- Making manual local edits inside `winget-app-icons/` when the intent is to
  drive extraction via GitHub Actions