#!/usr/bin/env python3
"""Create a compact AI-oriented summary from UAssetGUI tojson output."""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import sys
import traceback
from typing import Any, Iterable


MAX_LIST_ITEMS = 500
MAX_STRING_LENGTH = 512
MAX_STACK_LENGTH = 4000
RAW_PROPERTY_NAMES = {"data", "extras", "bulkdata", "rawdata"}


def empty_summary(asset_path: str, engine_version: str, status: str, error: dict[str, Any] | None) -> dict[str, Any]:
    return {
        "schema_version": "ue-bp-ai-json-v1",
        "asset_path": os.path.abspath(asset_path) if asset_path else None,
        "engine_version": engine_version,
        "status": status,
        "error": error,
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
        "raw_export_summaries": [],
    }


def error_object(error_type: str | None, message: str | None, stack: str | None) -> dict[str, Any] | None:
    if not error_type and not message and not stack:
        return None
    if stack and len(stack) > MAX_STACK_LENGTH:
        stack = stack[:MAX_STACK_LENGTH]
    return {"type": error_type, "message": message, "stack": stack}


def collect_strings(value: Any, out: set[str]) -> None:
    if isinstance(value, str):
        if value.strip() and len(value) <= MAX_STRING_LENGTH:
            out.add(value)
        return
    if isinstance(value, list):
        for item in value:
            collect_strings(item, out)
        return
    if isinstance(value, dict):
        for key, item in value.items():
            if key.lower() in RAW_PROPERTY_NAMES:
                continue
            collect_strings(item, out)


def get_array(root: dict[str, Any], key: str) -> list[Any]:
    value = root.get(key)
    return value if isinstance(value, list) else []


def get_string(entry: Any, key: str) -> str:
    if not isinstance(entry, dict):
        return ""
    value = entry.get(key)
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def short_type_name(type_name: str) -> str:
    if not type_name:
        return ""
    no_assembly = type_name.split(",", 1)[0].strip()
    return no_assembly.rsplit(".", 1)[-1]


def looks_like_object_name(value: str) -> bool:
    return bool(value and len(value) <= MAX_STRING_LENGTH and "/" not in value and "\\" not in value and " " not in value)


def normalize_unreal_ref(value: str) -> str:
    trimmed = (value or "").strip()
    first = trimmed.find("'")
    last = trimmed.rfind("'")
    if first >= 0 and last > first:
        trimmed = trimmed[first + 1:last]
    return trimmed


def is_package_ref(value: str) -> bool:
    if looks_like_comment(value):
        return False
    return bool(value and (value.startswith("/") or "/Game/" in value or "/Script/" in value))


_TAG_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)+$")


def looks_like_gameplay_tag(value: str) -> bool:
    if not value or len(value) > 128 or value.startswith("/") or "/" in value or " " in value:
        return False
    return bool(_TAG_RE.match(value))


def add_string_candidate(
    value: str,
    classes: set[str],
    k2_nodes: set[str],
    functions: set[str],
    variables: set[str],
) -> None:
    if not value:
        return
    if looks_like_comment(value):
        return
    lower = value.lower()
    if "k2node" in lower or value.startswith("K2_"):
        k2_nodes.add(value)
    if lower.endswith("class") or lower.endswith("blueprintgeneratedclass") or value.endswith("_C"):
        classes.add(value)
    if "function" in lower or lower.startswith("executeubergraph") or lower.startswith("ubergraph") or value.startswith("K2_"):
        functions.add(value)
    if "property" in lower or "variable" in lower or (len(value) > 1 and value.startswith("b") and value[1].isupper()):
        variables.add(value)


def looks_like_comment(value: str) -> bool:
    stripped = (value or "").lstrip()
    return stripped.startswith("/*") or stripped.startswith("//") or "\n" in value or "\r" in value


def add_name_map_candidates(
    name_map: Iterable[Any],
    object_names: set[str],
    classes: set[str],
    k2_nodes: set[str],
    functions: set[str],
    variables: set[str],
) -> None:
    for entry in name_map:
        value = entry if isinstance(entry, str) else json.dumps(entry, ensure_ascii=False, separators=(",", ":"))
        if not value:
            continue
        if looks_like_object_name(value):
            object_names.add(value)
        add_string_candidate(value, classes, k2_nodes, functions, variables)


def add_import_export_candidates(
    entries: Iterable[Any],
    object_names: set[str],
    classes: set[str],
    k2_nodes: set[str],
    functions: set[str],
    variables: set[str],
) -> None:
    for entry in entries:
        object_name = get_string(entry, "ObjectName")
        class_name = get_string(entry, "ClassName")
        type_name = short_type_name(get_string(entry, "$type"))
        for value in (object_name, class_name):
            if value:
                object_names.add(value) if value == object_name else classes.add(value)
        if type_name.endswith("Export"):
            classes.add(type_name[: -len("Export")])
        for value in (object_name, class_name, type_name):
            add_string_candidate(value, classes, k2_nodes, functions, variables)


def byte_size(data: Any, serial_size: Any) -> int:
    try:
        if serial_size is not None:
            return int(serial_size)
    except (TypeError, ValueError):
        pass
    if data is None:
        return 0
    if isinstance(data, list):
        return len(data)
    if isinstance(data, str):
        try:
            return len(base64.b64decode(data, validate=True))
        except Exception:
            return len(data)
    return 0


