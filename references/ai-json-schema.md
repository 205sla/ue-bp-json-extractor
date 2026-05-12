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
