[CmdletBinding()]
param(
    [string]$InstallRoot,
    [string]$RepositoryUrl = "https://github.com/atenfyr/UAssetGUI.git",
    [string]$Ref = "master",
    [string]$SourcePath,
    [string]$OutputPath,
    [switch]$DownloadRelease,
    [string]$ReleaseTag = "v1.1.0",
    [string]$ReleaseAssetPattern = "UAssetGUI.*\.(zip|exe)$",
    [switch]$SkipClone,
    [switch]$SkipBuild,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

function Resolve-Tool {
    param([Parameter(Mandatory = $true)][string]$Name)

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $command) {
        throw "Required tool not found on PATH: $Name"
    }
    return $command.Source
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)][string]$FileName,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [string]$WorkingDirectory
    )

    $display = $FileName + " " + (($Arguments | ForEach-Object {
        if ($_ -match '\s') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }) -join " ")
    Write-Host $display

    if ($WorkingDirectory) {
        & $FileName @Arguments 2>&1 | Write-Host
    }
    else {
        & $FileName @Arguments 2>&1 | Write-Host
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code ${LASTEXITCODE}: $display"
    }
}

function Invoke-GitHubJson {
    param([Parameter(Mandatory = $true)][string]$Uri)

    return Invoke-RestMethod -Uri $Uri -Headers @{
        "User-Agent" = "ue-bp-json-extractor-setup"
        "Accept" = "application/vnd.github+json"
    }
}

function Get-ReleaseAsset {
    param(
        [Parameter(Mandatory = $true)]$Release,
        [Parameter(Mandatory = $true)][string]$Pattern
    )

    $assets = @($Release.assets)
    if ($assets.Count -eq 0) {
        throw "Release '$($Release.tag_name)' has no downloadable assets."
    }

    $matches = @($assets | Where-Object {
        $_.name -match $Pattern -and $_.name -notmatch "(?i)(source|symbols|sha|checksums?|license|notice)"
    })
    if ($matches.Count -eq 0) {
        $assetNames = ($assets | ForEach-Object { $_.name }) -join ", "
        throw "No release asset matched pattern '$Pattern'. Available assets: $assetNames"
    }

    return @($matches | Sort-Object @{
        Expression = { if ($_.name -match "(?i)\.zip$") { 0 } else { 1 } }
    }, name)[0]
}

function Save-TextDownload {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$Path
    )

    try {
        Invoke-WebRequest -Uri $Uri -Headers @{ "User-Agent" = "ue-bp-json-extractor-setup" } -OutFile $Path
    }
    catch {
        Write-Warning "Could not download '$Uri'. $($_.Exception.Message)"
    }
}

function Install-UAssetGUIRelease {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [Parameter(Mandatory = $true)][string]$Tag,
        [Parameter(Mandatory = $true)][string]$AssetPattern,
        [switch]$Force
    )

    $release = Invoke-GitHubJson -Uri "https://api.github.com/repos/atenfyr/UAssetGUI/releases/tags/$Tag"
    $asset = Get-ReleaseAsset -Release $release -Pattern $AssetPattern
    $downloadRoot = Join-Path $InstallRoot "downloads"
    $extractRoot = Join-Path $InstallRoot ".uassetgui-release-extract"
    New-Item -ItemType Directory -Force -Path $downloadRoot | Out-Null

    if ((Test-Path -LiteralPath $OutputPath -PathType Container) -and $Force) {
        Remove-Item -LiteralPath $OutputPath -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null

    if (Test-Path -LiteralPath $extractRoot -PathType Container) {
        Remove-Item -LiteralPath $extractRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $extractRoot | Out-Null

    $downloadPath = Join-Path $downloadRoot $asset.name
    Write-Host "Downloading $($asset.name) from $($release.html_url)"
    Invoke-WebRequest -Uri $asset.browser_download_url -Headers @{ "User-Agent" = "ue-bp-json-extractor-setup" } -OutFile $downloadPath

    $hash = Get-FileHash -Algorithm SHA256 -LiteralPath $downloadPath
    $extension = [System.IO.Path]::GetExtension($downloadPath).ToLowerInvariant()
    if ($extension -eq ".zip") {
        Expand-Archive -LiteralPath $downloadPath -DestinationPath $extractRoot -Force
        $exe = Get-ChildItem -LiteralPath $extractRoot -Recurse -File -Filter "UAssetGUI.exe" | Select-Object -First 1
        if (-not $exe) {
            throw "Downloaded archive did not contain UAssetGUI.exe: $downloadPath"
        }
        Copy-Item -Path (Join-Path $exe.DirectoryName "*") -Destination $OutputPath -Recurse -Force
    }
    elseif ($extension -eq ".exe") {
        Copy-Item -LiteralPath $downloadPath -Destination (Join-Path $OutputPath "UAssetGUI.exe") -Force
    }
    else {
        throw "Unsupported release asset extension '$extension'. Adjust -ReleaseAssetPattern to select a .zip or .exe asset."
    }

    $versionText = @(
        "source=https://github.com/atenfyr/UAssetGUI"
        "release_tag=$Tag"
        "release_url=$($release.html_url)"
        "asset_name=$($asset.name)"
        "asset_url=$($asset.browser_download_url)"
        "downloaded_utc=$((Get-Date).ToUniversalTime().ToString("o"))"
    ) -join [System.Environment]::NewLine
    Set-Content -LiteralPath (Join-Path $OutputPath "VERSION.txt") -Value $versionText -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $OutputPath "SHA256SUMS.txt") -Value "$($hash.Hash)  $($asset.name)" -Encoding ASCII

    foreach ($noticeFile in @("LICENSE", "NOTICE.md")) {
        $existing = Get-ChildItem -LiteralPath $OutputPath -Recurse -File -Filter $noticeFile | Select-Object -First 1
        if (-not $existing) {
            Save-TextDownload -Uri "https://raw.githubusercontent.com/atenfyr/UAssetGUI/$Tag/$noticeFile" -Path (Join-Path $OutputPath $noticeFile)
        }
    }

    Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$skillRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
if (-not $InstallRoot) {
    $InstallRoot = Join-Path $skillRoot "tools"
}
$InstallRoot = [System.IO.Path]::GetFullPath($InstallRoot)

if (-not $SourcePath) {
    $SourcePath = Join-Path $InstallRoot "UAssetGUI-src"
}
$SourcePath = [System.IO.Path]::GetFullPath($SourcePath)

if (-not $OutputPath) {
    $OutputPath = Join-Path $InstallRoot "uassetgui-bin"
}
$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)

