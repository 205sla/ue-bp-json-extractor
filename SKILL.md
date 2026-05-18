---
name: ue-bp-json-extractor
description: Extract AI-readable JSON summaries from Unreal Engine assets (.uasset/.umap) using UAssetGUI/UAssetAPI - Blueprints, maps, widgets, behavior trees, data tables, materials, meshes, and textures. Use when inspecting Unreal assets, extracting Blueprint information, batch-exporting asset indexes, normalizing UAssetGUI tojson output, identifying NameMap/import/export references, or producing failure-tolerant JSON/string inventories without modifying source assets.
---

# UE Asset JSON Extraction

Use this skill to convert Unreal Engine `.uasset` or `.umap` files into compact JSON that is easier for an AI agent to scan than raw UAssetGUI JSON. It is strongest for Blueprint-like assets but can also index maps, widgets, behavior trees, data tables, materials, meshes, and textures when UAssetGUI supports the package. Treat extraction as read-only; never write back to the source asset.

This skill works with both Codex and Claude Code. UAssetGUI is a Windows .NET binary (`UAssetGUI.exe`), so the full extraction wrapper is PowerShell-based. Pick the path that matches the runtime:

- **Windows host** (Claude Code for Windows, Codex on Windows, native PowerShell) - run `scripts/extract_bp_json.ps1` for end-to-end extraction.
- **macOS / Linux / WSL host** (Claude Code without a Windows executor) - run the cross-platform Python helpers (`summarize_uasset_json.py`, `scan_uasset_strings.py`) against raw JSON produced elsewhere, or scan ASCII identifiers from `.uasset` bytes directly. Ask the user to run the PowerShell wrapper on a Windows machine when full parsing is required.

## Workflow

1. Detect the runtime platform first. On Windows, run `scripts/extract_bp_json.ps1` end-to-end. On macOS / Linux / WSL, limit work to the Python helpers (`summarize_uasset_json.py`, `scan_uasset_strings.py`) and coordinate with a Windows machine for full UAssetGUI parsing. Use `$IsWindows` in PowerShell or `uname` / `platform.system()` to check.
2. Confirm the asset path and Unreal engine version, for example `VER_UE5_5`. For `.uproject` `EngineAssociation` values like `5.4` or `5.5`, use `VER_UE5_4` or `VER_UE5_5`.
3. Create an output root under the current workspace, such as `bp_asset_analysis_<date>_<topic>`. Avoid hard-coded scratch paths like `C:\tmp` in sandboxed runs (Codex sandbox, containerized Claude Code, etc.) because they may be listed as writable but still fail at directory creation time.
4. Ensure UAssetGUI is available (Windows path only). Prefer a workspace-local copy under `tools/uassetgui-bin/UAssetGUI.exe`; run `scripts/setup_uassetgui.ps1 -DownloadRelease` to download an upstream release binary into the ignored `tools/` folder. Use source build only when release binaries are unsuitable. `extract_bp_json.ps1` also accepts `-UAssetGUIPath` or `UASSETGUI_PATH`.
5. On Windows, prefer `scripts/extract_bp_json.ps1` for local extraction. It runs UAssetGUI `tojson`, isolates config folders when possible, applies optional per-asset timeout, writes a failure JSON when an asset cannot be parsed, and calls the Python summarizer.
6. Always pass `OutputPath` or `-OutputRoot`, `-ManifestPath`, and `-AppDataRoot` under the same output root for reproducible runs.
7. Use `-NoPortable` for installed UAssetGUI binaries unless the executable directory is known to be writable. Use `-Portable` only when writing a `Data` folder beside the executable is acceptable.
8. If a sandbox write failure blocks the run, retry the same command with escalated permissions instead of changing the source assets.
9. Keep failed summary JSON files; they are analysis artifacts and should record the failure category/message.
10. If child stderr reports AppData or UAssetGUI mappings `UnauthorizedAccessException`, treat `AppDataPermissionDenied` as a sandbox issue and retry the same command with escalation.
11. If UAssetGUI exits successfully but raw JSON is missing or empty, treat `NoRawJsonProduced` as a likely silent UAssetGUI failure in sandboxed Windows runs and retry the same command with escalation. Do not inspect the Windows clipboard unless the user explicitly authorizes it.
12. When UAssetGUI fails, inspect the `string_inventory_json` fallback if present. It is a lossy ASCII identifier inventory from the binary asset, useful for names/references and asset-suitability checks when full parsing fails. Disable it only for very large batches with `-NoStringFallback`.
13. Use `scripts/summarize_uasset_json.py` directly when raw UAssetGUI JSON already exists. This works on any platform with Python 3.10+ and is the primary path for non-Windows hosts.
14. For batch folders, inspect the generated `manifest.json` or `manifest.jsonl` first, then open only the summary JSON files needed for the task. The wrapper updates the manifest after each asset, so interrupted batches can still leave partial progress.
15. Include raw export blobs only when explicitly needed by passing `-IncludeRaw`; otherwise keep raw bytes out of the AI summary.

