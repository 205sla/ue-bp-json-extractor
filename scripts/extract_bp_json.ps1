[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$InputPath,

    [Parameter(Position = 1)]
    [string]$OutputPath,

    [string]$OutputRoot,
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
    [switch]$Portable,
    [switch]$NoPortable,
    [switch]$NoIsolateAppData,
    [switch]$SkipPreflight,
    [int]$TimeoutSeconds = 0,
    [switch]$NoStringFallback,
    [int]$StringFallbackLimit = 500
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

function Resolve-UAssetGUIExecutable {
    param([string]$Path)

    $skillRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
    $candidates = New-Object System.Collections.Generic.List[string]

    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        $candidates.Add($Path)
    }
    if ($env:UASSETGUI_PATH) {
        $candidates.Add($env:UASSETGUI_PATH)
    }
    $candidates.Add((Join-Path $skillRoot "tools\uassetgui-bin\UAssetGUI.exe"))
    $candidates.Add((Join-Path $skillRoot "tools\UAssetGUI\UAssetGUI.exe"))
    $candidates.Add((Join-Path $skillRoot "tools\UAssetGUI-src\UAssetGUI\bin\Release\net8.0-windows\UAssetGUI.exe"))

    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    try {
        $command = Get-Command $Path -ErrorAction Stop
        return $command.Source
    }
    catch {
        throw "UAssetGUI executable was not found. Pass -UAssetGUIPath, set UASSETGUI_PATH, place UAssetGUI.exe under '$skillRoot\tools\uassetgui-bin', or run scripts\setup_uassetgui.ps1 to prepare a workspace-local copy."
    }
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
        [hashtable]$EnvironmentOverrides,
        [int]$TimeoutSeconds = 0
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
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $timedOut = $false

    if ($TimeoutSeconds -gt 0) {
        $waitMilliseconds = [Math]::Min(([int64]$TimeoutSeconds * [int64]1000), ([int64][int]::MaxValue))
        if (-not $process.WaitForExit([int]$waitMilliseconds)) {
            $timedOut = $true
            try {
                $process.Kill()
            }
            catch {
                # Process may already be gone.
            }
            try {
                [void]$process.WaitForExit(5000)
            }
            catch {
                # Ignore secondary wait failures after killing a hung child.
            }
        }
    }
    else {
        $process.WaitForExit()
    }

    try {
        [void]$stdoutTask.Wait(5000)
    }
    catch {
    }
    try {
        [void]$stderrTask.Wait(5000)
    }
    catch {
    }

    $stdout = if ($stdoutTask.IsCompleted) { $stdoutTask.Result } else { "" }
    $stderr = if ($stderrTask.IsCompleted) { $stderrTask.Result } else { "" }
    $exitCode = if ($timedOut) { -1 } else { $process.ExitCode }

    [pscustomobject]@{
        ExitCode = $exitCode
        StdOut = $stdout
        StdErr = $stderr
        TimedOut = $timedOut
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

function Get-UAssetGUIFailureCategory {
    param([string]$Text)

    if ($Text -match "TimedOut|timed out|timeout") {
        return "UAssetGUITimeout"
    }
    if ($Text -match "UnauthorizedAccessException" -and $Text -match "(AppData|UAssetGUI\\\\Mappings|Local\\\\UAssetGUI|Roaming\\\\UAssetGUI)") {
        return "AppDataPermissionDenied"
    }
    if ($Text -match "UnauthorizedAccessException|Access to the path") {
        return "OutputPermissionDenied"
    }
    if ($Text -match "Guid|Byte array for Guid") {
        return "GuidParseFailed"
    }
    if ($Text -match "Index was out of range|startIndex") {
        return "IndexOutOfRangeParseFailed"
    }
    if ($Text -match "non-negative|negative value|ThrowNegative|count '\-") {
        return "NegativeCountParseFailed"
    }
    return "UAssetGUIParseFailed"
}

function Write-Utf8NoBomFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Write-ManifestFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Entries,
        [Parameter(Mandatory = $true)]$Metadata,
        [bool]$AsJsonl
    )

    $parent = Split-Path -Parent $Path
    if ($parent) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    if ($AsJsonl) {
        $lines = foreach ($entry in $Entries) { $entry | ConvertTo-Json -Depth 20 -Compress }
        $content = ($lines -join [System.Environment]::NewLine)
        if ($content) {
            $content += [System.Environment]::NewLine
        }
        Write-Utf8NoBomFile -Path $Path -Content $content
        return
    }

    $content = [ordered]@{
        metadata = $Metadata
        entries = @($Entries)
    } | ConvertTo-Json -Depth 20
    Write-Utf8NoBomFile -Path $Path -Content ($content + [System.Environment]::NewLine)
}

