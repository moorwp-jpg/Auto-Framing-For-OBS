[CmdletBinding()]
param(
    [string]$StagingRoot = "out/release/staging",
    [string]$OutputDir = "out/release",
    [string]$InnoSetupPath,
    [switch]$NoChecksum
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "installer_policy.ps1")

function ConvertTo-ProjectPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $script:ProjectRoot $Path))
}

function Resolve-InnoSetupCompiler {
    param([string]$ExplicitPath)

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        $candidate = ConvertTo-ProjectPath -Path $ExplicitPath
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            throw "Inno Setup compiler not found at the explicit path: $candidate"
        }
        return $candidate
    }

    $command = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }

    foreach ($candidate in @(
        (Join-Path ${env:ProgramFiles(x86)} "Inno Setup 6\ISCC.exe"),
        (Join-Path $env:ProgramFiles "Inno Setup 6\ISCC.exe"),
        (Join-Path $env:LOCALAPPDATA "Programs\Inno Setup 6\ISCC.exe")
    )) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and
            (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    throw "Inno Setup 6 (ISCC.exe) was not found. Install Inno Setup 6 from https://jrsoftware.org/isdl.php or pass -InnoSetupPath."
}

$script:ProjectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$buildspecPath = Join-Path $ProjectRoot "buildspec.json"
$installerScript = Join-Path $ProjectRoot "installer\obs-auto-framing.iss"
$buildspec = Get-Content -Raw -LiteralPath $buildspecPath | ConvertFrom-Json

$pluginName = [string]$buildspec.name
$displayName = [string]$buildspec.displayName
$version = [string]$buildspec.version
$releaseChannel = [string]$buildspec.releaseChannel
$publisher = [string]$buildspec.author
if ([string]::IsNullOrWhiteSpace($pluginName) -or
    [string]::IsNullOrWhiteSpace($displayName) -or
    [string]::IsNullOrWhiteSpace($version) -or
    [string]::IsNullOrWhiteSpace($releaseChannel) -or
    [string]::IsNullOrWhiteSpace($publisher)) {
    throw "buildspec.json is missing required installer metadata."
}
if (-not (Test-Path -LiteralPath $installerScript -PathType Leaf)) {
    throw "Inno Setup script not found: $installerScript"
}

$installerText = Get-Content -Raw -LiteralPath $installerScript
if ($installerText -notmatch '#define ExpectedAppVersion "([^"]+)"') {
    throw "Installer script does not declare ExpectedAppVersion."
}
if ($Matches[1] -cne $version) {
    throw "Version mismatch: buildspec.json is $version but installer expects $($Matches[1])."
}

$stagingPath = ConvertTo-ProjectPath -Path $StagingRoot
$outputPath = ConvertTo-ProjectPath -Path $OutputDir
Assert-InstallerStaging -StagingRoot $stagingPath

$packageBaseName = "$pluginName-v$version-windows-x64"
$zipPath = Join-Path $outputPath "$packageBaseName.zip"
$zipChecksumPath = "$zipPath.sha256"
Assert-ReleaseChecksum -ArtifactPath $zipPath -ChecksumPath $zipChecksumPath
Assert-StagingMatchesZip -StagingRoot $stagingPath -ZipPath $zipPath

New-Item -ItemType Directory -Path $outputPath -Force | Out-Null
$iscc = Resolve-InnoSetupCompiler -ExplicitPath $InnoSetupPath
$installerBaseName = "$packageBaseName-installer"
$installerPath = Join-Path $outputPath "$installerBaseName.exe"
$checksumPath = "$installerPath.sha256"
foreach ($oldOutput in @($installerPath, $checksumPath)) {
    if (Test-Path -LiteralPath $oldOutput -PathType Leaf) {
        Remove-Item -LiteralPath $oldOutput -Force
    }
}

$hashDefinitions = @{
    PluginHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $stagingPath "obs-plugins\64bit\obs-auto-framing.dll")).Hash.ToLowerInvariant()
    RuntimeHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $stagingPath "obs-plugins\64bit\onnxruntime.dll")).Hash.ToLowerInvariant()
    EffectHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $stagingPath "data\obs-plugins\obs-auto-framing\effects\crop.effect")).Hash.ToLowerInvariant()
    LocaleHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $stagingPath "data\obs-plugins\obs-auto-framing\locale\en-US.ini")).Hash.ToLowerInvariant()
    ModelHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $stagingPath "data\obs-plugins\obs-auto-framing\models\yolox_tiny.onnx")).Hash.ToLowerInvariant()
    InstallDocHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $stagingPath "docs\install.md")).Hash.ToLowerInvariant()
    TroubleshootingDocHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $stagingPath "docs\troubleshooting.md")).Hash.ToLowerInvariant()
    LicenseHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $stagingPath "LICENSE")).Hash.ToLowerInvariant()
    ReadmeHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $stagingPath "README.md")).Hash.ToLowerInvariant()
    SecurityHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $stagingPath "SECURITY.md")).Hash.ToLowerInvariant()
    NoticesHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $stagingPath "THIRD_PARTY_NOTICES.md")).Hash.ToLowerInvariant()
}

$isccArguments = @(
    "/Qp",
    "/DStagingRoot=$stagingPath",
    "/DOutputDir=$outputPath",
    "/DOutputBaseFilename=$installerBaseName",
    "/DAppVersion=$version",
    "/DReleaseChannel=$releaseChannel",
    "/DAppPublisher=$publisher"
)
foreach ($entry in $hashDefinitions.GetEnumerator()) {
    $isccArguments += "/D$($entry.Key)=$($entry.Value)"
}
$isccArguments += $installerScript

& $iscc @isccArguments
if ($LASTEXITCODE -ne 0) {
    throw "Inno Setup compilation failed with exit code $LASTEXITCODE."
}
if (-not (Test-Path -LiteralPath $installerPath -PathType Leaf)) {
    throw "Inno Setup did not produce the expected installer: $installerPath"
}

if (-not $NoChecksum) {
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $installerPath).Hash.ToLowerInvariant()
    "$hash *$([System.IO.Path]::GetFileName($installerPath))" |
        Set-Content -LiteralPath $checksumPath -NoNewline -Encoding Ascii
}

Write-Host "Created public Windows installer from validated staging:"
Write-Host "  Staging: $stagingPath"
Write-Host "  Installer: $installerPath"
if (-not $NoChecksum) {
    Write-Host "  Checksum: $checksumPath"
}
Write-Host "  Version: $version $releaseChannel"
Write-Host "  Model: yolox_tiny.onnx"
