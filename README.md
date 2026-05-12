# UE Blueprint JSON Extractor

[한국어](README.ko.md)

Codex skill and helper scripts for extracting AI-readable JSON summaries from Unreal Engine Blueprint and map assets (`.uasset` / `.umap`).

This project does not try to fully reconstruct Blueprint graphs. Instead, it uses UAssetGUI's existing `tojson` output as a stable source and builds a compact summary/index that is easier for AI tools to inspect.

## What It Extracts

The AI summary JSON includes:

- Asset path and engine version
- Extraction status: `ok`, `failed`, or `partial`
- Failure details when extraction fails
- NameMap, import, export, and raw export counts
- Class-like names
- Object names
- Package references
- `/Script/...` references
- `/Game/...` references
- Gameplay-tag-like strings
- K2 node candidates
- Function candidates
- Variable/property candidates
- Raw export summaries with index, type, name, and byte size

Raw byte blobs are excluded by default. They are included only when explicitly requested.

## Why

Raw UAssetGUI JSON can be large and noisy. For AI-assisted reverse engineering, auditing, search, or documentation, it is often more useful to have a predictable summary with the most relevant names and references surfaced up front.

This tool is designed for read-only extraction. It never modifies the original `.uasset` or `.umap` file.

## Requirements

- Windows PowerShell
- Python 3.10+
- A working UAssetGUI executable
- Unreal Engine version string for the asset, for example `VER_UE5_5`

UAssetGUI is an external dependency. You can use an existing local build or release binary.

## Repository Layout

```text
.
├── SKILL.md
├── agents/
│   └── openai.yaml
├── references/
│   ├── ai-json-schema.md
│   └── uassetgui-cli.md
└── scripts/
    ├── extract_bp_json.ps1
    └── summarize_uasset_json.py
```

## Quick Start

Extract one asset:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\extract_bp_json.ps1 `
  "C:\Project\Content\Blueprints\BP_Thing.uasset" `
  "C:\tmp\bp-json\BP_Thing.ai.json" `
  -EngineVersion VER_UE5_5 `
  -UAssetGUIPath "C:\Tools\UAssetGUI\UAssetGUI.exe"
```

Extract a folder and write a manifest:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\extract_bp_json.ps1 `
  "C:\Project\Content\Blueprints" `
  "C:\tmp\bp-json" `
  -EngineVersion VER_UE5_5 `
  -UAssetGUIPath "C:\Tools\UAssetGUI\UAssetGUI.exe" `
  -ManifestPath "C:\tmp\bp-json\manifest.json"
```

Normalize an existing UAssetGUI JSON export:

```bash
python scripts/summarize_uasset_json.py \
  --input raw.uassetgui.json \
  --output asset.ai.json \
  --asset-path BP_Thing.uasset \
  --engine-version VER_UE5_5
```

## Failure Handling

Some assets fail to parse because of engine-version mismatch, mapping issues, unsupported serialization, locked files, or UAssetAPI exceptions.

The wrapper keeps batch extraction alive. For failed assets it writes a JSON file like:

```json
{
  "schema_version": "ue-bp-ai-json-v1",
  "asset_path": "C:/Project/Content/BP_Broken.uasset",
  "engine_version": "VER_UE5_5",
  "status": "failed",
  "error": {
    "type": "UAssetGUI.ToJsonFailed",
    "message": "UAssetGUI tojson did not produce a readable JSON file.",
    "stack": "..."
  }
}
```

## Config Isolation

UAssetGUI may read or write configuration and mappings under user profile folders. The PowerShell wrapper avoids common permission and profile-collision problems by:

- Trying portable mode when possible
- Isolating `LOCALAPPDATA` and `APPDATA` under the output directory
- Using `.NET ProcessStartInfo` instead of PowerShell `Start-Process` for predictable argument and environment handling

## Codex Skill Usage

This repository is structured as a Codex skill. Put the folder where Codex can load local skills, or invoke it explicitly by path.

The skill teaches Codex to:

- Run UAssetGUI safely in read-only extraction mode
- Normalize raw UAssetGUI JSON
- Prefer compact AI summaries over huge raw JSON blobs
- Inspect manifest files first during batch extraction
- Avoid committing private game assets or generated extraction output

## Output Schema

See [references/ai-json-schema.md](references/ai-json-schema.md) for the field contract.

## Limitations

- This is not a complete Blueprint graph decompiler.
- Candidate fields are heuristic indexes, not guaranteed semantic facts.
- Results depend on UAssetGUI/UAssetAPI support for the asset and engine version.
- Proprietary assets and mappings should not be committed to public repositories.

## Related Projects

- [UAssetGUI](https://github.com/atenfyr/UAssetGUI)
- [UAssetAPI](https://github.com/atenfyr/UAssetAPI)
