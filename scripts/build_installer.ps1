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

function ConvertTo-InnoString {
    param([Parameter(Mandatory = $true)][string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

function Get-InnoCaseFunction {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$ReturnType,
        [Parameter(Mandatory = $true)][object[]]$Policy,
        [Parameter(Mandatory = $true)][scriptblock]$Value
    )

    $result = [System.Collections.Generic.List[string]]::new()
    $result.Add("function ${Name}(Index: Integer): ${ReturnType};")
    $result.Add("begin")
    $result.Add("  case Index of")
    for ($index = 0; $index -lt $Policy.Count; $index++) {
        $result.Add("    ${index}: Result := $(& $Value $Policy[$index]);")
    }
    $result.Add("  else")
    $result.Add("    RaiseException('Invalid compiled payload index: ' + IntToStr(Index));")
    $result.Add("  end;")
    $result.Add("end;")
    $result.Add("")
    return @($result)
}

function New-InnoPayloadPolicyInclude {
    param(
        [Parameter(Mandatory = $true)][object[]]$Policy,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("{ Generated from installer/payload-policy.json and validated staging. }")
    $lines.Add("const")
    $lines.Add("  CompiledPayloadCount = $($Policy.Count);")
    $lines.Add("")
    $lines.AddRange([string[]]@(Get-InnoCaseFunction -Name "PayloadId" -ReturnType "String" `
        -Policy $Policy -Value { param($item) ConvertTo-InnoString $item.Id }))
    $lines.AddRange([string[]]@(Get-InnoCaseFunction -Name "PayloadRelativePath" `
        -ReturnType "String" -Policy $Policy `
        -Value { param($item) ConvertTo-InnoString $item.RelativePath }))
    $lines.AddRange([string[]]@(Get-InnoCaseFunction -Name "PayloadInstalledHash" `
        -ReturnType "String" -Policy $Policy `
        -Value { param($item) ConvertTo-InnoString $item.InstalledHash }))
    $lines.AddRange([string[]]@(Get-InnoCaseFunction -Name "PayloadShared" `
        -ReturnType "Boolean" -Policy $Policy `
        -Value { param($item) if ($item.Shared) { "True" } else { "False" } }))
    $lines.AddRange([string[]]@(Get-InnoCaseFunction -Name "PayloadRemoveOnUninstall" `
        -ReturnType "Boolean" -Policy $Policy -Value {
            param($item) if ($item.RemoveOnUninstall) { "True" } else { "False" }
        }))

    $lines.Add("function PayloadRecognizesManualHash(Index: Integer; Hash: String): Boolean;")
    $lines.Add("begin")
    $lines.Add("  Result := False;")
    $lines.Add("  case Index of")
    for ($index = 0; $index -lt $Policy.Count; $index++) {
        $item = $Policy[$index]
        if (-not $item.RecognizedManualUpgrade) {
            $expression = "False"
        }
        else {
            $hashes = @($item.InstalledHash) + @($item.PreviousHashes)
            $checks = @($hashes | Select-Object -Unique | ForEach-Object {
                "(CompareText(Hash, $(ConvertTo-InnoString $_)) = 0)"
            })
            $expression = $checks -join " or "
        }
        $lines.Add("    ${index}: Result := ${expression};")
    }
    $lines.Add("  end;")
    $lines.Add("end;")
    $lines.Add("")
    Set-Content -LiteralPath $Path -Value $lines -Encoding Ascii
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
$payloadPolicy = @(Get-ResolvedInstallerPayloadPolicy -StagingRoot $stagingPath)
for ($index = 0; $index -lt $payloadPolicy.Count; $index++) {
    $item = $payloadPolicy[$index]
    $destinationDirectory = Split-Path -Parent $item.RelativePath
    if ($installerText -notlike "*$($item.StagingPath)*" -or
        $installerText -notlike "*DestDir: `"{app}\$destinationDirectory`"*"-or
        $installerText -notlike "*ShouldInstallPayload($index)*") {
        throw "Inno Setup [Files] entry does not match payload descriptor '$($item.Id)'."
    }
}

$packageBaseName = "$pluginName-v$version-windows-x64"
$zipPath = Join-Path $outputPath "$packageBaseName.zip"
$zipChecksumPath = "$zipPath.sha256"
Assert-ReleaseChecksum -ArtifactPath $zipPath -ChecksumPath $zipChecksumPath
Assert-StagingMatchesZip -StagingRoot $stagingPath -ZipPath $zipPath

New-Item -ItemType Directory -Path $outputPath -Force | Out-Null
$iscc = Resolve-InnoSetupCompiler -ExplicitPath $InnoSetupPath
$minimumInnoVersion = [version]"6.7.3"
$detectedInnoVersion = Get-InnoSetupVersion -CompilerPath $iscc
Write-Host "Inno Setup compiler:"
Write-Host "  Path: $iscc"
Write-Host "  Version: $detectedInnoVersion"
Write-Host "  Minimum supported: $minimumInnoVersion"
if (-not (Test-InnoSetupMinimumVersion -Detected $detectedInnoVersion `
        -Minimum $minimumInnoVersion)) {
    throw "Inno Setup $minimumInnoVersion or newer is required. " +
        "Detected: $detectedInnoVersion Compiler: $iscc"
}
$installerBaseName = "$packageBaseName-installer"
$installerPath = Join-Path $outputPath "$installerBaseName.exe"
$checksumPath = "$installerPath.sha256"
$policyIncludePath = Join-Path $outputPath "installer-payload-policy.generated.iss"
New-InnoPayloadPolicyInclude -Policy $payloadPolicy -Path $policyIncludePath
foreach ($oldOutput in @($installerPath, $checksumPath)) {
    if (Test-Path -LiteralPath $oldOutput -PathType Leaf) {
        Remove-Item -LiteralPath $oldOutput -Force
    }
}

$isccArguments = @(
    "/Qp",
    "/DStagingRoot=$stagingPath",
    "/DOutputDir=$outputPath",
    "/DOutputBaseFilename=$installerBaseName",
    "/DAppVersion=$version",
    "/DReleaseChannel=$releaseChannel",
    "/DAppPublisher=$publisher",
    "/DPolicyIncludePath=$policyIncludePath"
)
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