function Test-WritableDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$Category
    )

    try {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
        $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
        $testPath = Join-Path $resolvedPath (".ue-bp-json-extractor-write-test-" + [System.Guid]::NewGuid().ToString("N") + ".tmp")
        Set-Content -LiteralPath $testPath -Value "write-test" -Encoding ASCII
        Remove-Item -LiteralPath $testPath -Force
        return $resolvedPath
    }
    catch {
        throw "$Category`: Cannot write $Label at '$Path'. $($_.Exception.Message)"
    }
}

function Write-FailedSummary {
    param(
        [Parameter(Mandatory = $true)][string]$SummaryPath,
        [Parameter(Mandatory = $true)][string]$AssetPath,
        [Parameter(Mandatory = $true)][string]$ErrorCategory,
        [Parameter(Mandatory = $true)][string]$ErrorType,
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$Stack,
        [string]$StringInventoryPath
    )

    $resolvedStringInventoryPath = $null
    if ($StringInventoryPath) {
        if (Test-Path -LiteralPath $StringInventoryPath -PathType Leaf) {
            $resolvedStringInventoryPath = (Resolve-Path -LiteralPath $StringInventoryPath).Path
        }
        else {
            $resolvedStringInventoryPath = [System.IO.Path]::GetFullPath($StringInventoryPath)
        }
    }

    $summary = [ordered]@{
        schema_version = "ue-bp-ai-json-v1"
        asset_path = (Resolve-Path -LiteralPath $AssetPath).Path
        engine_version = $EngineVersion
        status = "failed"
        error = [ordered]@{
            category = $ErrorCategory
            type = $ErrorType
            message = $Message
            stack = $Stack
        }
        string_inventory_json = $resolvedStringInventoryPath
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
        node_class_counts = @()
        function_candidates = @()
        variable_candidates = @()
        raw_export_summaries = @()
    }
    $parent = Split-Path -Parent $SummaryPath
    if ($parent) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    $content = $summary | ConvertTo-Json -Depth 20
    Write-Utf8NoBomFile -Path $SummaryPath -Content ($content + [System.Environment]::NewLine)
}

function Invoke-StringFallback {
    param(
        [Parameter(Mandatory = $true)][string]$PythonPath,
        [Parameter(Mandatory = $true)][string]$AssetPath,
        [Parameter(Mandatory = $true)][string]$InventoryPath
    )

    if ($NoStringFallback) {
        return $null
    }

    $scriptPath = Join-Path $PSScriptRoot "scan_uasset_strings.py"
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        Write-Warning "String fallback script not found: $scriptPath"
        return $null
    }

    $inventoryParent = Split-Path -Parent $InventoryPath
    if ($inventoryParent) {
        New-Item -ItemType Directory -Force -Path $inventoryParent | Out-Null
    }

    $arguments = @(
        $scriptPath,
        $AssetPath,
        "--output", $InventoryPath,
        "--limit", [string]$StringFallbackLimit
    )
    $scanResult = Invoke-ProcessCaptured -FileName $PythonPath -Arguments $arguments
    if (Test-Path -LiteralPath $InventoryPath -PathType Leaf) {
        return (Resolve-Path -LiteralPath $InventoryPath).Path
    }

    Write-Warning "String fallback did not produce JSON for '$AssetPath'. $($scanResult.StdErr)$($scanResult.StdOut)"
    return $null
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

$resolvedUAssetGUI = Resolve-UAssetGUIExecutable $UAssetGUIPath
$resolvedPython = Resolve-Executable $Python
$assets = Get-AssetFiles $InputPath
if ($assets.Count -eq 0) {
    throw "No .uasset or .umap files found under: $InputPath"
}
if ($TimeoutSeconds -lt 0) {
    throw "TimeoutSeconds must be 0 or greater."
}
if ($StringFallbackLimit -lt 1) {
    throw "StringFallbackLimit must be 1 or greater."
}

$isBatch = $assets.Count -gt 1 -or (Test-Path -LiteralPath $InputPath -PathType Container)
$usingOutputRoot = -not [string]::IsNullOrWhiteSpace($OutputRoot)
if ($OutputRoot) {
    $OutputPath = $OutputRoot
}
if (-not $OutputPath) {
    $OutputPath = Join-Path (Get-Location).Path "ai-json"
}

