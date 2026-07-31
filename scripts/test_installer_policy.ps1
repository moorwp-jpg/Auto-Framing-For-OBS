[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "installer_policy.ps1")

$fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
    "obs-auto-framing-installer-policy-" + [guid]::NewGuid())
$expected = @(Get-InstallerExpectedRelativePaths)

function Write-FixtureFile {
    param([string]$Path, [string]$Value)
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    Set-Content -LiteralPath $Path -Value $Value -Encoding Ascii -NoNewline
}

function New-ValidStaging {
    param([string]$Root)
    if (Test-Path -LiteralPath $Root) {
        Remove-Item -LiteralPath $Root -Recurse -Force
    }
    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    foreach ($relativePath in $expected) {
        Write-FixtureFile -Path (Join-Path $Root $relativePath) `
            -Value "public installer policy fixture: $relativePath"
    }
}

function New-ObsRoot {
    param([string]$Root)
    Write-FixtureFile -Path (Join-Path $Root "bin\64bit\obs64.exe") -Value "fixture"
}

function Assert-Rejected {
    param([scriptblock]$Action, [string]$Description)
    try { & $Action }
    catch {
        Write-Host "Rejected as expected: $Description"
        return
    }
    throw "Installer policy failed to reject: $Description"
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Description)
    if ($Actual -cne $Expected) {
        throw "$Description (actual '$Actual', expected '$Expected')."
    }
}

function Write-PolicyFixture {
    param($Document, [string]$Name)
    $path = Join-Path $fixtureRoot $Name
    Write-FixtureFile -Path $path -Value ($Document | ConvertTo-Json -Depth 8)
    return $path
}

function Copy-PolicyPayload {
    param([object[]]$Policy, [string]$Staging, [string]$ObsRoot)
    foreach ($item in $Policy) {
        $source = Join-Path $Staging $item.StagingPath
        $target = Resolve-InstallerTargetPath -ObsRoot $ObsRoot -RelativePath $item.RelativePath
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Copy-Item -LiteralPath $source -Destination $target -Force
    }
}

function Copy-Manifest {
    param($Manifest)
    return ($Manifest | ConvertTo-Json -Depth 8 | ConvertFrom-Json)
}

try {
    $staging = Join-Path $fixtureRoot "staging"
    New-ValidStaging -Root $staging
    Assert-InstallerStaging -StagingRoot $staging
    $policy = @(Get-ResolvedInstallerPayloadPolicy -StagingRoot $staging)
    Assert-Equal $policy.Count 11 "The compiled payload count changed"
    Write-Host "Accepted valid public staging and authoritative 11-file descriptor."

    $descriptor = @(Get-InstallerPayloadDescriptor)
    $v011Expected = @{
        plugin = "5a33fa827465a666559a5e01d58d7d885a964f069ef104a7bfbec5e468d30d51"
        runtime = "c707fd4b555781b0d7ac6f6d64f2e94227793f9d21283664638c21817fe5597d"
        effect = "91db6e6c7776cba0a8322f09d3d7798669c27e3f9116a055c95fee9f4e6ec3ff"
        locale = "cda8431ceebb74da1e854522226c5854ace7d400fe1baef2113583b5b4279a70"
        model = "427cc366d34e27ff7a03e2899b5e3671425c262ea2291f88bb942bc1cc70b0f7"
    }
    foreach ($id in $v011Expected.Keys) {
        $entry = @($descriptor | Where-Object id -ceq $id)
        Assert-Equal $entry.Count 1 "Missing v0.1.1 descriptor for $id"
        Assert-Equal ([string]$entry[0].previousHashes[0].sha256) $v011Expected[$id] `
            "Incorrect verified v0.1.1 hash for $id"
    }
    Write-Host "Verified exact public v0.1.1 manual-upgrade hashes."

    $versionCases = [ordered]@{
        "6.7.2" = $false
        "6.7.3" = $true
        "6.7.4" = $true
        "6.8.0" = $true
        "7.0.0" = $true
        "6.7.3.0" = $true
        "Inno Setup 6.7.3 (u)" = $true
    }
    foreach ($versionText in $versionCases.Keys) {
        $parsedVersion = ConvertTo-InnoSetupVersion -VersionText $versionText
        Assert-Equal (Test-InnoSetupMinimumVersion -Detected $parsedVersion) `
            $versionCases[$versionText] "Incorrect Inno Setup minimum result for $versionText"
    }
    foreach ($invalidVersion in @("", "invalid", "6", "6.7")) {
        Assert-Rejected {
            ConvertTo-InnoSetupVersion -VersionText $invalidVersion
        } "indeterminate Inno Setup version '$invalidVersion'"
    }
    $indeterminateCompiler = Join-Path $fixtureRoot "ISCC.exe"
    Write-FixtureFile -Path $indeterminateCompiler -Value "not an Inno Setup compiler"
    Assert-Rejected {
        Get-InnoSetupVersion -CompilerPath $indeterminateCompiler
    } "compiler with indeterminate FileVersionInfo"

    $buildInstallerText = Get-Content -Raw -LiteralPath (
        Join-Path $PSScriptRoot "build_installer.ps1")
    $versionCheckIndex = $buildInstallerText.IndexOf(
        '$detectedInnoVersion = Get-InnoSetupVersion')
    $minimumCheckIndex = $buildInstallerText.IndexOf(
        'Test-InnoSetupMinimumVersion -Detected')
    $compilerInvocationIndex = $buildInstallerText.IndexOf('& $iscc @isccArguments')
    if ($versionCheckIndex -lt 0 -or $minimumCheckIndex -lt 0 -or
        $compilerInvocationIndex -lt 0 -or
        $versionCheckIndex -gt $compilerInvocationIndex -or
        $minimumCheckIndex -gt $compilerInvocationIndex) {
        throw "Inno Setup version validation must occur before compiler invocation."
    }
    Write-Host "Validated Inno Setup 6.7.3 minimum-version parsing and comparison."

    $archivePolicy = Get-PublicV011ArchivePolicy
    Assert-Equal $archivePolicy.Asset "obs-auto-framing-v0.1.1-windows-x64.zip" `
        "Incorrect public v0.1.1 archive filename"
    Assert-Equal $archivePolicy.SHA256 `
        "8cff523c196b48c38b77847e9e9721e926eeea94b4956b95eedacab73dc38f19" `
        "Incorrect public v0.1.1 archive SHA-256"
    $null = Assert-PublicV011ArchiveIdentity -ArchiveFileName $archivePolicy.Asset `
        -ActualSHA256 $archivePolicy.SHA256 -Policy $archivePolicy
    $null = Assert-PublicV011ArchiveIdentity -ArchiveFileName $archivePolicy.Asset `
        -ActualSHA256 $archivePolicy.SHA256.ToUpperInvariant() -Policy $archivePolicy
    Assert-Rejected {
        Assert-PublicV011ArchiveIdentity -ArchiveFileName "wrong-v0.1.1.zip" `
            -ActualSHA256 $archivePolicy.SHA256 -Policy $archivePolicy
    } "incorrect public v0.1.1 archive filename"
    Assert-Rejected {
        Assert-PublicV011ArchiveIdentity -ArchiveFileName $archivePolicy.Asset `
            -ActualSHA256 ("0" * 64) -Policy $archivePolicy
    } "incorrect public v0.1.1 archive hash"

    $validSource = @{
        release = "https://github.com/moorwp-jpg/Auto-Framing-For-OBS/releases/tag/v0.1.1"
        asset = $archivePolicy.Asset
        assetSHA256 = $archivePolicy.SHA256
    }
    Assert-Rejected {
        Get-PublicV011ArchivePolicy -PolicyPath (
            Write-PolicyFixture -Document @{} -Name "missing-source.json")
    } "missing previousHashSource"
    Assert-Rejected {
        Get-PublicV011ArchivePolicy -PolicyPath (
            Write-PolicyFixture -Document @{
                previousHashSource = @{
                    release = $validSource.release
                    asset = $validSource.asset
                }
            } -Name "missing-archive-sha.json")
    } "missing public archive SHA-256"
    foreach ($invalidPolicyHash in @("bad-hash", $archivePolicy.SHA256.ToUpperInvariant())) {
        Assert-Rejected {
            Get-PublicV011ArchivePolicy -PolicyPath (
                Write-PolicyFixture -Document @{
                    previousHashSource = @{
                        release = $validSource.release
                        asset = $validSource.asset
                        assetSHA256 = $invalidPolicyHash
                    }
                } -Name ("invalid-archive-sha-" + [guid]::NewGuid() + ".json"))
        } "noncanonical public archive SHA-256"
    }
    $wrongArchiveFixture = Join-Path $fixtureRoot $archivePolicy.Asset
    Write-FixtureFile -Path $wrongArchiveFixture -Value "not the published archive"
    Assert-Rejected {
        Assert-PublicV011UpgradeArchive -ArchivePath $wrongArchiveFixture
    } "fixture archive with incorrect content hash"

    $runtimeScriptText = Get-Content -Raw -LiteralPath (
        Join-Path $PSScriptRoot "test_installer_runtime.ps1")
    $archiveValidationIndex = $runtimeScriptText.IndexOf(
        '$validatedV011Archive = Assert-PublicV011UpgradeArchive')
    $testRootMutationIndex = $runtimeScriptText.IndexOf(
        'if (Test-Path -LiteralPath $TestRoot)')
    $upgradeExtractionIndex = $runtimeScriptText.IndexOf(
        'Expand-Archive -LiteralPath $v011Path')
    if ($archiveValidationIndex -lt 0 -or
        $testRootMutationIndex -lt 0 -or
        $upgradeExtractionIndex -lt 0 -or
        $archiveValidationIndex -gt $testRootMutationIndex -or
        $archiveValidationIndex -gt $upgradeExtractionIndex) {
        throw "Runtime archive validation must occur before test-root mutation and upgrade extraction."
    }
    Write-Host "Validated canonical public v0.1.1 archive policy and pre-extraction ordering."

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
        "unexpected.pt", "unexpected.pdb", "nested.zip", "src\unexpected.cpp",
        "PRIVATE_NOTICE.md"
    )) {
        New-ValidStaging -Root $staging
        Write-FixtureFile -Path (Join-Path $staging $blocked) -Value "blocked"
        Assert-Rejected { Assert-InstallerStaging -StagingRoot $staging } "unexpected $blocked"
    }

    foreach ($allowedRoot in @(
        @{ Path = "C:\Program Files\obs-studio"; Drive = [System.IO.DriveType]::Fixed },
        @{ Path = "C:\Local OBS With Spaces"; Drive = [System.IO.DriveType]::Fixed },
        @{ Path = "E:\Portable OBS"; Drive = [System.IO.DriveType]::Removable }
    )) {
        if (-not (Test-InstallerRootLocationPolicy -ObsRoot $allowedRoot.Path `
                -DriveType $allowedRoot.Drive)) {
            throw "Local installer root policy rejected '$($allowedRoot.Path)'."
        }
    }
    foreach ($rejectedRoot in @(
        @{ Path = "\\server\share\obs-studio"; Drive = [System.IO.DriveType]::Network },
        @{ Path = "\\server\share\obs-studio\bin\64bit\obs64.exe"; Drive = [System.IO.DriveType]::Fixed },
        @{ Path = "Z:\mapped-obs"; Drive = [System.IO.DriveType]::Network },
        @{ Path = "relative\obs-studio"; Drive = [System.IO.DriveType]::Fixed },
        @{ Path = "::invalid::"; Drive = [System.IO.DriveType]::Fixed }
    )) {
        if (Test-InstallerRootLocationPolicy -ObsRoot $rejectedRoot.Path `
                -DriveType $rejectedRoot.Drive) {
            throw "Network, relative, or malformed installer root was accepted: $($rejectedRoot.Path)"
        }
    }

    $invalidObsRoot = Join-Path $fixtureRoot "invalid-obs"
    New-Item -ItemType Directory -Path $invalidObsRoot -Force | Out-Null
    if (Test-ObsInstallationRoot -ObsRoot $invalidObsRoot) {
        throw "Invalid OBS root was accepted."
    }
    $obsRoot = Join-Path $fixtureRoot "custom obs root"
    New-ObsRoot -Root $obsRoot
    if (-not (Test-ObsInstallationRoot -ObsRoot $obsRoot)) {
        throw "Valid custom OBS root was rejected."
    }
    $portableRoot = Join-Path $fixtureRoot "local portable obs root"
    New-ObsRoot -Root $portableRoot
    if (-not (Test-ObsInstallationRoot -ObsRoot $portableRoot)) {
        throw "Valid local portable OBS root was rejected."
    }
    Write-Host "Validated local fixed, custom, portable, UNC, and mapped-drive root policy."

    $installerScriptText = Get-Content -Raw -LiteralPath (
        Join-Path (Join-Path $PSScriptRoot "..") "installer\obs-auto-framing.iss")
    foreach ($directive in @(
        "RedirectionGuard=yes", "AllowUNCPath=no", "AllowNetworkDrive=no"
    )) {
        if ($installerScriptText -cnotmatch [regex]::Escape($directive)) {
            throw "Installer script is missing required security directive: $directive"
        }
    }
    foreach ($requiredText in @(
        "ObsRootLocationIsLocal", "WindowsGetDriveType", "UNC paths and mapped network drives"
    )) {
        if ($installerScriptText -cnotmatch [regex]::Escape($requiredText)) {
            throw "Installer script is missing local-root enforcement: $requiredText"
        }
    }

    foreach ($injectedPath in @(
        "..\outside.dll", "data\..\outside.dll", "C:\outside.dll",
        "\\server\share\outside.dll", "/outside.dll"
    )) {
        Assert-Rejected {
            Resolve-InstallerTargetPath -ObsRoot $obsRoot -RelativePath $injectedPath
        } "unsafe path $injectedPath"
    }

    New-ValidStaging -Root $staging
    $policy = @(Get-ResolvedInstallerPayloadPolicy -StagingRoot $staging)
    $cleanRoot = Join-Path $fixtureRoot "clean install"
    New-ObsRoot -Root $cleanRoot
    $cleanPlan = @(Get-InstallerPreflightPlan -ObsRoot $cleanRoot -Policy $policy `
        -InstalledVersion "0.2.0")
    if (@($cleanPlan | Where-Object {
        $_.Action -cne "InstallNew" -or -not $_.CreatedByInstaller
    }).Count -gt 0) {
        throw "Clean-install ownership was not installer-created."
    }
    Copy-PolicyPayload -Policy $policy -Staging $staging -ObsRoot $cleanRoot
    $validManifest = New-InstallerOwnershipManifest -ObsRoot $cleanRoot -Policy $policy `
        -Plan $cleanPlan -InstalledVersion "0.2.0"
    $validity = Test-InstallerOwnershipManifest -Manifest $validManifest -Policy $policy `
        -ObsRoot $cleanRoot -InstalledVersion "0.2.0"
    if (-not $validity.Valid) { throw "A valid complete manifest was rejected: $($validity.Reason)" }

    $repair = @(Get-InstallerPreflightPlan -ObsRoot $cleanRoot -Policy $policy `
        -InstalledVersion "0.2.0" -ExistingManifest $validManifest)
    if (@($repair | Where-Object {
        $_.Action -cne "CarryPriorInstallerOwnership"
    }).Count -gt 0) {
        throw "Repair did not reuse the exact installed payload."
    }
    $preExistingManifest = Copy-Manifest $validManifest
    $preExistingManifest.Files[0].CreatedByInstaller = $false
    $preExistingManifest.Files[0].ExistedBefore = $true
    $preExistingManifest.Files[0].OriginalSHA256 = $policy[0].InstalledHash
    $preExistingRepair = @(Get-InstallerPreflightPlan -ObsRoot $cleanRoot -Policy $policy `
        -InstalledVersion "0.2.0" -ExistingManifest $preExistingManifest)
    if ($preExistingRepair[0].CreatedByInstaller -or
        $preExistingRepair[0].Action -cne "CarryPriorInstallerOwnership") {
        throw "Repair incorrectly claimed a valid pre-existing plugin file."
    }
    Write-Host "Validated clean install and same-version repair ownership."

    $tamperCases = [ordered]@{
        "missing record" = { param($m) $m.Files = @($m.Files | Select-Object -SkipLast 1) }
        "extra record" = { param($m) $m.Files += (Copy-Manifest $m.Files[0]) }
        "wrong count" = { param($m) $m.Metadata.FileCount = "10" }
        "incomplete marker" = { param($m) $m.Metadata.Complete = $false }
        "string complete marker" = { param($m) $m.Metadata.Complete = "true" }
        "wrong root" = { param($m) $m.Metadata.ObsRoot = $invalidObsRoot }
        "wrong schema" = { param($m) $m.Metadata.SchemaVersion = "2" }
        "wrong version" = { param($m) $m.Metadata.InstalledVersion = "0.1.1" }
        "swapped records" = {
            param($m) $first = $m.Files[0]; $m.Files[0] = $m.Files[1]; $m.Files[1] = $first
        }
        "duplicate path" = { param($m) $m.Files[1].RelativePath = $m.Files[0].RelativePath }
        "OBS executable path" = { param($m) $m.Files[0].RelativePath = "bin\64bit\obs64.exe" }
        "another plugin path" = {
            param($m) $m.Files[0].RelativePath = "obs-plugins\64bit\another-plugin.dll"
        }
        "unexpected in-root path" = {
            param($m) $m.Files[0].RelativePath = "data\obs-plugins\other\file.txt"
        }
        "traversing path" = { param($m) $m.Files[0].RelativePath = "..\outside.dll" }
        "absolute path" = { param($m) $m.Files[0].RelativePath = "C:\outside.dll" }
        "tampered id" = { param($m) $m.Files[0].Id = "other-plugin" }
        "tampered hash" = { param($m) $m.Files[0].InstalledSHA256 = ("0" * 64) }
        "tampered shared class" = { param($m) $m.Files[0].Shared = $true }
        "tampered removal class" = { param($m) $m.Files[0].RemoveOnUninstall = $false }
        "string ownership boolean" = { param($m) $m.Files[0].CreatedByInstaller = "true" }
    }
    foreach ($name in $tamperCases.Keys) {
        $tampered = Copy-Manifest $validManifest
        & $tamperCases[$name] $tampered
        $check = Test-InstallerOwnershipManifest -Manifest $tampered -Policy $policy `
            -ObsRoot $cleanRoot -InstalledVersion "0.2.0"
        if ($check.Valid) { throw "Tampered manifest was accepted: $name" }
        $preserve = @(Get-InstallerUninstallPlan -ObsRoot $cleanRoot -Policy $policy `
            -InstalledVersion "0.2.0" -Manifest $tampered)
        if ($preserve.Count -ne 11 -or
            @($preserve | Where-Object Action -cne "PreserveInvalidManifest").Count -gt 0) {
            throw "Invalid manifest did not produce preserve-all: $name"
        }
        Assert-Rejected {
            Get-InstallerPreflightPlan -ObsRoot $cleanRoot -Policy $policy `
                -InstalledVersion "0.2.0" -ExistingManifest $tampered
        } "transactional install with $name"
    }
    Write-Host "Validated manifest completeness, classification, path, and hash tamper resistance."

    $unknownRoot = Join-Path $fixtureRoot "unknown payload"
    New-ObsRoot -Root $unknownRoot
    $unknownPlugin = Resolve-InstallerTargetPath -ObsRoot $unknownRoot `
        -RelativePath $policy[0].RelativePath
    Write-FixtureFile -Path $unknownPlugin -Value "unknown or modified plugin"
    $unknownHashBefore = (Get-FileHash -Algorithm SHA256 -LiteralPath $unknownPlugin).Hash
    Assert-Rejected {
        Get-InstallerPreflightPlan -ObsRoot $unknownRoot -Policy $policy `
            -InstalledVersion "0.2.0"
    } "unknown existing plugin payload"
    Assert-Equal (Get-FileHash -Algorithm SHA256 -LiteralPath $unknownPlugin).Hash `
        $unknownHashBefore "Transactional preflight changed a conflicting file"
    if (@(Get-ChildItem -LiteralPath $unknownRoot -Recurse -File).Count -ne 2) {
        throw "Transactional preflight wrote payload files before rejecting a conflict."
    }

    foreach ($unknownId in @("effect", "model")) {
        $conflictRoot = Join-Path $fixtureRoot "unknown $unknownId"
        New-ObsRoot -Root $conflictRoot
        $conflictItem = @($policy | Where-Object Id -ceq $unknownId)[0]
        Write-FixtureFile -Path (Resolve-InstallerTargetPath -ObsRoot $conflictRoot `
            -RelativePath $conflictItem.RelativePath) -Value "unknown $unknownId"
        Assert-Rejected {
            Get-InstallerPreflightPlan -ObsRoot $conflictRoot -Policy $policy `
                -InstalledVersion "0.2.0"
        } "unknown existing $unknownId"
    }

    $manualRoot = Join-Path $fixtureRoot "manual v0.1.1 simulation"
    New-ObsRoot -Root $manualRoot
    $recognizedIds = @("plugin", "runtime", "effect", "locale", "model")
    foreach ($item in $policy) {
        if ($recognizedIds -contains $item.Id) {
            $target = Resolve-InstallerTargetPath -ObsRoot $manualRoot -RelativePath $item.RelativePath
            Write-FixtureFile -Path $target -Value "verified old public payload: $($item.Id)"
            $oldHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $target).Hash.ToLowerInvariant()
            $item.PreviousHashes = @($item.PreviousHashes) + $oldHash
        }
    }
    $manualPlan = @(Get-InstallerPreflightPlan -ObsRoot $manualRoot -Policy $policy `
        -InstalledVersion "0.2.0")
    foreach ($id in @("plugin", "effect", "locale", "model")) {
        $entry = @($manualPlan | Where-Object Id -ceq $id)[0]
        if (-not $entry.CreatedByInstaller -or
            $entry.Action -cne "UpgradeRecognizedManual") {
            throw "Recognized manual $id did not become replaceable installer ownership."
        }
    }
    $runtimePlan = @($manualPlan | Where-Object Id -ceq "runtime")[0]
    if ($runtimePlan.CreatedByInstaller -or
        $runtimePlan.Action -cne "UpgradeRecognizedManual") {
        throw "Recognized manual shared runtime was not kept pre-existing."
    }
    $modifiedManualRoot = Join-Path $fixtureRoot "modified v0.1.1 simulation"
    New-ObsRoot -Root $modifiedManualRoot
    $effectItem = @($policy | Where-Object Id -ceq "effect")[0]
    Write-FixtureFile -Path (Resolve-InstallerTargetPath -ObsRoot $modifiedManualRoot `
        -RelativePath $effectItem.RelativePath) -Value "verified old public payload: effect modified"
    Assert-Rejected {
        Get-InstallerPreflightPlan -ObsRoot $modifiedManualRoot -Policy $policy `
            -InstalledVersion "0.2.0"
    } "modified recognized v0.1.1 effect"

    Copy-PolicyPayload -Policy $policy -Staging $staging -ObsRoot $manualRoot
    $manualManifest = New-InstallerOwnershipManifest -ObsRoot $manualRoot -Policy $policy `
        -Plan $manualPlan -InstalledVersion "0.2.0"
    $manualUninstall = @(Get-InstallerUninstallPlan -ObsRoot $manualRoot -Policy $policy `
        -InstalledVersion "0.2.0" -Manifest $manualManifest)
    foreach ($id in @("plugin", "effect", "locale", "model")) {
        Assert-Equal (@($manualUninstall | Where-Object Id -ceq $id)[0].Action) "RemoveOwned" `
            "Recognized manual $id was not removable after upgrade"
    }
    Assert-Equal (@($manualUninstall | Where-Object Id -ceq "runtime")[0].Action) `
        "PreservePreExisting" "Pre-existing shared runtime was not preserved"

    $cleanUninstall = @(Get-InstallerUninstallPlan -ObsRoot $cleanRoot -Policy $policy `
        -InstalledVersion "0.2.0" -Manifest $validManifest)
    Assert-Equal (@($cleanUninstall | Where-Object Id -ceq "runtime")[0].Action) `
        "RemoveOwned" "Installer-created unchanged shared runtime was not removable"

    $pluginPath = Resolve-InstallerTargetPath -ObsRoot $manualRoot `
        -RelativePath (@($policy | Where-Object Id -ceq "plugin")[0].RelativePath)
    Write-FixtureFile -Path $pluginPath -Value "modified after install"
    $modifiedPlan = @(Get-InstallerUninstallPlan -ObsRoot $manualRoot -Policy $policy `
        -InstalledVersion "0.2.0" -Manifest $manualManifest)
    Assert-Equal (@($modifiedPlan | Where-Object Id -ceq "plugin")[0].Action) `
        "PreserveModified" "Modified plugin payload was not preserved"
    Write-Host "Validated v0.1.1 ownership migration and conservative shared-runtime uninstall."

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