## Commands

### Windows (PowerShell + UAssetGUI)

Single asset:

```powershell
$out = Join-Path (Get-Location) "bp_asset_analysis_20260513_topic"
powershell -ExecutionPolicy Bypass -File .\scripts\extract_bp_json.ps1 `
  "C:\Project\Content\Blueprints\BP_Thing.uasset" `
  $out `
  -EngineVersion VER_UE5_5 `
  -ManifestPath (Join-Path $out "manifest.json") `
  -AppDataRoot (Join-Path $out ".uassetgui-appdata") `
  -NoPortable `
  -TimeoutSeconds 120
```

Batch folder with manifest:

```powershell
$out = Join-Path (Get-Location) "bp_asset_analysis_20260513_topic"
powershell -ExecutionPolicy Bypass -File .\scripts\extract_bp_json.ps1 `
  "C:\Project\Content\Blueprints" `
  $out `
  -EngineVersion VER_UE5_5 `
  -ManifestPath (Join-Path $out "manifest.json") `
  -AppDataRoot (Join-Path $out ".uassetgui-appdata") `
  -NoPortable `
  -KeepRawJson `
  -TimeoutSeconds 120
```

Prepare a workspace-local UAssetGUI build:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\setup_uassetgui.ps1 -DownloadRelease
```

Use `-ReleaseTag v1.1.0` or another upstream tag when a specific UAssetGUI release is required.

### Cross-platform (Python only)

These run on Windows, macOS, Linux, and WSL with Python 3.10+. They consume raw UAssetGUI JSON produced elsewhere, or scan ASCII identifiers from the binary asset directly. They never call `UAssetGUI.exe` on their own.

Normalize an existing raw JSON export:

```bash
python scripts/summarize_uasset_json.py --input raw.uassetgui.json --output asset.ai.json --asset-path BP_Thing.uasset --engine-version VER_UE5_5
```

Scan identifiers from a failing asset without UAssetGUI:

```bash
python scripts/scan_uasset_strings.py BP_Thing.uasset --output BP_Thing.strings.json --limit 500
```

### Optional: forked UAssetGUI with `toaijson`

If a local/forked UAssetGUI binary with `toaijson` is available, it can be used directly:

```powershell
UAssetGUI.exe toaijson BP_Thing.uasset BP_Thing.ai.json VER_UE5_5 --raw-json BP_Thing.uassetgui.json
```

## References

- Read `references/uassetgui-cli.md` when choosing between direct UAssetGUI commands and the wrapper script.
- Read `references/ai-json-schema.md` when interpreting or validating the summary JSON fields.

## Fallbacks

If a critical Blueprint fails or graph topology/pin wiring matters, do not infer more than the summary supports. Use the generated string inventory for rough identifier/reference inventory, and ask for a UE Editor `Copy as Text` export of the relevant function graph when precise graph structure is required.

When running on Claude Code (or any agent) without Windows access:

- Ask the user to run `scripts/extract_bp_json.ps1` on a Windows machine and share the produced raw JSON or output folder.
- Use `scripts/summarize_uasset_json.py` against that raw JSON to build the AI summary locally.
- If only the binary `.uasset` is available, run `scripts/scan_uasset_strings.py` for an identifier-only inventory and treat it as a rough index, not graph topology.
