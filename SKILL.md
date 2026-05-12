---
name: ue-bp-json-extractor
description: Extract AI-readable JSON summaries from Unreal Engine Blueprint and map assets (.uasset/.umap) using UAssetGUI/UAssetAPI. Use when Codex needs to inspect Blueprint assets, batch-export asset indexes, normalize UAssetGUI tojson output, identify NameMap/import/export references, or produce failure-tolerant JSON for AI analysis without modifying source assets.
---

# UE Blueprint JSON Extraction

Use this skill to convert Unreal Engine `.uasset` or `.umap` files into compact JSON that is easier for an AI agent to scan than raw UAssetGUI JSON. Treat extraction as read-only; never write back to the source asset.

## Workflow

1. Confirm the asset path and Unreal engine version, for example `VER_UE5_5`.
2. Prefer `scripts/extract_bp_json.ps1` for local extraction. It runs UAssetGUI `tojson`, isolates config folders, writes a failure JSON when an asset cannot be parsed, and calls the Python summarizer.
3. Use `scripts/summarize_uasset_json.py` directly when raw UAssetGUI JSON already exists.
4. For batch folders, inspect the generated `manifest.json` or `manifest.jsonl` first, then open only the summary JSON files needed for the task.
5. Include raw export blobs only when explicitly needed by passing `-IncludeRaw`; otherwise keep raw bytes out of the AI summary.

## Commands

Single asset:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\extract_bp_json.ps1 `
  "C:\Project\Content\Blueprints\BP_Thing.uasset" `
  "C:\tmp\bp-json\BP_Thing.ai.json" `
  -EngineVersion VER_UE5_5 `
  -UAssetGUIPath "C:\Tools\UAssetGUI\UAssetGUI.exe"
```

Batch folder with manifest:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\extract_bp_json.ps1 `
  "C:\Project\Content\Blueprints" `
  "C:\tmp\bp-json" `
  -EngineVersion VER_UE5_5 `
  -UAssetGUIPath "C:\Tools\UAssetGUI\UAssetGUI.exe" `
  -ManifestPath "C:\tmp\bp-json\manifest.json"
```

Normalize an existing raw JSON export:

```bash
python scripts/summarize_uasset_json.py --input raw.uassetgui.json --output asset.ai.json --asset-path BP_Thing.uasset --engine-version VER_UE5_5
```

If this fork's UAssetGUI binary is available, `toaijson` can be used directly:

```powershell
UAssetGUI.exe toaijson BP_Thing.uasset BP_Thing.ai.json VER_UE5_5 --raw-json BP_Thing.uassetgui.json
```

## References

- Read `references/uassetgui-cli.md` when choosing between direct UAssetGUI commands and the wrapper script.
- Read `references/ai-json-schema.md` when interpreting or validating the summary JSON fields.
