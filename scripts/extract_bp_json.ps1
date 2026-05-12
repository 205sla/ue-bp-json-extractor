[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$InputPath,

    [Parameter(Position = 1)]
    [string]$OutputPath,

    [Parameter(Mandatory = $true)]
    [string]$EngineVersion,

    [string]$UAssetGUIPath = "UAssetGUI.exe",
    [string]$MappingsName,
    [string]$Python = "python",
    [string]$RawJsonPath,
    [string]$ManifestPath,
    [string]$AppDataRoot,
    [switch]$KeepRawJson,
    [switch]$IncludeRaw,
    [switch]$ManifestJsonl,
    [switch]$NoPortable,
    [switch]$NoIsolateAppData
)

$ErrorActionPreference = "Stop"

function Resolve-Executable {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (Test-Path -LiteralPath $Path) {
        return (Resolve-Path -LiteralPath $Path).Path
    }

    $command = Get-Command $Path -ErrorAction Stop
    return $command.Source
}

function Get-AssetFiles {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $extension = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
        if ($extension -ne ".uasset" -and $extension -ne ".umap") {
            throw "Input file must be a .uasset or .umap: $Path"
        }
        return @((Resolve-Path -LiteralPath $Path).Path)
    }

    if (Test-Path -LiteralPath $Path -PathType Container) {
        return @(Get-ChildItem -LiteralPath $Path -Recurse -File |
            Where-Object { $_.Extension -in @(".uasset", ".umap") } |
            ForEach-Object { $_.FullName })
    }

    throw "Input path does not exist: $Path"
}

function Get-StableOutputName {
    param([Parameter(Mandatory = $true)][string]$AssetPath)

    $name = [System.IO.Path]::GetFileNameWithoutExtension($AssetPath)
    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes((Resolve-Path -LiteralPath $AssetPath).Path)
        $hash = [System.BitConverter]::ToString($sha1.ComputeHash($bytes)).Replace("-", "").Substring(0, 8).ToLowerInvariant()
    }
    finally {
        $sha1.Dispose()
    }

    $safeName = [regex]::Replace($name, "[^A-Za-z0-9_.-]+", "_")
    return "$safeName.$hash.ai.json"
}

