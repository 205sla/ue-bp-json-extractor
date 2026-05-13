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
- You want per-asset timeout protection with `-TimeoutSeconds`.
- You want fallback `*.strings.json` identifier inventories for assets that UAssetGUI cannot parse.

The wrapper defaults to non-portable execution and explicit output/appdata roots. Use `-NoPortable` in analysis commands for readability and backward compatibility. Use `-Portable` only when the UAssetGUI executable directory is writable and a `Data` folder beside the executable is acceptable.

UAssetGUI resolution order:

1. Explicit `-UAssetGUIPath`.
2. `UASSETGUI_PATH`.
3. `tools/uassetgui-bin/UAssetGUI.exe` inside the skill folder.
4. `tools/UAssetGUI/UAssetGUI.exe` inside the skill folder.
5. A `UAssetGUI.exe` found on `PATH`.

Use `scripts/setup_uassetgui.ps1 -DownloadRelease` to download a pinned upstream UAssetGUI release into `tools/uassetgui-bin`. It records `VERSION.txt`, `SHA256SUMS.txt`, and upstream license/notice files when available.

Use `scripts/setup_uassetgui.ps1` without `-DownloadRelease` to clone/build upstream UAssetGUI from source. The `tools/` directory is intentionally git-ignored because it may contain upstream source, binaries, NuGet restore output, and local build artifacts.

For sandboxed Codex runs, keep the output root, manifest, raw JSON directory, and appdata root under the current workspace. The wrapper runs a preflight write test for those directories and reports `OutputPermissionDenied` or `AppDataPermissionDenied` when setup fails.

Some UAssetGUI builds resolve the real user AppData folder internally even when `LOCALAPPDATA` and `APPDATA` are overridden for the child process. If child stderr contains an AppData or mappings `UnauthorizedAccessException`, the wrapper classifies it as `AppDataPermissionDenied`; retry the same command with escalation.

It uses `.NET ProcessStartInfo` rather than PowerShell `Start-Process` so arguments and environment variables are passed predictably.

When parsing fails, the wrapper classifies common UAssetAPI failure shapes such as GUID byte-length errors, index/range errors, negative count errors, and timeout. Unless `-NoStringFallback` is supplied, it also runs `scripts/scan_uasset_strings.py` against the original asset and records the resulting `string_inventory_json` path in both the failed summary and manifest entry.

Mappings names are passed through to UAssetGUI. Keep private game assets and proprietary mappings out of public commits.
