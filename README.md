# UE Asset JSON Extractor

[Korean](README.ko.md)

Codex skill and helper scripts for extracting AI-readable JSON summaries from Unreal Engine assets (`.uasset` / `.umap`), including Blueprints, maps, widgets, behavior trees, data tables, materials, meshes, and textures when UAssetGUI can parse them.

This project does not try to fully reconstruct Blueprint graphs. It uses UAssetGUI's existing `tojson` output as the stable source, then builds a compact summary/index that is easier for AI tools to inspect. Extraction is read-only and never modifies the original asset files.

## What It Extracts

The AI summary JSON includes:

- Asset path and engine version
- Extraction status: `ok`, `failed`, or `partial`
- Failure details and failure category
- Optional fallback string inventory for failed assets
- NameMap, import, export, and raw export counts
- Class-like names and object names
- Package references, `/Script/...` references, and `/Game/...` references
- Gameplay-tag-like strings
- K2 node, function, and variable/property candidates
- Raw export summaries with index, type, name, and byte size

Raw byte blobs are excluded by default. They are included only when explicitly requested with `-IncludeRaw`.

## Requirements

- Windows PowerShell
- Python 3.10+
- A working UAssetGUI executable
- Unreal Engine version string for the asset, for example `VER_UE5_5`

UAssetGUI is an external dependency. You can use an existing local build or release binary.

## Repository Layout

```text
.
|-- SKILL.md
|-- agents/
|   `-- openai.yaml
|-- references/
|   |-- ai-json-schema.md
|   `-- uassetgui-cli.md
`-- scripts/
    |-- extract_bp_json.ps1
    |-- scan_uasset_strings.py
    `-- summarize_uasset_json.py
```

## Quick Start

Extract one asset:

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

Extract a folder and write a manifest:

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

Normalize an existing UAssetGUI JSON export:

```bash
python scripts/summarize_uasset_json.py \
  --input raw.uassetgui.json \
  --output asset.ai.json \
  --asset-path BP_Thing.uasset \
  --engine-version VER_UE5_5
```

Scan identifiers from a failing asset without UAssetGUI:

```bash
python scripts/scan_uasset_strings.py BP_Thing.uasset --output BP_Thing.strings.json --limit 500
```

## Failure Handling

Some assets fail to parse because of engine-version mismatch, mapping issues, unsupported serialization, locked files, or UAssetAPI exceptions. The wrapper keeps batch extraction alive and writes a failure summary instead of stopping the whole run.

Example failed summary:

```json
{
  "schema_version": "ue-bp-ai-json-v1",
  "asset_path": "C:/Project/Content/BP_Broken.uasset",
  "engine_version": "VER_UE5_5",
  "status": "failed",
  "error": {
    "category": "GuidParseFailed",
    "type": "UAssetGUI.ToJsonFailed",
    "message": "UAssetGUI tojson did not produce a readable JSON file.",
    "stack": "..."
  },
  "string_inventory_json": "C:/Project/bp_asset_analysis_20260513_topic/BP_Broken.hash.strings.json"
}
```

Known failure categories include `OutputPermissionDenied`, `AppDataPermissionDenied`, `UAssetGUITimeout`, `GuidParseFailed`, `IndexOutOfRangeParseFailed`, `NegativeCountParseFailed`, `UAssetGUIParseFailed`, `SummarizerFailed`, and `MalformedSummaryJson`.

Unless `-NoStringFallback` is supplied, failed assets also get a `*.strings.json` fallback inventory. This file is a lossy ASCII identifier scan of the original binary asset. It can reveal names and references when UAssetGUI cannot parse the package, but it is not graph topology.

## Config Isolation

UAssetGUI may read or write configuration and mappings under user profile folders. The PowerShell wrapper avoids common permission and profile-collision problems by:

- Defaulting to non-portable execution with explicit output/appdata roots
- Isolating `LOCALAPPDATA` and `APPDATA` under the output directory
- Supporting `-Portable` only when writing a `Data` folder beside the executable is acceptable
- Using `.NET ProcessStartInfo` instead of PowerShell `Start-Process` for predictable argument and environment handling

Some UAssetGUI builds still resolve the real user AppData folder internally. For Codex/sandboxed runs, keep `OutputPath`, `ManifestPath`, and `AppDataRoot` under the current workspace. If the child process reports `AppDataPermissionDenied`, retry the same command with elevated permissions rather than changing the source assets.

## Codex Skill Usage

This repository is structured as a Codex skill. Put the folder where Codex can load local skills, or invoke it explicitly by path.

The skill teaches Codex to:

- Run UAssetGUI safely in read-only extraction mode
- Normalize raw UAssetGUI JSON
- Prefer compact AI summaries over huge raw JSON blobs
- Inspect manifest files first during batch extraction
- Use fallback string inventories when full parsing fails
- Avoid committing private game assets or generated extraction output

## Output Schema

See [references/ai-json-schema.md](references/ai-json-schema.md) for the field contract.

JSON manifests include command metadata such as the skill path, script path, UAssetGUI path, engine version, output root, appdata root, timeout, fallback settings, option flags, and command timestamp. The wrapper updates the manifest after each asset so long batches keep partial progress. JSONL manifests repeat metadata per entry.

## Limitations

- This is not a complete Blueprint graph decompiler.
- Candidate fields are heuristic indexes, not guaranteed semantic facts.
- Results depend on UAssetGUI/UAssetAPI support for the asset and engine version.
- The fallback string inventory is useful for rough identifier discovery, but cannot prove graph edges, pin connections, ownership, or property values.
- If graph topology or pin wiring is important, use this summary as an index and fall back to UE Editor `Copy as Text` exports for the relevant function graphs.
- Proprietary assets and mappings should not be committed to public repositories.

## Related Projects

- [UAssetGUI](https://github.com/atenfyr/UAssetGUI)
- [UAssetAPI](https://github.com/atenfyr/UAssetAPI)
