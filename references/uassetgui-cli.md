# UAssetGUI CLI Notes

UAssetGUI upstream CLI:

```text
UAssetGUI tojson <source> <destination> <engine version> [mappings name]
UAssetGUI fromjson <source> <destination> [mappings name]
UAssetGUI portable
```

Some local/forked UAssetGUI builds may add:

```text
UAssetGUI toaijson <source> <destination> <engine version> [mappings name] [--include-raw] [--raw-json <destination>]
```

`toaijson` is optional. When available, it should preserve `tojson/fromjson` behavior and only add a new command. The skill does not require it because the wrapper can call upstream `tojson` and normalize the result.

Use `scripts/extract_bp_json.ps1` when:

- You need batch extraction.
- You want a manifest.
- You are using an upstream UAssetGUI binary that does not have `toaijson`.
- You need config isolation through `LOCALAPPDATA` and `APPDATA`.

The wrapper attempts portable mode when the UAssetGUI executable directory is writable. If not, it falls back to isolated app data folders under the output directory. It uses `.NET ProcessStartInfo` rather than PowerShell `Start-Process` so arguments and environment variables are passed predictably.

Mappings names are passed through to UAssetGUI. Keep private game assets and proprietary mappings out of public commits.
