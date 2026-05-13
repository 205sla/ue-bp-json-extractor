#!/usr/bin/env python3
"""Extract a lightweight ASCII identifier inventory from Unreal asset binaries."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import traceback
from collections import Counter
from typing import Any


DEFAULT_LIMIT = 500
STRING_RE = re.compile(rb"[A-Za-z0-9_./:$'-]{4,}")
IDENTIFIER_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]{3,96}$")
INTERESTING_RE = re.compile(
    r"(/Game/|/Script/|BP_|WBP_|ABP_|BT_|BB_|GM_|DT_|M_|MI_|T_|SM_|SK_|K2Node|"
    r"Default__|Class|Function|Property|Gameplay|DataTable|Widget|Material)",
    re.IGNORECASE,
)
GAMEPLAY_TAG_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)+$")
FUNCTION_PREFIXES = ("On", "Receive", "Execute", "K2_", "Get", "Set", "Can", "Has", "Is")
USEFUL_SUFFIXES = (
    "Actor",
    "Asset",
    "Class",
    "Component",
    "Controller",
    "Count",
    "Data",
    "Index",
    "Material",
    "Mesh",
    "Mode",
    "Name",
    "State",
    "Table",
    "Tag",
    "Texture",
    "Widget",
)


def normalize_unreal_ref(value: str) -> str:
    trimmed = value.strip()
    first = trimmed.find("'")
    last = trimmed.rfind("'")
    if first >= 0 and last > first:
        return trimmed[first + 1:last]
    return trimmed


def limited_sorted(values: set[str], limit: int) -> list[str]:
    return sorted(values)[:limit]


def looks_useful_identifier(value: str) -> bool:
    if value.startswith(("UAssetAPI.", "System.", "Newtonsoft.")):
        return False
    if INTERESTING_RE.search(value) or GAMEPLAY_TAG_RE.match(value):
        return True
    if not IDENTIFIER_RE.match(value):
        return False
    if "_" in value or value.startswith(FUNCTION_PREFIXES):
        return True
    if len(value) > 1 and value.startswith("b") and value[1].isupper():
        return True
    return value.endswith(USEFUL_SUFFIXES)


def scan(path: str, limit: int) -> dict[str, Any]:
    with open(path, "rb") as handle:
        data = handle.read()

    strings: list[str] = []
    counts: Counter[str] = Counter()
    for match in STRING_RE.finditer(data):
        value = match.group().decode("ascii", errors="ignore")
        if not looks_useful_identifier(value):
            continue
        counts[value] += 1
        if value not in strings:
            strings.append(value)

    strings = strings[:limit]

    package_refs: set[str] = set()
    script_refs: set[str] = set()
    game_refs: set[str] = set()
    gameplay_tags: set[str] = set()
    class_candidates: set[str] = set()
    function_candidates: set[str] = set()
    variable_candidates: set[str] = set()
    k2_node_candidates: set[str] = set()

    for value in strings:
        normalized = normalize_unreal_ref(value)
        if normalized.startswith("/") or "/Game/" in normalized or "/Script/" in normalized:
            package_refs.add(normalized)
        if normalized.lower().startswith("/script/"):
            script_refs.add(normalized)
        if normalized.lower().startswith("/game/"):
            game_refs.add(normalized)
        if GAMEPLAY_TAG_RE.match(value) and "/" not in value and " " not in value:
            gameplay_tags.add(value)

        lower = value.lower()
        if "k2node" in lower or value.startswith("K2_"):
            k2_node_candidates.add(value)
        if lower.endswith("class") or lower.endswith("blueprintgeneratedclass") or value.endswith("_C"):
            class_candidates.add(value)
        if "function" in lower or lower.startswith("executeubergraph") or lower.startswith("ubergraph") or value.startswith("K2_"):
            function_candidates.add(value)
        if "property" in lower or "variable" in lower or (len(value) > 1 and value.startswith("b") and value[1].isupper()):
            variable_candidates.add(value)

    return {
        "schema_version": "ue-bp-string-inventory-v1",
        "asset_path": os.path.abspath(path),
        "status": "ok",
        "error": None,
        "strings_count": len(strings),
        "strings": strings,
        "top_strings": [
            {"value": value, "count": count}
            for value, count in counts.most_common(min(limit, 100))
        ],
        "package_refs": limited_sorted(package_refs, limit),
        "script_refs": limited_sorted(script_refs, limit),
        "game_refs": limited_sorted(game_refs, limit),
        "gameplay_tags": limited_sorted(gameplay_tags, limit),
        "class_candidates": limited_sorted(class_candidates, limit),
        "k2_node_candidates": limited_sorted(k2_node_candidates, limit),
        "function_candidates": limited_sorted(function_candidates, limit),
        "variable_candidates": limited_sorted(variable_candidates, limit),
    }


def write_json(path: str, value: dict[str, Any]) -> None:
    parent = os.path.dirname(os.path.abspath(path))
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(value, handle, ensure_ascii=False, indent=2)
        handle.write("\n")


def failed(path: str, error: BaseException) -> dict[str, Any]:
    return {
        "schema_version": "ue-bp-string-inventory-v1",
        "asset_path": os.path.abspath(path),
        "status": "failed",
        "error": {
            "type": type(error).__name__,
            "message": str(error),
            "stack": traceback.format_exc()[:4000],
        },
        "strings_count": 0,
        "strings": [],
        "top_strings": [],
        "package_refs": [],
        "script_refs": [],
        "game_refs": [],
        "gameplay_tags": [],
        "class_candidates": [],
        "k2_node_candidates": [],
        "function_candidates": [],
        "variable_candidates": [],
    }


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Extract ASCII identifiers from .uasset/.umap files.")
    parser.add_argument("asset_path", help="Source .uasset or .umap file.")
    parser.add_argument("--output", required=True, help="Destination inventory JSON path.")
    parser.add_argument("--limit", type=int, default=DEFAULT_LIMIT, help="Maximum strings per inventory section.")
    args = parser.parse_args(argv)

    try:
        write_json(args.output, scan(args.asset_path, max(1, args.limit)))
        return 0
    except Exception as exc:
        write_json(args.output, failed(args.asset_path, exc))
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
