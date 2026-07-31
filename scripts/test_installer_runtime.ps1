[CmdletBinding()]
param(
    [string]$InstallerPath = "out/release/obs-auto-framing-v0.2.0-windows-x64-installer.exe",
    [string]$ObsPortableZip = "out/tools/OBS-Studio-32.1.2-Windows-x64.zip",
    [string]$V011Zip = "out/tools/obs-auto-framing-v0.1.1-windows-x64.zip",
    [string]$WorkRoot = "out/installer-runtime-tests",
    [ValidateRange(10, 600)]
    [int]$ProcessTimeoutSeconds = 120
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "installer_policy.ps1")

function ConvertTo-RepoPath {
    param([string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $script:RepoRoot $Path))
}

function Assert-SafeWorkRoot {
    param([string]$Path)
    $outRoot = [System.IO.Path]::GetFullPath((Join-Path $script:RepoRoot "out"))
    $full = [System.IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith(
        $outRoot.TrimEnd('\') + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Runtime-test work root must be a child of the repository out directory: $full"
    }
    return $full
}

function New-PortableRoot {
    param([string]$Name)
    $root = Join-Path $script:TestRoot $Name
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    Expand-Archive -LiteralPath $script:ObsZipPath -DestinationPath $root -Force
    Set-Content -LiteralPath (Join-Path $root "unrelated-runtime-marker.txt") `
        -Value "must remain" -Encoding Ascii -NoNewline
    if (-not (Test-ObsInstallationRoot -ObsRoot $root)) {
        throw "Extracted OBS portable root is invalid: $root"
    }
    return $root
}

function Invoke-Installer {
    param([string]$ObsRoot, [bool]$ExpectSuccess, [switch]$OmitDir)
    $log = Join-Path $script:TestRoot ("setup-" + [guid]::NewGuid() + ".log")
    $arguments = @(
        "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/CURRENTUSER",
        "/LOG=`"$log`""
    )
    if (-not $OmitDir) { $arguments += "/DIR=`"$ObsRoot`"" }
    $process = Start-Process -FilePath $script:InstallerExe -ArgumentList $arguments `
        -PassThru -WindowStyle Hidden
    if (-not $process.WaitForExit($ProcessTimeoutSeconds * 1000)) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        throw "Installer exceeded the $ProcessTimeoutSeconds-second test timeout. Log: $log"
    }
    if ($ExpectSuccess -and $process.ExitCode -ne 0) {
        throw "Installer failed with exit code $($process.ExitCode). Log: $log"
    }
    if (-not $ExpectSuccess -and $process.ExitCode -eq 0) {
        throw "Installer unexpectedly succeeded. Log: $log"
    }
    return [pscustomobject]@{ ExitCode = $process.ExitCode; Log = $log }
}

function Find-Uninstaller {
    param([string]$ObsRoot)
    $matches = @(Get-ChildItem -LiteralPath (
        Join-Path $ObsRoot "data\obs-plugins\obs-auto-framing\installer") `
        -Filter "unins*.exe" -File)
    if ($matches.Count -ne 1) {
        throw "Expected exactly one generated uninstaller in $ObsRoot."
    }
    return $matches[0].FullName
}

function Invoke-Uninstaller {
    param([string]$ObsRoot)
    $uninstaller = Find-Uninstaller -ObsRoot $ObsRoot
    $log = Join-Path $script:TestRoot ("uninstall-" + [guid]::NewGuid() + ".log")
    $process = Start-Process -FilePath $uninstaller -ArgumentList @(
        "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/LOG=`"$log`""
    ) -PassThru -WindowStyle Hidden
    if (-not $process.WaitForExit($ProcessTimeoutSeconds * 1000)) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        throw "Uninstaller exceeded the $ProcessTimeoutSeconds-second test timeout. Log: $log"
    }
    if ($process.ExitCode -ne 0) {
        throw "Uninstaller failed with exit code $($process.ExitCode). Log: $log"
    }
    return $log
}

function Get-PayloadState {
    param([string]$ObsRoot)
    $state = @{}
    foreach ($item in $script:Descriptor) {
        $path = Resolve-InstallerTargetPath -ObsRoot $ObsRoot -RelativePath $item.relativePath
        $state[[string]$item.id] = if (Test-Path -LiteralPath $path -PathType Leaf) {
            (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
        }
        else { "" }
    }
    return $state
}

function Assert-StatesEqual {
    param($Before, $After, [string]$Description)
    foreach ($id in $Before.Keys) {
        if ([string]$Before[$id] -cne [string]$After[$id]) {
            throw "$Description changed payload '$id'."
        }
    }
}

function Assert-RootSurvived {
    param([string]$ObsRoot)
    if (-not (Test-ObsInstallationRoot -ObsRoot $ObsRoot) -or
        (Get-Content -Raw -LiteralPath (
            Join-Path $ObsRoot "unrelated-runtime-marker.txt")) -cne "must remain") {
        throw "OBS or the unrelated marker was changed: $ObsRoot"
    }
}

$script:RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$script:InstallerExe = ConvertTo-RepoPath $InstallerPath
$script:ObsZipPath = ConvertTo-RepoPath $ObsPortableZip
$v011Path = ConvertTo-RepoPath $V011Zip
$script:TestRoot = Assert-SafeWorkRoot (ConvertTo-RepoPath $WorkRoot)
foreach ($required in @($InstallerExe, $ObsZipPath, $v011Path)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Runtime-test input is missing: $required"
    }
}
$script:Descriptor = @(Get-InstallerPayloadDescriptor)

