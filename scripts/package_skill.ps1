[CmdletBinding()]
param(
    [ValidateSet("claude-code", "codex")]
    [string]$Target = "claude-code",

    [string]$OutputRoot,
    [switch]$Zip,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

function Assert-PathInside {
    param(
        [Parameter(Mandatory = $true)][string]$Child,
        [Parameter(Mandatory = $true)][string]$Parent
    )

    $childFull = [System.IO.Path]::GetFullPath($Child)
    $parentFull = [System.IO.Path]::GetFullPath($Parent)
    if (-not $parentFull.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $parentFull += [System.IO.Path]::DirectorySeparatorChar
    }
    if (-not $childFull.StartsWith($parentFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to write outside package output root: $childFull"
    }
}

function Copy-FileToPackage {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $parent = Split-Path -Parent $Destination
    if ($parent) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

$skillRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$skillName = "ue-bp-json-extractor"

if (-not $OutputRoot) {
    $OutputRoot = Join-Path $skillRoot "dist"
}
$OutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)

$packageName = "$skillName-$Target"
$packageRoot = Join-Path $OutputRoot $packageName
$skillPackageRoot = Join-Path $packageRoot $skillName

New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
Assert-PathInside -Child $packageRoot -Parent $OutputRoot

if (Test-Path -LiteralPath $packageRoot) {
    if (-not $Force) {
        throw "Package output already exists. Re-run with -Force to replace: $packageRoot"
    }
    Remove-Item -LiteralPath $packageRoot -Recurse -Force
}

New-Item -ItemType Directory -Force -Path $skillPackageRoot | Out-Null

Copy-FileToPackage -Source (Join-Path $skillRoot "SKILL.md") -Destination (Join-Path $skillPackageRoot "SKILL.md")

$scriptNames = @(
    "extract_bp_json.ps1",
    "setup_uassetgui.ps1",
    "summarize_uasset_json.py",
    "scan_uasset_strings.py"
)
foreach ($scriptName in $scriptNames) {
    Copy-FileToPackage -Source (Join-Path (Join-Path $skillRoot "scripts") $scriptName) -Destination (Join-Path (Join-Path $skillPackageRoot "scripts") $scriptName)
}

$referenceRoot = Join-Path $skillRoot "references"
Get-ChildItem -LiteralPath $referenceRoot -File | ForEach-Object {
    Copy-FileToPackage -Source $_.FullName -Destination (Join-Path (Join-Path $skillPackageRoot "references") $_.Name)
}

if ($Target -eq "codex") {
    $openAiYaml = Join-Path (Join-Path $skillRoot "agents") "openai.yaml"
    if (Test-Path -LiteralPath $openAiYaml -PathType Leaf) {
        Copy-FileToPackage -Source $openAiYaml -Destination (Join-Path (Join-Path $skillPackageRoot "agents") "openai.yaml")
    }
}

$zipPath = $null
if ($Zip) {
    $zipPath = Join-Path $OutputRoot "$packageName.zip"
    Assert-PathInside -Child $zipPath -Parent $OutputRoot
    if (Test-Path -LiteralPath $zipPath) {
        if (-not $Force) {
            throw "Package zip already exists. Re-run with -Force to replace: $zipPath"
        }
        Remove-Item -LiteralPath $zipPath -Force
    }
    Compress-Archive -LiteralPath $skillPackageRoot -DestinationPath $zipPath -Force
}

[ordered]@{
    target = $Target
    package_root = (Resolve-Path -LiteralPath $packageRoot).Path
    skill_root = (Resolve-Path -LiteralPath $skillPackageRoot).Path
    zip_path = if ($zipPath) { [System.IO.Path]::GetFullPath($zipPath) } else { $null }
    excluded = @("agents/openai.yaml for claude-code", "README*.md", "notes/", "tools/", "dist/", "bp_asset_analysis_*/", "old/")
} | ConvertTo-Json -Depth 5
