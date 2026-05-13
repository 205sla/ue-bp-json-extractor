# AI Summary JSON Schema

The summary JSON is a lossy index over UAssetGUI `tojson` output. It does not reconstruct a complete Blueprint graph. It highlights stable structures and likely references that are useful for AI inspection.

Required top-level fields:

```json
{
  "schema_version": "ue-bp-ai-json-v1",
  "asset_path": "C:/Project/Content/BP_Thing.uasset",
  "engine_version": "VER_UE5_5",
  "status": "ok",
  "error": null,
  "string_inventory_json": null,
  "name_map_count": 0,
  "imports_count": 0,
  "exports_count": 0,
  "raw_exports_count": 0,
  "classes": [],
  "object_names": [],
  "package_refs": [],
  "script_refs": [],
  "game_refs": [],
  "gameplay_tags": [],
  "k2_node_candidates": [],
  "function_candidates": [],
  "variable_candidates": [],
  "raw_export_summaries": []
}
```

Status values:

- `ok`: UAssetGUI produced raw JSON and the summary was generated.
- `failed`: extraction or summarization failed; inspect `error`.
- `partial`: reserved for future cases where raw JSON is available but some summary sections are incomplete.

Failure error object:

```json
{
  "category": "UAssetGUIParseFailed",
  "type": "UAssetGUI.ToJsonFailed",
  "message": "UAssetGUI tojson did not produce a readable JSON file.",
  "stack": "..."
}
```

Known categories:

- `OutputPermissionDenied`: the output root, raw JSON root, or manifest destination was not writable.
- `AppDataPermissionDenied`: the configured UAssetGUI appdata root was not writable.
- `UAssetGUITimeout`: UAssetGUI exceeded the configured per-asset timeout.
- `GuidParseFailed`: UAssetGUI/UAssetAPI reported a GUID parsing failure.
- `IndexOutOfRangeParseFailed`: UAssetGUI/UAssetAPI reported an index/range failure.
- `NegativeCountParseFailed`: UAssetGUI/UAssetAPI reported a negative count/length failure.
- `UAssetGUIParseFailed`: UAssetGUI did not produce a readable raw JSON export.
- `SummarizerFailed`: the Python summarizer failed while reading or writing summary JSON.
- `MalformedSummaryJson`: a summary file existed but could not be parsed back as JSON for the manifest.

Fallback inventory:

- `string_inventory_json`: optional path to a `ue-bp-string-inventory-v1` JSON file generated from an ASCII scan of the original `.uasset`/`.umap` when UAssetGUI or summarization fails. This is a lossy fallback and should not be treated as graph topology.

Reference fields:

- `classes`: class-like names from imports, export type names, and NameMap candidates.
- `object_names`: import/export object names and object-like NameMap entries.
- `package_refs`: Unreal package/object paths, including `/Game/...` and `/Script/...`.
- `script_refs`: package refs under `/Script/`.
- `game_refs`: package refs under `/Game/`.
- `gameplay_tags`: dotted gameplay-tag-like strings.
- `k2_node_candidates`: strings that look like Blueprint graph node names or K2 node classes.
- `function_candidates`: function-like names, including UFunction exports and `ExecuteUbergraph`/`K2_` names.
- `variable_candidates`: property-like or variable-like names.

Raw exports:

Each `raw_export_summaries` item includes:

```json
{
  "index": 1,
  "type": "RawExport",
  "name": "SomeExport",
  "byte_size": 1234,
  "has_raw_data": true
}
```

Raw byte blobs are excluded by default. Use `--include-raw` or `-IncludeRaw` only when the caller explicitly needs them.

Manifest JSON:

```json
{
  "metadata": {
    "skill_path": "C:/path/to/ue-bp-json-extractor",
    "script_path": "C:/path/to/scripts/extract_bp_json.ps1",
    "uassetgui_path": "C:/Tools/UAssetGUI/UAssetGUI.exe",
    "engine_version": "VER_UE5_5",
    "output_root": "C:/Project/bp_asset_analysis_20260513_topic",
    "manifest_path": "C:/Project/bp_asset_analysis_20260513_topic/manifest.json",
    "appdata_root": "C:/Project/bp_asset_analysis_20260513_topic/.uassetgui-appdata",
    "portable": false,
    "no_portable": true,
    "keep_raw_json": true,
    "include_raw": false,
    "timeout_seconds": 120,
    "string_fallback": true,
    "string_fallback_limit": 500,
    "command_timestamp": "2026-05-13T00:00:00.0000000Z"
  },
  "entries": [
    {
      "asset_path": "C:/Project/Content/BP_Thing.uasset",
      "summary_json": "C:/Project/bp_asset_analysis_20260513_topic/BP_Thing.hash.ai.json",
      "raw_json": "C:/Project/bp_asset_analysis_20260513_topic/raw-json/BP_Thing.hash.uassetgui.json",
      "string_inventory_json": null,
      "status": "ok",
      "error_category": null,
      "error_message": null
    }
  ]
}
```

For JSONL manifests, each line is one entry and repeats `command_metadata` for reproducibility.

The wrapper rewrites the manifest after each processed asset, so a long batch should still leave partial progress if it is interrupted.

String inventory JSON:

```json
{
  "schema_version": "ue-bp-string-inventory-v1",
  "asset_path": "C:/Project/Content/BP_Broken.uasset",
  "status": "ok",
  "error": null,
  "strings_count": 12,
  "strings": [],
  "top_strings": [
    { "value": "/Game/Blueprints/BP_Thing", "count": 1 }
  ],
  "package_refs": [],
  "script_refs": [],
  "game_refs": [],
  "gameplay_tags": [],
  "class_candidates": [],
  "k2_node_candidates": [],
  "function_candidates": [],
  "variable_candidates": []
}
```

This fallback scans readable ASCII-like identifiers directly from the binary asset. It can reveal names and references when UAssetGUI cannot parse the package, but it does not prove object ownership, graph edges, pin connections, or property values.
