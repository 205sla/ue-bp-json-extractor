# UE Asset JSON Extractor

[Korean](README.ko.md)

AI agent skill and helper scripts for extracting AI-readable JSON summaries from Unreal Engine assets (`.uasset` / `.umap`), including Blueprints, maps, widgets, behavior trees, data tables, materials, meshes, and textures when UAssetGUI can parse them. Works with both **Codex** and **Claude Code** as a local skill (the `SKILL.md` format is shared between the two), and the helper scripts can be invoked directly without any agent.

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
- Compact graph node class counts when UAssetGUI exposes K2 node exports
- Raw export summaries with index, type, name, and byte size

Raw byte blobs are excluded by default. They are included only when explicitly requested with `-IncludeRaw`.

## Requirements

- Windows PowerShell
- Python 3.10+
- A working UAssetGUI executable
- Unreal Engine version string for the asset, for example `VER_UE5_5`

UAssetGUI is an external dependency, but this repository can prepare a workspace-local copy under the ignored `tools/` folder. You can also use an existing local build or release binary by passing `-UAssetGUIPath` or setting `UASSETGUI_PATH`.

For `.uproject` files with `EngineAssociation` values like `5.4` or `5.5`, use UAssetGUI engine versions `VER_UE5_4` or `VER_UE5_5`.

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
    |-- package_skill.ps1
    |-- scan_uasset_strings.py
    |-- setup_uassetgui.ps1
    `-- summarize_uasset_json.py
```

## Prepare UAssetGUI

To avoid depending on a hard-coded machine path such as `C:\Users\young\Tools\UAssetGUI`, prepare a local copy:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\setup_uassetgui.ps1 -DownloadRelease
```

The setup script downloads a pinned upstream release, extracts `UAssetGUI.exe` and companion files into `tools/uassetgui-bin`, writes `VERSION.txt` and `SHA256SUMS.txt`, and attempts to include upstream `LICENSE`/`NOTICE.md`. The `tools/` folder is git-ignored. The extractor automatically looks there before falling back to `UASSETGUI_PATH` or a `UAssetGUI.exe` on `PATH`.

The default pinned release is `v1.1.0`. Override it with `-ReleaseTag` if you need a different upstream release:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\setup_uassetgui.ps1 -DownloadRelease -ReleaseTag v1.1.0
```

To build from source instead of downloading a release, run:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\setup_uassetgui.ps1
```

The source build path clones [atenfyr/UAssetGUI](https://github.com/atenfyr/UAssetGUI), initializes submodules, and publishes `UAssetGUI.exe` into `tools/uassetgui-bin`. It requires `git` and a .NET SDK capable of building `net8.0-windows`.

## Quick Start

Extract one asset:

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

Extract a folder and write a manifest:

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

Known failure categories include `OutputPermissionDenied`, `AppDataPermissionDenied`, `UAssetGUITimeout`, `GuidParseFailed`, `IndexOutOfRangeParseFailed`, `NegativeCountParseFailed`, `NoRawJsonProduced`, `UAssetGUIParseFailed`, `SummarizerFailed`, and `MalformedSummaryJson`.

`NoRawJsonProduced` means UAssetGUI exited successfully but left no non-empty raw JSON file. In sandboxed Windows runs, retry the same command with elevated permissions. Do not inspect the Windows clipboard for hidden exception text unless the user explicitly authorizes it.

Unless `-NoStringFallback` is supplied, failed assets also get a `*.strings.json` fallback inventory. This file is a lossy ASCII identifier scan of the original binary asset. It can reveal names, function candidates, node class strings, and references when UAssetGUI cannot parse the package, but it is not graph topology.

## Config Isolation

UAssetGUI may read or write configuration and mappings under user profile folders. The PowerShell wrapper avoids common permission and profile-collision problems by:

- Defaulting to non-portable execution with explicit output/appdata roots
- Isolating `LOCALAPPDATA` and `APPDATA` under the output directory
- Supporting `-Portable` only when writing a `Data` folder beside the executable is acceptable
- Using `.NET ProcessStartInfo` instead of PowerShell `Start-Process` for predictable argument and environment handling

Some UAssetGUI builds still resolve the real user AppData folder internally. For Codex/sandboxed runs, keep `OutputPath`, `ManifestPath`, and `AppDataRoot` under the current workspace. If the child process reports `AppDataPermissionDenied`, retry the same command with elevated permissions rather than changing the source assets.

## Skill Usage

The repository ships a `SKILL.md` that both **Codex** and **Claude Code** can load as a local skill. Put the folder where the agent discovers skills, or invoke it explicitly by path.

The skill teaches an AI agent to:

- Run UAssetGUI safely in read-only extraction mode
- Normalize raw UAssetGUI JSON
- Prefer compact AI summaries over huge raw JSON blobs
- Inspect manifest files first during batch extraction
- Use fallback string inventories when full parsing fails
- Avoid committing private game assets or generated extraction output

### Claude Code

Claude Code discovers skills from any directory containing `SKILL.md` under `~/.claude/skills/` (personal) or `.claude/skills/` (project).

Personal install (Windows PowerShell):

```powershell
New-Item -ItemType Directory -Force -Path "$env:USERPROFILE\.claude\skills" | Out-Null
Copy-Item -Recurse -Force . "$env:USERPROFILE\.claude\skills\ue-bp-json-extractor"
```

Project install (Windows PowerShell):

```powershell
New-Item -ItemType Directory -Force -Path ".claude\skills" | Out-Null
Copy-Item -Recurse -Force . ".claude\skills\ue-bp-json-extractor"
```

Personal install (macOS / Linux / WSL):

```bash
mkdir -p "$HOME/.claude/skills"
cp -R . "$HOME/.claude/skills/ue-bp-json-extractor"
```

For a clean Claude Code package that excludes Codex-only metadata, repo docs, `tools/`, notes, and generated output:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\package_skill.ps1 -Target claude-code -Zip -Force
```

Install the generated `dist/ue-bp-json-extractor-claude-code/ue-bp-json-extractor` folder into `~/.claude/skills/` or `.claude/skills/`.

Platform notes for Claude Code:

- **Claude Code for Windows** runs the PowerShell wrapper directly and gets full UAssetGUI extraction.
- **Claude Code on macOS / Linux / WSL** uses the Python summarizer/string scanner (cross-platform), but cannot execute `UAssetGUI.exe` without a Windows bridge. Run the PowerShell wrapper on a Windows machine and share the raw JSON or output folder back to the macOS/Linux/WSL session, then point `summarize_uasset_json.py` at the raw JSON.

### Codex

Place the folder where Codex loads local skills, or invoke it by path. The `agents/openai.yaml` file provides the Codex display name and default prompt. The packager preserves it under `-Target codex`.

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\package_skill.ps1 -Target codex -Zip -Force
```

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
