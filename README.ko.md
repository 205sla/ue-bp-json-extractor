# UE Blueprint JSON Extractor

[English](README.md)

Unreal Engine Blueprint 및 map asset(`.uasset` / `.umap`)에서 AI가 읽기 쉬운 JSON 요약을 추출하기 위한 Codex skill과 보조 스크립트입니다.

이 프로젝트는 Blueprint graph를 완전히 복원한다고 주장하지 않습니다. 대신 UAssetGUI의 기존 `tojson` 결과를 안정적인 원천으로 사용하고, AI 도구가 더 쉽게 훑어볼 수 있는 작고 예측 가능한 요약/색인 JSON을 만듭니다.

## 추출 내용

AI 요약 JSON에는 다음 정보가 포함됩니다.

- Asset 경로와 엔진 버전
- 추출 상태: `ok`, `failed`, `partial`
- 실패 시 오류 정보
- NameMap, import, export, raw export 개수
- class 후보 이름
- object 이름
- package reference
- `/Script/...` reference
- `/Game/...` reference
- gameplay tag처럼 보이는 문자열
- K2 node 후보
- function 후보
- variable/property 후보
- raw export 요약: index, type, name, byte size

큰 raw byte blob은 기본적으로 제외됩니다. 명시적으로 요청한 경우에만 포함됩니다.

## 목적

UAssetGUI의 원본 JSON은 크고 노이즈가 많을 수 있습니다. AI 기반 리버스 엔지니어링, 감사, 검색, 문서화 작업에서는 중요한 이름과 참조가 먼저 드러나는 일관된 요약이 더 유용할 때가 많습니다.

이 도구는 read-only 추출을 위해 설계되었습니다. 원본 `.uasset` 또는 `.umap` 파일을 수정하지 않습니다.

## 요구 사항

- Windows PowerShell
- Python 3.10 이상
- 실행 가능한 UAssetGUI 바이너리
- asset에 맞는 Unreal Engine 버전 문자열, 예: `VER_UE5_5`

UAssetGUI는 외부 의존성입니다. 로컬 빌드나 release 바이너리를 사용할 수 있습니다.

## 저장소 구조

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

## 빠른 시작

단일 asset 추출:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\extract_bp_json.ps1 `
  "C:\Project\Content\Blueprints\BP_Thing.uasset" `
  "C:\tmp\bp-json\BP_Thing.ai.json" `
  -EngineVersion VER_UE5_5 `
  -UAssetGUIPath "C:\Tools\UAssetGUI\UAssetGUI.exe"
```

폴더 단위 추출 및 manifest 생성:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\extract_bp_json.ps1 `
  "C:\Project\Content\Blueprints" `
  "C:\tmp\bp-json" `
  -EngineVersion VER_UE5_5 `
  -UAssetGUIPath "C:\Tools\UAssetGUI\UAssetGUI.exe" `
  -ManifestPath "C:\tmp\bp-json\manifest.json"
```

이미 존재하는 UAssetGUI JSON export 정규화:

```bash
python scripts/summarize_uasset_json.py \
  --input raw.uassetgui.json \
  --output asset.ai.json \
  --asset-path BP_Thing.uasset \
  --engine-version VER_UE5_5
```

## 실패 처리

일부 asset은 엔진 버전 불일치, mapping 문제, 지원되지 않는 serialization, 잠긴 파일, UAssetAPI 예외 등으로 parsing에 실패할 수 있습니다.

wrapper는 batch 추출 전체가 죽지 않게 유지합니다. 실패한 asset에 대해서는 다음과 같은 JSON을 남깁니다.

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

## 설정 격리

UAssetGUI는 사용자 profile 폴더 아래의 설정 및 mapping 파일을 읽거나 쓸 수 있습니다. PowerShell wrapper는 흔한 권한 문제와 profile 충돌을 줄이기 위해 다음 방식을 사용합니다.

- 가능하면 portable mode 사용
- `LOCALAPPDATA`와 `APPDATA`를 출력 폴더 아래로 격리
- 인자와 환경변수를 안정적으로 전달하기 위해 PowerShell `Start-Process` 대신 `.NET ProcessStartInfo` 사용

## Codex Skill 사용

이 저장소는 Codex skill 구조로 되어 있습니다. Codex가 local skill을 읽을 수 있는 위치에 폴더를 두거나, 경로를 명시해서 사용하면 됩니다.

이 skill은 Codex에게 다음 작업 방식을 알려줍니다.

- UAssetGUI를 read-only 추출 모드로 안전하게 실행
- UAssetGUI 원본 JSON 정규화
- 거대한 raw JSON blob보다 작은 AI 요약 우선 사용
- batch 추출 시 manifest를 먼저 확인
- private game asset 또는 생성된 추출 결과를 public repo에 commit하지 않기

## 출력 Schema

필드 계약은 [references/ai-json-schema.md](references/ai-json-schema.md)를 참고하세요.

## 한계

- 완전한 Blueprint graph decompiler가 아닙니다.
- 후보 필드는 heuristic index이며, 의미론적으로 항상 확정된 사실은 아닙니다.
- 결과는 asset 및 engine version에 대한 UAssetGUI/UAssetAPI 지원 수준에 의존합니다.
- proprietary asset과 mapping 파일은 public repository에 commit하지 않는 것이 좋습니다.

## 관련 프로젝트

- [UAssetGUI](https://github.com/atenfyr/UAssetGUI)
- [UAssetAPI](https://github.com/atenfyr/UAssetAPI)
