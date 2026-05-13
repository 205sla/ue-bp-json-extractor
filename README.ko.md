# UE Asset JSON Extractor

[English](README.md)

Unreal Engine 에셋(`.uasset` / `.umap`)에서 AI가 읽기 쉬운 JSON 요약을 추출하는 Codex skill과 보조 스크립트입니다. Blueprint뿐 아니라 UAssetGUI가 파싱할 수 있는 map, widget, behavior tree, data table, material, mesh, texture 같은 Unreal 전용 에셋 분석에도 사용할 수 있습니다.

이 프로젝트는 Blueprint graph를 완전히 복원한다고 주장하지 않습니다. UAssetGUI의 기존 `tojson` 결과를 안정적인 원천으로 사용하고, 그 위에서 AI가 훑어보기 좋은 요약/색인 JSON을 만듭니다. 추출은 read-only이며 원본 에셋 파일을 수정하지 않습니다.

## 추출 내용

AI 요약 JSON에는 다음 정보가 포함됩니다.

- 에셋 경로와 엔진 버전
- 추출 상태: `ok`, `failed`, `partial`
- 실패 시 오류 category와 메시지
- 실패 에셋용 fallback string inventory
- NameMap, import, export, raw export 개수
- class 후보와 object 이름
- package reference, `/Script/...`, `/Game/...` reference
- gameplay tag처럼 보이는 문자열
- K2 node, function, variable/property 후보
- raw export의 index, type, name, byte size 요약

raw byte blob은 기본적으로 제외합니다. 명시적으로 필요할 때만 `-IncludeRaw`를 사용합니다.

## 요구 사항

- Windows PowerShell
- Python 3.10 이상
- 실행 가능한 UAssetGUI 바이너리
- 에셋에 맞는 Unreal Engine 버전 문자열, 예: `VER_UE5_5`

UAssetGUI는 외부 의존성입니다. 기존 로컬 빌드나 release 바이너리를 사용할 수 있습니다.

## 저장소 구조

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

## 빠른 시작

단일 에셋 추출:

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

폴더 단위 추출과 manifest 생성:

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

이미 존재하는 UAssetGUI JSON export 정규화:

```bash
python scripts/summarize_uasset_json.py \
  --input raw.uassetgui.json \
  --output asset.ai.json \
  --asset-path BP_Thing.uasset \
  --engine-version VER_UE5_5
```

UAssetGUI 없이 실패 에셋의 식별자만 스캔:

```bash
python scripts/scan_uasset_strings.py BP_Thing.uasset --output BP_Thing.strings.json --limit 500
```

## 실패 처리

일부 에셋은 엔진 버전 불일치, mapping 문제, 지원되지 않는 serialization, 잠긴 파일, UAssetAPI 예외 때문에 파싱에 실패할 수 있습니다. wrapper는 배치 전체를 중단하지 않고 실패 summary JSON을 남깁니다.

실패 summary 예:

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

주요 실패 category는 `OutputPermissionDenied`, `AppDataPermissionDenied`, `UAssetGUITimeout`, `GuidParseFailed`, `IndexOutOfRangeParseFailed`, `NegativeCountParseFailed`, `UAssetGUIParseFailed`, `SummarizerFailed`, `MalformedSummaryJson`입니다.

`-NoStringFallback`을 지정하지 않으면 실패 에셋마다 `*.strings.json` fallback inventory를 생성합니다. 이 파일은 원본 바이너리 에셋에서 ASCII 식별자를 거칠게 스캔한 결과입니다. UAssetGUI가 패키지를 파싱하지 못할 때 이름과 reference를 찾는 데 도움이 되지만, graph topology는 아닙니다.

## 설정 격리

UAssetGUI는 사용자 profile 폴더 아래의 설정과 mapping 파일을 읽거나 쓸 수 있습니다. PowerShell wrapper는 권한 문제와 profile 충돌을 줄이기 위해 다음 방식을 사용합니다.

- 명시적인 output/appdata root를 사용하는 non-portable 실행을 기본으로 사용
- `LOCALAPPDATA`와 `APPDATA`를 출력 폴더 아래로 격리
- 실행 파일 옆 `Data` 폴더에 써도 되는 경우에만 `-Portable` 지원
- 인자와 환경변수 전달을 안정화하기 위해 PowerShell `Start-Process` 대신 `.NET ProcessStartInfo` 사용

일부 UAssetGUI 빌드는 환경변수를 덮어써도 실제 사용자 AppData를 내부적으로 참조할 수 있습니다. Codex/sandbox 실행에서는 `OutputPath`, `ManifestPath`, `AppDataRoot`를 현재 workspace 아래에 두세요. child process가 `AppDataPermissionDenied`를 보고하면 source asset을 바꾸지 말고 같은 명령을 escalated 권한으로 재시도합니다.

## Codex Skill 사용

이 저장소는 Codex skill 구조입니다. Codex가 로컬 skill로 읽을 수 있는 위치에 두거나, 경로를 명시해 사용할 수 있습니다.

이 skill은 Codex에게 다음 절차를 알려줍니다.

- UAssetGUI를 read-only 추출 모드로 안전하게 실행
- UAssetGUI raw JSON 정규화
- 큰 raw JSON blob보다 작은 AI 요약 우선 사용
- 배치 분석 시 manifest를 먼저 확인
- 전체 파싱 실패 시 fallback string inventory 확인
- private game asset이나 생성된 분석 결과를 public repository에 커밋하지 않기

## 출력 Schema

필드 계약은 [references/ai-json-schema.md](references/ai-json-schema.md)를 참고하세요.

JSON manifest에는 skill path, script path, UAssetGUI path, engine version, output root, appdata root, timeout, fallback 설정, option flag, command timestamp 같은 command metadata가 포함됩니다. wrapper는 asset마다 manifest를 갱신하므로 긴 배치가 중간에 멈춰도 partial progress가 남습니다. JSONL manifest는 각 entry에 metadata를 반복합니다.

## 한계

- 완전한 Blueprint graph decompiler가 아닙니다.
- 후보 필드는 heuristic index이며 의미론적으로 항상 확정된 사실은 아닙니다.
- 결과는 에셋과 엔진 버전에 대한 UAssetGUI/UAssetAPI 지원에 의존합니다.
- fallback string inventory는 식별자 탐색에는 유용하지만 graph edge, pin connection, ownership, property value를 증명하지 않습니다.
- graph topology나 pin wiring이 중요하면 이 요약을 색인으로만 사용하고, 필요한 function graph는 UE Editor의 `Copy as Text` export로 보완하세요.
- proprietary asset과 mapping 파일은 public repository에 커밋하지 않는 편이 안전합니다.

## 관련 프로젝트

- [UAssetGUI](https://github.com/atenfyr/UAssetGUI)
- [UAssetAPI](https://github.com/atenfyr/UAssetAPI)