New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null

if ($DownloadRelease) {
    Install-UAssetGUIRelease -InstallRoot $InstallRoot -OutputPath $OutputPath -Tag $ReleaseTag -AssetPattern $ReleaseAssetPattern -Force:$Force
    $exePath = Join-Path $OutputPath "UAssetGUI.exe"
    if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
        throw "UAssetGUI.exe was not installed at: $exePath"
    }
    [ordered]@{
        install_mode = "release"
        release_tag = $ReleaseTag
        output_path = $OutputPath
        uassetgui_path = (Resolve-Path -LiteralPath $exePath).Path
    } | ConvertTo-Json -Depth 5
    return
}

if (-not (Test-Path -LiteralPath $SourcePath -PathType Container)) {
    if ($SkipClone) {
        throw "SourcePath does not exist and SkipClone was supplied: $SourcePath"
    }
    [void](Resolve-Tool "git")
    Invoke-Checked -FileName "git" -Arguments @("clone", $RepositoryUrl, $SourcePath)
}
else {
    Write-Host "Using existing UAssetGUI source: $SourcePath"
}

$gitDir = Join-Path $SourcePath ".git"
if (Test-Path -LiteralPath $gitDir -PathType Container) {
    [void](Resolve-Tool "git")
    if ($Ref) {
        Invoke-Checked -FileName "git" -Arguments @("-C", $SourcePath, "checkout", $Ref)
    }
    Invoke-Checked -FileName "git" -Arguments @("-C", $SourcePath, "submodule", "update", "--init", "--recursive")
}

$projectPath = Join-Path (Join-Path $SourcePath "UAssetGUI") "UAssetGUI.csproj"
if (-not (Test-Path -LiteralPath $projectPath -PathType Leaf)) {
    throw "UAssetGUI project was not found: $projectPath"
}

if (-not $SkipBuild) {
    [void](Resolve-Tool "dotnet")
    if ((Test-Path -LiteralPath $OutputPath -PathType Container) -and $Force) {
        Remove-Item -LiteralPath $OutputPath -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null
    Invoke-Checked -FileName "dotnet" -Arguments @(
        "publish",
        $projectPath,
        "-c",
        "Release",
        "-o",
        $OutputPath,
        "--self-contained",
        "false"
    )
}

$exePath = Join-Path $OutputPath "UAssetGUI.exe"
if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
    throw "UAssetGUI.exe was not produced at: $exePath"
}

foreach ($noticeFile in @("LICENSE", "NOTICE.md")) {
    $sourceNotice = Join-Path $SourcePath $noticeFile
    if (Test-Path -LiteralPath $sourceNotice -PathType Leaf) {
        Copy-Item -LiteralPath $sourceNotice -Destination (Join-Path $OutputPath $noticeFile) -Force
    }
}

[ordered]@{
    install_mode = "source-build"
    source_path = $SourcePath
    output_path = $OutputPath
    uassetgui_path = (Resolve-Path -LiteralPath $exePath).Path
} | ConvertTo-Json -Depth 5