if ($usingOutputRoot) {
    $outputRoot = $OutputRoot
}
elseif ($isBatch) {
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

if (-not $AppDataRoot) {
    $AppDataRoot = Join-Path $outputRoot ".uassetgui-appdata"
}

$rawRoot = if ($KeepRawJson) { Join-Path $outputRoot "raw-json" } else { Join-Path $outputRoot ".tmp-raw-json" }
if (-not $ManifestPath) {
    $ManifestPath = if ($ManifestJsonl) { Join-Path $outputRoot "manifest.jsonl" } else { Join-Path $outputRoot "manifest.json" }
}

if (-not $SkipPreflight) {
    $outputRoot = Test-WritableDirectory -Path $outputRoot -Label "output root" -Category "OutputPermissionDenied"
    $rawRoot = Test-WritableDirectory -Path $rawRoot -Label "raw JSON root" -Category "OutputPermissionDenied"
    $manifestParent = Split-Path -Parent $ManifestPath
    if ($manifestParent) {
        [void](Test-WritableDirectory -Path $manifestParent -Label "manifest directory" -Category "OutputPermissionDenied")
    }
    if (-not $NoIsolateAppData) {
        $AppDataRoot = Test-WritableDirectory -Path $AppDataRoot -Label "UAssetGUI app data root" -Category "AppDataPermissionDenied"
    }
}
else {
    New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
    New-Item -ItemType Directory -Force -Path $rawRoot | Out-Null
    if (-not $NoIsolateAppData) {
        New-Item -ItemType Directory -Force -Path $AppDataRoot | Out-Null
    }
}

if ($Portable -and $NoPortable) {
    throw "Portable and NoPortable cannot both be set."
}

$usePortable = $Portable -and -not $NoPortable
if ($usePortable) {
    try {
        $exeDir = Split-Path -Parent $resolvedUAssetGUI
        if ($exeDir) {
            New-Item -ItemType Directory -Force -Path (Join-Path $exeDir "Data") | Out-Null
        }
    }
    catch {
        Write-Warning "Portable mode is not writable beside UAssetGUI.exe. Falling back to isolated APPDATA. Recommended: -NoPortable -AppDataRoot `"$AppDataRoot`"."
        $usePortable = $false
    }
}

$metadataAppDataRoot = $null
if (-not $NoIsolateAppData) {
    $metadataAppDataRoot = (Resolve-Path -LiteralPath $AppDataRoot).Path
}

$commandMetadata = [ordered]@{
    skill_path = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
    script_path = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "extract_bp_json.ps1")).Path
    uassetgui_path = $resolvedUAssetGUI
    engine_version = $EngineVersion
    input_path = (Resolve-Path -LiteralPath $InputPath).Path
    output_root = (Resolve-Path -LiteralPath $outputRoot).Path
    manifest_path = [System.IO.Path]::GetFullPath($ManifestPath)
    appdata_root = $metadataAppDataRoot
    portable = [bool]$usePortable
    no_portable = [bool]$NoPortable
    keep_raw_json = [bool]$KeepRawJson
    include_raw = [bool]$IncludeRaw
    manifest_jsonl = [bool]$ManifestJsonl
    timeout_seconds = $TimeoutSeconds
    string_fallback = -not [bool]$NoStringFallback
    string_fallback_limit = $StringFallbackLimit
    command_timestamp = (Get-Date).ToUniversalTime().ToString("o")
}

$manifest = New-Object System.Collections.Generic.List[object]

foreach ($asset in $assets) {
    $summaryPath = $null
    if (-not $usingOutputRoot -and -not $isBatch -and [System.IO.Path]::GetExtension($OutputPath).ToLowerInvariant() -eq ".json") {
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
    $stringInventoryPath = Join-Path $outputRoot ((Get-StableOutputName $asset) -replace "\.ai\.json$", ".strings.json")
    $entryStringInventoryJson = $null

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
        $toJsonResult = Invoke-ProcessCaptured -FileName $resolvedUAssetGUI -Arguments $uassetArgs -EnvironmentOverrides $envOverrides -TimeoutSeconds $TimeoutSeconds
        $rawExists = Test-Path -LiteralPath $rawPath -PathType Leaf
        $rawHasContent = $false
        if ($rawExists) {
            $rawHasContent = (Get-Item -LiteralPath $rawPath).Length -gt 0
        }

        if ($toJsonResult.ExitCode -eq 0 -and $rawHasContent) {
            $summarizeResult = Invoke-Summarizer -PythonPath $resolvedPython -RawPath $rawPath -SummaryPath $summaryPath -AssetPath $asset
            if ($summarizeResult.ExitCode -ne 0 -and -not (Test-Path -LiteralPath $summaryPath -PathType Leaf)) {
                $entryStringInventoryJson = Invoke-StringFallback -PythonPath $resolvedPython -AssetPath $asset -InventoryPath $stringInventoryPath
                Write-FailedSummary -SummaryPath $summaryPath -AssetPath $asset -ErrorCategory "SummarizerFailed" -ErrorType "SummarizerFailed" -Message "summarize_uasset_json.py failed." -Stack ($summarizeResult.StdErr + $summarizeResult.StdOut) -StringInventoryPath $entryStringInventoryJson
            }
        }
        else {
            if ($toJsonResult.TimedOut) {
                $message = "UAssetGUI tojson timed out after $TimeoutSeconds seconds."
                $failureCategory = Get-UAssetGUIFailureCategory "timed_out=True"
            }
            elseif ($toJsonResult.ExitCode -eq 0 -and -not $rawHasContent) {
                $message = "UAssetGUI exited successfully but did not produce a non-empty raw JSON file. In sandboxed Windows runs, retry the same command with escalated permissions."
                $failureCategory = "NoRawJsonProduced"
            }
            else {
                $message = "UAssetGUI tojson did not produce a readable JSON file."
                $failureCategory = $null
            }
            $stack = "exit_code=$($toJsonResult.ExitCode)`ntimed_out=$($toJsonResult.TimedOut)`nraw_exists=$rawExists`nraw_has_content=$rawHasContent`nraw_path=$rawPath`nstdout=$($toJsonResult.StdOut)`nstderr=$($toJsonResult.StdErr)"
            if (-not $failureCategory) {
                $failureCategory = Get-UAssetGUIFailureCategory $stack
            }
            $entryStringInventoryJson = Invoke-StringFallback -PythonPath $resolvedPython -AssetPath $asset -InventoryPath $stringInventoryPath
            Write-FailedSummary -SummaryPath $summaryPath -AssetPath $asset -ErrorCategory $failureCategory -ErrorType "UAssetGUI.ToJsonFailed" -Message $message -Stack $stack -StringInventoryPath $entryStringInventoryJson
        }
    }
    catch {
        $catchText = "$($_.Exception.GetType().FullName)`n$($_.Exception.Message)`n$($_.ScriptStackTrace)"
        $catchCategory = Get-UAssetGUIFailureCategory $catchText
        $entryStringInventoryJson = Invoke-StringFallback -PythonPath $resolvedPython -AssetPath $asset -InventoryPath $stringInventoryPath
        Write-FailedSummary -SummaryPath $summaryPath -AssetPath $asset -ErrorCategory $catchCategory -ErrorType $_.Exception.GetType().FullName -Message $_.Exception.Message -Stack $_.ScriptStackTrace -StringInventoryPath $entryStringInventoryJson
    }

    $summaryStatus = "unknown"
    $errorMessage = $null
    $errorCategory = $null
    try {
        $summary = Get-Content -Raw -LiteralPath $summaryPath | ConvertFrom-Json
        $summaryStatus = $summary.status
        if ($summary.error) {
            $errorMessage = $summary.error.message
            $errorCategory = $summary.error.category
        }
    }
    catch {
        if (-not $entryStringInventoryJson) {
            $entryStringInventoryJson = Invoke-StringFallback -PythonPath $resolvedPython -AssetPath $asset -InventoryPath $stringInventoryPath
        }
        Write-FailedSummary -SummaryPath $summaryPath -AssetPath $asset -ErrorCategory "MalformedSummaryJson" -ErrorType $_.Exception.GetType().FullName -Message "Could not read summary JSON." -Stack $_.ScriptStackTrace -StringInventoryPath $entryStringInventoryJson
        $summaryStatus = "failed"
        $errorMessage = "Could not read summary JSON."
        $errorCategory = "MalformedSummaryJson"
    }

    $entryRawJson = $null
    if ($KeepRawJson -and (Test-Path -LiteralPath $rawPath -PathType Leaf)) {
        $entryRawJson = (Resolve-Path -LiteralPath $rawPath).Path
    }

    $entry = [ordered]@{
        asset_path = (Resolve-Path -LiteralPath $asset).Path
        summary_json = (Resolve-Path -LiteralPath $summaryPath).Path
        raw_json = $entryRawJson
        string_inventory_json = $entryStringInventoryJson
        status = $summaryStatus
        error_category = $errorCategory
        error_message = $errorMessage
    }
    if ($ManifestJsonl) {
        $entry.command_metadata = $commandMetadata
    }
    $manifest.Add([pscustomobject]$entry) | Out-Null
    Write-ManifestFile -Path $ManifestPath -Entries @($manifest.ToArray()) -Metadata $commandMetadata -AsJsonl ([bool]$ManifestJsonl)
}

if (-not $KeepRawJson -and (Test-Path -LiteralPath $rawRoot -PathType Container)) {
    Get-ChildItem -LiteralPath $rawRoot -File | Remove-Item -Force
}

if (-not $ManifestPath) {
    $ManifestPath = if ($ManifestJsonl) { Join-Path $outputRoot "manifest.jsonl" } else { Join-Path $outputRoot "manifest.json" }
}

Write-ManifestFile -Path $ManifestPath -Entries @($manifest.ToArray()) -Metadata $commandMetadata -AsJsonl ([bool]$ManifestJsonl)

$manifest