def raw_export_summaries(exports: Iterable[Any], include_raw: bool, treat_all_as_raw: bool = False) -> list[dict[str, Any]]:
    summaries: list[dict[str, Any]] = []
    for index, entry in enumerate(exports, start=1):
        if not isinstance(entry, dict):
            continue
        type_name = short_type_name(get_string(entry, "$type"))
        is_raw = treat_all_as_raw or type_name.lower() == "rawexport"
        if not is_raw:
            continue
        data = entry.get("Data")
        summary: dict[str, Any] = {
            "index": index,
            "type": type_name or "RawExport",
            "name": get_string(entry, "ObjectName"),
            "byte_size": byte_size(data, entry.get("SerialSize")),
            "has_raw_data": data is not None,
        }
        if include_raw and data is not None:
            summary["raw_data"] = data
        summaries.append(summary)
    return summaries


def limited(values: Iterable[str]) -> list[str]:
    return sorted(v for v in values if v)[:MAX_LIST_ITEMS]


def summarize(root: dict[str, Any], asset_path: str, engine_version: str, include_raw: bool) -> dict[str, Any]:
    name_map = get_array(root, "NameMap")
    imports = get_array(root, "Imports")
    exports = get_array(root, "Exports")
    top_raw_exports = get_array(root, "RawExports")

    all_strings: set[str] = set()
    collect_strings(root, all_strings)

    classes: set[str] = set()
    object_names: set[str] = set()
    k2_nodes: set[str] = set()
    functions: set[str] = set()
    variables: set[str] = set()

    add_name_map_candidates(name_map, object_names, classes, k2_nodes, functions, variables)
    add_import_export_candidates(imports, object_names, classes, k2_nodes, functions, variables)
    add_import_export_candidates(exports, object_names, classes, k2_nodes, functions, variables)
    for value in all_strings:
        add_string_candidate(value, classes, k2_nodes, functions, variables)

    package_refs: set[str] = set()
    script_refs: set[str] = set()
    game_refs: set[str] = set()
    gameplay_tags: set[str] = set()
    for value in all_strings:
        normalized = normalize_unreal_ref(value)
        if is_package_ref(normalized):
            package_refs.add(normalized)
            if normalized.lower().startswith("/script/"):
                script_refs.add(normalized)
            if normalized.lower().startswith("/game/"):
                game_refs.add(normalized)
        if looks_like_gameplay_tag(value):
            gameplay_tags.add(value)

    raw_summaries = raw_export_summaries(exports, include_raw) + raw_export_summaries(top_raw_exports, include_raw, True)

    summary = empty_summary(asset_path, engine_version, "ok", None)
    summary.update(
        {
            "name_map_count": len(name_map),
            "imports_count": len(imports),
            "exports_count": len(exports),
            "raw_exports_count": len(raw_summaries),
            "classes": limited(classes),
            "object_names": limited(object_names),
            "package_refs": limited(package_refs),
            "script_refs": limited(script_refs),
            "game_refs": limited(game_refs),
            "gameplay_tags": limited(gameplay_tags),
            "k2_node_candidates": limited(k2_nodes),
            "function_candidates": limited(functions),
            "variable_candidates": limited(variables),
            "raw_export_summaries": raw_summaries,
        }
    )
    return summary


def write_json(path: str, value: dict[str, Any]) -> None:
    parent = os.path.dirname(os.path.abspath(path))
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(value, handle, ensure_ascii=False, indent=2)
        handle.write("\n")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Summarize UAssetGUI JSON for AI-oriented inspection.")
    parser.add_argument("input_path", nargs="?", help="UAssetGUI tojson output path.")
    parser.add_argument("--input", dest="input_option", help="UAssetGUI tojson output path.")
    parser.add_argument("--output", required=True, help="Destination summary JSON path.")
    parser.add_argument("--asset-path", required=True, help="Original .uasset or .umap path.")
    parser.add_argument("--engine-version", required=True, help="Engine version passed to UAssetGUI, such as VER_UE5_5.")
    parser.add_argument("--include-raw", action="store_true", help="Include raw export blobs when present.")
    parser.add_argument("--failed", action="store_true", help="Write a failed summary without reading an input JSON.")
    parser.add_argument("--error-type", help="Failure exception type.")
    parser.add_argument("--error-message", help="Failure message.")
    parser.add_argument("--error-stack", help="Failure stack or captured process output.")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    input_path = args.input_option or args.input_path

    if args.failed:
        write_json(
            args.output,
            empty_summary(
                args.asset_path,
                args.engine_version,
                "failed",
                error_object(args.error_type, args.error_message, args.error_stack),
            ),
        )
        return 0

    if not input_path:
        write_json(
            args.output,
            empty_summary(
                args.asset_path,
                args.engine_version,
                "failed",
                error_object("ArgumentError", "No input JSON path was provided.", None),
            ),
        )
        return 2

    try:
        with open(input_path, "r", encoding="utf-8") as handle:
            root = json.load(handle)
        if not isinstance(root, dict):
            raise TypeError("Expected the UAssetGUI JSON root to be an object.")
        write_json(args.output, summarize(root, args.asset_path, args.engine_version, args.include_raw))
        return 0
    except Exception as exc:
        write_json(
            args.output,
            empty_summary(
                args.asset_path,
                args.engine_version,
                "failed",
                error_object(type(exc).__name__, str(exc), traceback.format_exc()),
            ),
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