function Invoke-ProcessCaptured {
    param(
        [Parameter(Mandatory = $true)][string]$FileName,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [hashtable]$EnvironmentOverrides
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FileName
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    if ($null -ne $psi.ArgumentList) {
        foreach ($arg in $Arguments) {
            [void]$psi.ArgumentList.Add($arg)
        }
    }
    else {
        $psi.Arguments = Join-ProcessArguments $Arguments
    }
    if ($EnvironmentOverrides) {
        $targetEnvironment = $psi.Environment
        if ($null -eq $targetEnvironment) {
            $targetEnvironment = $psi.EnvironmentVariables
        }
        foreach ($key in $EnvironmentOverrides.Keys) {
            $targetEnvironment[$key] = [string]$EnvironmentOverrides[$key]
        }
    }

    $process = [System.Diagnostics.Process]::Start($psi)
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    [pscustomobject]@{
        ExitCode = $process.ExitCode
        StdOut = $stdout
        StdErr = $stderr
    }
}

function ConvertTo-ProcessArgument {
    param([AllowNull()][string]$Argument)

    if ($null -eq $Argument) {
        return '""'
    }
    if ($Argument -notmatch '[\s"]') {
        return $Argument
    }

    $escaped = $Argument -replace '"', '\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function Join-ProcessArguments {
    param([string[]]$Arguments)

    return (($Arguments | ForEach-Object { ConvertTo-ProcessArgument $_ }) -join " ")
}

function Write-FailedSummary {
    param(
        [Parameter(Mandatory = $true)][string]$SummaryPath,
        [Parameter(Mandatory = $true)][string]$AssetPath,
        [Parameter(Mandatory = $true)][string]$ErrorType,
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$Stack
    )

    $summary = [ordered]@{
        schema_version = "ue-bp-ai-json-v1"
        asset_path = (Resolve-Path -LiteralPath $AssetPath).Path
        engine_version = $EngineVersion
        status = "failed"
        error = [ordered]@{
            type = $ErrorType
            message = $Message
            stack = $Stack
        }
        name_map_count = 0
        imports_count = 0
        exports_count = 0
        raw_exports_count = 0
        classes = @()
        object_names = @()
        package_refs = @()
        script_refs = @()
        game_refs = @()
        gameplay_tags = @()
        k2_node_candidates = @()
        function_candidates = @()
        variable_candidates = @()
        raw_export_summaries = @()
    }
    $parent = Split-Path -Parent $SummaryPath
    if ($parent) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    $summary | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $SummaryPath -Encoding UTF8
}

function Invoke-Summarizer {
    param(
        [Parameter(Mandatory = $true)][string]$PythonPath,
        [Parameter(Mandatory = $true)][string]$RawPath,
        [Parameter(Mandatory = $true)][string]$SummaryPath,
        [Parameter(Mandatory = $true)][string]$AssetPath
    )

    $scriptPath = Join-Path $PSScriptRoot "summarize_uasset_json.py"
    $arguments = @(
        $scriptPath,
        "--input", $RawPath,
        "--output", $SummaryPath,
        "--asset-path", $AssetPath,
        "--engine-version", $EngineVersion
    )
    if ($IncludeRaw) {
        $arguments += "--include-raw"
    }
    return Invoke-ProcessCaptured -FileName $PythonPath -Arguments $arguments
}

$resolvedUAssetGUI = Resolve-Executable $UAssetGUIPath
$resolvedPython = Resolve-Executable $Python
$usePortable = -not $NoPortable
if ($usePortable) {
    try {
        $exeDir = Split-Path -Parent $resolvedUAssetGUI
        if ($exeDir) {
            New-Item -ItemType Directory -Force -Path (Join-Path $exeDir "Data") | Out-Null
        }
    }
    catch {
        Write-Verbose "Portable mode is not writable beside UAssetGUI.exe; falling back to isolated APPDATA."
        $usePortable = $false
    }
}
$assets = Get-AssetFiles $InputPath
if ($assets.Count -eq 0) {
    throw "No .uasset or .umap files found under: $InputPath"
}

$isBatch = $assets.Count -gt 1 -or (Test-Path -LiteralPath $InputPath -PathType Container)
if (-not $OutputPath) {
    $OutputPath = Join-Path (Get-Location).Path "ai-json"
}

if ($isBatch) {
    $outputRoot = $OutputPath
}
else {
    $outputExtension = [System.IO.Path]::GetExtension($OutputPath).ToLowerInvariant()
    if ($outputExtension -eq ".json") {
        $outputRoot = Split-Path -Parent $OutputPath
    }
    else {
        $outputRoot = $OutputPath
    }
}
if (-not $outputRoot) {
    $outputRoot = (Get-Location).Path
}
New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null

if (-not $AppDataRoot) {
    $AppDataRoot = Join-Path $outputRoot ".uassetgui-appdata"
}
if (-not $NoIsolateAppData) {
    New-Item -ItemType Directory -Force -Path $AppDataRoot | Out-Null
}

$rawRoot = if ($KeepRawJson) { Join-Path $outputRoot "raw-json" } else { Join-Path $outputRoot ".tmp-raw-json" }
New-Item -ItemType Directory -Force -Path $rawRoot | Out-Null

$manifest = New-Object System.Collections.Generic.List[object]

foreach ($asset in $assets) {
    $summaryPath = $null
    if (-not $isBatch -and [System.IO.Path]::GetExtension($OutputPath).ToLowerInvariant() -eq ".json") {
        $summaryPath = $OutputPath
    }
    else {
        $summaryPath = Join-Path $outputRoot (Get-StableOutputName $asset)
    }

    if ($RawJsonPath -and -not $isBatch) {
        $rawPath = $RawJsonPath
    }
    else {
        $rawPath = Join-Path $rawRoot ((Get-StableOutputName $asset) -replace "\.ai\.json$", ".uassetgui.json")
    }

    $rawParent = Split-Path -Parent $rawPath
    if ($rawParent) {
        New-Item -ItemType Directory -Force -Path $rawParent | Out-Null
    }

    $uassetArgs = @()
    if ($usePortable) {
        $uassetArgs += "portable"
    }
    $uassetArgs += @("tojson", $asset, $rawPath, $EngineVersion)
    if ($MappingsName) {
        $uassetArgs += $MappingsName
    }

    $envOverrides = @{}
    if (-not $NoIsolateAppData) {
        $localAppData = Join-Path $AppDataRoot "Local"
        $roamingAppData = Join-Path $AppDataRoot "Roaming"
        New-Item -ItemType Directory -Force -Path $localAppData | Out-Null
        New-Item -ItemType Directory -Force -Path $roamingAppData | Out-Null
        $envOverrides["LOCALAPPDATA"] = $localAppData
        $envOverrides["APPDATA"] = $roamingAppData
    }

    try {
        $toJsonResult = Invoke-ProcessCaptured -FileName $resolvedUAssetGUI -Arguments $uassetArgs -EnvironmentOverrides $envOverrides
        $rawExists = Test-Path -LiteralPath $rawPath -PathType Leaf
        $rawHasContent = $false
        if ($rawExists) {
            $rawHasContent = (Get-Item -LiteralPath $rawPath).Length -gt 0
        }

        if ($toJsonResult.ExitCode -eq 0 -and $rawHasContent) {
            $summarizeResult = Invoke-Summarizer -PythonPath $resolvedPython -RawPath $rawPath -SummaryPath $summaryPath -AssetPath $asset
            if ($summarizeResult.ExitCode -ne 0 -and -not (Test-Path -LiteralPath $summaryPath -PathType Leaf)) {
                Write-FailedSummary -SummaryPath $summaryPath -AssetPath $asset -ErrorType "SummarizerFailed" -Message "summarize_uasset_json.py failed." -Stack ($summarizeResult.StdErr + $summarizeResult.StdOut)
            }
        }
        else {
            $message = "UAssetGUI tojson did not produce a readable JSON file."
            $stack = "exit_code=$($toJsonResult.ExitCode)`nstdout=$($toJsonResult.StdOut)`nstderr=$($toJsonResult.StdErr)"
            Write-FailedSummary -SummaryPath $summaryPath -AssetPath $asset -ErrorType "UAssetGUI.ToJsonFailed" -Message $message -Stack $stack
        }
    }
    catch {
        Write-FailedSummary -SummaryPath $summaryPath -AssetPath $asset -ErrorType $_.Exception.GetType().FullName -Message $_.Exception.Message -Stack $_.ScriptStackTrace
    }

    $summaryStatus = "unknown"
    $errorMessage = $null
    try {
        $summary = Get-Content -Raw -LiteralPath $summaryPath | ConvertFrom-Json
        $summaryStatus = $summary.status
        if ($summary.error) {
            $errorMessage = $summary.error.message
        }
    }
    catch {
        $summaryStatus = "failed"
        $errorMessage = "Could not read summary JSON."
    }

    $manifest.Add([pscustomobject]@{
        asset_path = (Resolve-Path -LiteralPath $asset).Path
        summary_json = (Resolve-Path -LiteralPath $summaryPath).Path
        raw_json = if ($KeepRawJson -and (Test-Path -LiteralPath $rawPath -PathType Leaf)) { (Resolve-Path -LiteralPath $rawPath).Path } else { $null }
        status = $summaryStatus
        error_message = $errorMessage
    }) | Out-Null
}

if (-not $KeepRawJson -and (Test-Path -LiteralPath $rawRoot -PathType Container)) {
    Get-ChildItem -LiteralPath $rawRoot -File | Remove-Item -Force
}

if (-not $ManifestPath) {
    $ManifestPath = if ($ManifestJsonl) { Join-Path $outputRoot "manifest.jsonl" } else { Join-Path $outputRoot "manifest.json" }
}

if ($ManifestJsonl) {
    $lines = foreach ($entry in $manifest) { $entry | ConvertTo-Json -Depth 20 -Compress }
    $lines | Set-Content -LiteralPath $ManifestPath -Encoding UTF8
}
else {
    $manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $ManifestPath -Encoding UTF8
}

$manifest
