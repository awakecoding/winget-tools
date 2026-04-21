# UniGetUI Data Files

This directory contains the UniGetUI screenshot source database and the
generated package-manager-specific databases derived from it.

## Files

- `screenshot-database-v2.json`
  - Source UniGetUI icon and screenshot database.
  - Keys are UniGetUI normalized package IDs.
- `choco-database.json`
  - Generated Chocolatey-primary database.
- `winget-database.json`
  - Generated WinGet-primary database.
- `scoop-database.json`
  - Generated Scoop-primary database.
- `python-database.json`
  - Generated PyPI-primary database.
- `npm-database.json`
  - Generated npm-primary database.

Each generated database keeps the original UniGetUI key in the `unigetui`
field, the primary package ID for that manager, mapped IDs in the other
supported managers when a confident match exists, and the original `icon` /
`images` payload.

## Regenerate

Run the generator from the repository root:

```powershell
.\unigetui\scripts\Generate-UniGetUiPackageDatabases.ps1 -PassThru
```

The generator reads `screenshot-database-v2.json` and refreshes all five
manager databases in this directory.

## Unmatched Report

To inspect which UniGetUI source keys still do not map to any generated
database, run:

```powershell
.\unigetui\scripts\Get-UniGetUiUnmatchedReport.ps1 -PassThru
```

This helps separate likely alias or variant gaps from entries that may still
need another package source or a manual mapping rule.

## Notes

- Treat `screenshot-database-v2.json` as the input dataset.
- Treat the manager databases as generated artifacts.
- If you change the matching logic, regenerate the databases and rerun the
  unmatched report.