if (Test-Path -LiteralPath $TestRoot) {
    Remove-Item -LiteralPath $TestRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $TestRoot -Force | Out-Null

try {
    $clean = New-PortableRoot "clean custom root"
    $cleanResult = Invoke-Installer $clean $true
    $installed = Get-PayloadState $clean
    if (@($installed.Values | Where-Object { $_ -eq "" }).Count -gt 0) {
        throw "Clean install omitted an expected payload file."
    }
    $cleanUninstallLog = Invoke-Uninstaller $clean
    $afterCleanUninstall = Get-PayloadState $clean
    if (@($afterCleanUninstall.Values | Where-Object { $_ -ne "" }).Count -gt 0) {
        throw "Clean uninstall left installer-created payload files."
    }
    Assert-RootSurvived $clean
    Write-Host "Clean install/uninstall passed (setup exit $($cleanResult.ExitCode))."

    $manual = New-PortableRoot "manual v0.1.1 upgrade"
    Expand-Archive -LiteralPath $v011Path -DestinationPath $manual -Force
    $manualResult = Invoke-Installer $manual $true
    $runtimeAfterUpgrade = (Get-PayloadState $manual)["runtime"]
    $manualUninstallLog = Invoke-Uninstaller $manual
    $afterManualUninstall = Get-PayloadState $manual
    foreach ($id in @(
        "plugin", "effect", "locale", "model", "install-doc", "troubleshooting-doc",
        "license", "readme", "security", "notices"
    )) {
        if ($afterManualUninstall[$id] -ne "") {
            throw "Manual v0.1.1 upgrade uninstall left plugin-owned '$id'."
        }
    }
    if ($afterManualUninstall["runtime"] -cne $runtimeAfterUpgrade) {
        throw "Manual v0.1.1 upgrade uninstall did not preserve the shared runtime."
    }
    Assert-RootSurvived $manual
    Write-Host "Exact v0.1.1 upgrade/uninstall passed (setup exit $($manualResult.ExitCode))."

    $unknown = New-PortableRoot "unknown plugin"
    $pluginPath = Resolve-InstallerTargetPath $unknown $Descriptor[0].relativePath
    New-Item -ItemType Directory -Path (Split-Path -Parent $pluginPath) -Force | Out-Null
    Set-Content -LiteralPath $pluginPath -Value "arbitrary DLL fixture" -Encoding Ascii -NoNewline
    $unknownBefore = Get-PayloadState $unknown
    $unknownResult = Invoke-Installer $unknown $false
    Assert-StatesEqual $unknownBefore (Get-PayloadState $unknown) "Unknown plugin rejection"
    Write-Host "Unknown plugin rejection passed (exit $($unknownResult.ExitCode))."

    $modified = New-PortableRoot "modified v0.1.1 effect"
    Expand-Archive -LiteralPath $v011Path -DestinationPath $modified -Force
    $effectPath = Resolve-InstallerTargetPath $modified $Descriptor[2].relativePath
    Add-Content -LiteralPath $effectPath -Value "modified" -Encoding Ascii
    $modifiedBefore = Get-PayloadState $modified
    $modifiedResult = Invoke-Installer $modified $false
    Assert-StatesEqual $modifiedBefore (Get-PayloadState $modified) "Modified effect rejection"
    Write-Host "Modified public effect rejection passed (exit $($modifiedResult.ExitCode))."

    $repair = New-PortableRoot "repair root with spaces"
    $null = Invoke-Installer $repair $true
    $repairBefore = Get-PayloadState $repair
    $repairResult = Invoke-Installer $repair $true -OmitDir
    Assert-StatesEqual $repairBefore (Get-PayloadState $repair) "Repair ownership"
    $null = Invoke-Uninstaller $repair
    if (@((Get-PayloadState $repair).Values | Where-Object { $_ -ne "" }).Count -gt 0) {
        throw "Repair uninstall left installer-owned payload."
    }
    Assert-RootSurvived $repair
    Write-Host "Remembered custom-root repair passed (exit $($repairResult.ExitCode))."

    $tampered = New-PortableRoot "tampered manifest"
    $null = Invoke-Installer $tampered $true
    $obsHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (
        Join-Path $tampered "bin\64bit\obs64.exe")).Hash
    $manifest = Join-Path $tampered (
        "data\obs-plugins\obs-auto-framing\installer\install-manifest.ini")
    (Get-Content -Raw -LiteralPath $manifest).Replace(
        "RelativePath=obs-plugins\64bit\obs-auto-framing.dll",
        "RelativePath=bin\64bit\obs64.exe") |
        Set-Content -LiteralPath $manifest -Encoding Ascii
    $tamperedBefore = Get-PayloadState $tampered
    $tamperLog = Invoke-Uninstaller $tampered
    Assert-StatesEqual $tamperedBefore (Get-PayloadState $tampered) "Tampered-manifest uninstall"
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath (
        Join-Path $tampered "bin\64bit\obs64.exe")).Hash -cne $obsHash) {
        throw "Tampered manifest changed obs64.exe."
    }
    if ((Get-Content -Raw -LiteralPath $tamperLog) -notmatch
        "Preserved all payload files: File.0 path differs from the compiled allowlist") {
        throw "Tampered-manifest uninstall did not log the exact preserve-all reason."
    }
    Write-Host "Tampered-manifest preserve-all passed."

    $invalid = Join-Path $TestRoot "invalid root"
    New-Item -ItemType Directory -Path $invalid -Force | Out-Null
    $invalidResult = Invoke-Installer $invalid $false
    if (@(Get-ChildItem -LiteralPath $invalid -Recurse -File).Count -gt 0) {
        throw "Invalid-root rejection wrote files."
    }
    Write-Host "Invalid-root silent rejection passed (exit $($invalidResult.ExitCode))."

    Write-Host "Installer runtime policy matrix passed."
    Write-Host "Logs retained under: $TestRoot"
}
catch {
    Write-Host "Installer runtime test artifacts retained under: $TestRoot"
    throw
}
