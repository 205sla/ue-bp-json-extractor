---
name: ue-bp-json-extractor
description: Extract AI-readable JSON summaries from Unreal Engine assets (.uasset/.umap) using UAssetGUI/UAssetAPI, especially Blueprints, maps, widgets, behavior trees, data tables, materials, meshes, and textures. Use when Codex needs to inspect Unreal assets, batch-export asset indexes, normalize UAssetGUI tojson output, identify NameMap/import/export references, or produce failure-tolerant JSON/string inventories for AI analysis without modifying source assets.
---

# UE Asset JSON Extraction

Use this skill to convert Unreal Engine `.uasset` or `.umap` files into compact JSON that is easier for an AI agent to scan than raw UAssetGUI JSON. It is strongest for Blueprint-like assets but can also index maps, widgets, behavior trees, data tables, materials, meshes, and textures when UAssetGUI supports the package. Treat extraction as read-only; never write back to the source asset.

## Workflow

1. Confirm the asset path and Unreal engine version, for example `VER_UE5_5`.
2. Create an output root under the current workspace, such as `bp_asset_analysis_<date>_<topic>`. Avoid `C:\tmp` in sandboxed Codex runs because it may be listed as writable but still fail at directory creation time.
3. Prefer `scripts/extract_bp_json.ps1` for local extraction. It runs UAssetGUI `tojson`, isolates config folders when possible, applies optional per-asset timeout, writes a failure JSON when an asset cannot be parsed, and calls the Python summarizer.
4. Always pass `OutputPath` or `-OutputRoot`, `-ManifestPath`, and `-AppDataRoot` under the same output root for reproducible runs.
5. Use `-NoPortable` for installed UAssetGUI binaries unless the executable directory is known to be writable. Use `-Portable` only when writing a `Data` folder beside the executable is acceptable.
6. If a sandbox write failure blocks the run, retry the same command with escalated permissions instead of changing the source assets.
7. Keep failed summary JSON files; they are analysis artifacts and should record the failure category/message.
8. If child stderr reports AppData or UAssetGUI mappings `UnauthorizedAccessException`, treat `AppDataPermissionDenied` as a sandbox issue and retry the same command with escalation.
9. When UAssetGUI fails, inspect the `string_inventory_json` fallback if present. It is a lossy ASCII identifier inventory from the binary asset, useful for names/references when full parsing fails. Disable it only for very large batches with `-NoStringFallback`.
10. Use `scripts/summarize_uasset_json.py` directly when raw UAssetGUI JSON already exists.
11. For batch folders, inspect the generated `manifest.json` or `manifest.jsonl` first, then open only the summary JSON files needed for the task. The wrapper updates the manifest after each asset, so interrupted batches can still leave partial progress.
12. Include raw export blobs only when explicitly needed by passing `-IncludeRaw`; otherwise keep raw bytes out of the AI summary.

## Commands

Single asset:

```powershell
$out = Join-Path (Get-Location) "bp_asset_analysis_20260513_topic"
powershell -ExecutionPolicy Bypass -File .\scripts\extract_bp_json.ps1 `
  "C:\Project\Content\Blueprints\BP_Thing.uasset" `
  $out `
  -EngineVersion VER_UE5_5 `
  -UAssetGUIPath "C:\Tools\UAssetGUI\UAssetGUI.exe" `
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
  -UAssetGUIPath "C:\Tools\UAssetGUI\UAssetGUI.exe" `
  -ManifestPath (Join-Path $out "manifest.json") `
  -AppDataRoot (Join-Path $out ".uassetgui-appdata") `
  -NoPortable `
  -KeepRawJson `
  -TimeoutSeconds 120
```

Normalize an existing raw JSON export:

```bash
python scripts/summarize_uasset_json.py --input raw.uassetgui.json --output asset.ai.json --asset-path BP_Thing.uasset --engine-version VER_UE5_5
```

Scan identifiers from a failing asset without UAssetGUI:

```bash
python scripts/scan_uasset_strings.py BP_Thing.uasset --output BP_Thing.strings.json --limit 500
```

If a local/forked UAssetGUI binary with `toaijson` is available, it can be used directly:

```powershell
UAssetGUI.exe toaijson BP_Thing.uasset BP_Thing.ai.json VER_UE5_5 --raw-json BP_Thing.uassetgui.json
```

## References

- Read `references/uassetgui-cli.md` when choosing between direct UAssetGUI commands and the wrapper script.
- Read `references/ai-json-schema.md` when interpreting or validating the summary JSON fields.

## Fallbacks

If a critical Blueprint fails or graph topology/pin wiring matters, do not infer more than the summary supports. Use the generated string inventory for rough identifier/reference inventory, and ask for a UE Editor `Copy as Text` export of the relevant function graph when precise graph structure is required.
