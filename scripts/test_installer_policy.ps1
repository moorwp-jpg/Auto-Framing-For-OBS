[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "installer_policy.ps1")

$fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("obs-auto-framing-installer-policy-" + [guid]::NewGuid())
$expected = @(Get-InstallerExpectedRelativePaths)

function New-ValidStaging {
    param([string]$Root)

    if (Test-Path -LiteralPath $Root) {
        Remove-Item -LiteralPath $Root -Recurse -Force
    }
    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    foreach ($relativePath in $expected) {
        $path = Join-Path $Root $relativePath
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        Set-Content -LiteralPath $path -Value "public installer policy fixture: $relativePath" -Encoding Ascii
    }
}

function Assert-Rejected {
    param(
        [scriptblock]$Action,
        [string]$Description
    )

    try {
        & $Action
    }
    catch {
        Write-Host "Rejected as expected: $Description"
        return
    }
    throw "Installer policy failed to reject: $Description"
}

function Add-UnexpectedFixture {
    param(
        [string]$Root,
        [string]$RelativePath
    )

    $path = Join-Path $Root $RelativePath
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    Set-Content -LiteralPath $path -Value "blocked installer fixture" -Encoding Ascii
}

try {
    $staging = Join-Path $fixtureRoot "staging"
    New-ValidStaging -Root $staging
    Assert-InstallerStaging -StagingRoot $staging
    Write-Host "Accepted valid public staging."

    foreach ($missing in @(
        "obs-plugins\64bit\obs-auto-framing.dll",
        "obs-plugins\64bit\onnxruntime.dll",
        "data\obs-plugins\obs-auto-framing\models\yolox_tiny.onnx"
    )) {
        New-ValidStaging -Root $staging
        Remove-Item -LiteralPath (Join-Path $staging $missing) -Force
        Assert-Rejected { Assert-InstallerStaging -StagingRoot $staging } "missing $missing"
    }

    foreach ($blocked in @(
        "data\obs-plugins\obs-auto-framing\models\yolo26.onnx",
        "data\obs-plugins\obs-auto-framing\models\presenter_pose.onnx",
        "data\obs-plugins\obs-auto-framing\models\unexpected.onnx",
        "unexpected.pt",
        "unexpected.pdb",
        "nested.zip",
        "src\unexpected.cpp",
        "PRIVATE_NOTICE.md"
    )) {
        New-ValidStaging -Root $staging
        Add-UnexpectedFixture -Root $staging -RelativePath $blocked
        Assert-Rejected { Assert-InstallerStaging -StagingRoot $staging } "unexpected $blocked"
    }

    $invalidObsRoot = Join-Path $fixtureRoot "invalid-obs"
    New-Item -ItemType Directory -Path $invalidObsRoot -Force | Out-Null
    if (Test-ObsInstallationRoot -ObsRoot $invalidObsRoot) {
        throw "Invalid OBS root was accepted."
    }
    Write-Host "Rejected invalid OBS root."

    $validObsRoot = Join-Path $fixtureRoot "custom obs root"
    $obsExe = Join-Path $validObsRoot "bin\64bit\obs64.exe"
    New-Item -ItemType Directory -Path (Split-Path -Parent $obsExe) -Force | Out-Null
    Set-Content -LiteralPath $obsExe -Value "fixture" -Encoding Ascii
    if (-not (Test-ObsInstallationRoot -ObsRoot $validObsRoot)) {
        throw "Valid custom OBS root was rejected."
    }
    Write-Host "Accepted valid custom OBS root."

    New-ValidStaging -Root $staging
    $bundledRuntime = Join-Path $staging "obs-plugins\64bit\onnxruntime.dll"
    $installedRuntime = Join-Path $validObsRoot "obs-plugins\64bit\onnxruntime.dll"
    New-Item -ItemType Directory -Path (Split-Path -Parent $installedRuntime) -Force | Out-Null
    Copy-Item -LiteralPath $bundledRuntime -Destination $installedRuntime -Force
    $sharedState = Get-SharedRuntimePolicy -ObsRoot $validObsRoot -BundledRuntimePath $bundledRuntime
    if ($sharedState.Action -ne "Reuse" -or -not $sharedState.ExistedBefore) {
        throw "Pre-existing identical shared runtime was not detected."
    }
    Write-Host "Detected pre-existing identical shared runtime."

    $installedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $installedRuntime).Hash
    Set-Content -LiteralPath $installedRuntime -Value "modified shared runtime" -Encoding Ascii
    $decision = Get-UninstallOwnershipDecision -ObsRoot $validObsRoot `
        -RelativePath "obs-plugins\64bit\onnxruntime.dll" -InstalledHash $installedHash `
        -CreatedByInstaller $true -SharedRuntime $true
    if ($decision.Action -ne "Preserve") {
        throw "Modified shared runtime was not preserved."
    }
    Write-Host "Preserved modified shared runtime."

    foreach ($injectedPath in @(
        "..\outside.dll",
        "data\..\outside.dll",
        "C:\outside.dll",
        "\\server\share\outside.dll",
        "/outside.dll"
    )) {
        Assert-Rejected {
            Resolve-InstallerTargetPath -ObsRoot $validObsRoot -RelativePath $injectedPath
        } "unsafe manifest path $injectedPath"
    }

    Write-Host "Installer policy tests passed."
}
finally {
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\', '/')
    $fixtureFull = [System.IO.Path]::GetFullPath($fixtureRoot)
    if ($fixtureFull.StartsWith($tempRoot + [System.IO.Path]::DirectorySeparatorChar,
            [System.StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $fixtureFull)) {
        Remove-Item -LiteralPath $fixtureFull -Recurse -Force
    }
}
