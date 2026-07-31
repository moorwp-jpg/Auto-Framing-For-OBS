[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

function Get-InstallerPolicyPath {
    return [System.IO.Path]::GetFullPath(
        (Join-Path (Join-Path $PSScriptRoot "..") "installer\payload-policy.json"))
}

function ConvertTo-InnoSetupVersion {
    param([string]$VersionText)

    if ([string]::IsNullOrWhiteSpace($VersionText)) {
        throw "The Inno Setup compiler version is empty."
    }
    $match = [regex]::Match(
        $VersionText, '(?<!\d)(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)(?:\.(?<build>\d+))?')
    if (-not $match.Success) {
        throw "Could not parse an Inno Setup major, minor, and patch version from '$VersionText'."
    }
    $normalized = "$($match.Groups['major'].Value).$($match.Groups['minor'].Value)." +
        $match.Groups['patch'].Value
    if ($match.Groups['build'].Success) {
        $normalized += ".$($match.Groups['build'].Value)"
    }
    try {
        return [version]$normalized
    }
    catch {
        throw "Could not parse the Inno Setup compiler version '$VersionText'."
    }
}

function Test-InnoSetupMinimumVersion {
    param(
        [Parameter(Mandatory = $true)][version]$Detected,
        [version]$Minimum = [version]"6.7.3"
    )

    return $Detected -ge $Minimum
}

function Get-InnoSetupVersion {
    param([Parameter(Mandatory = $true)][string]$CompilerPath)

    if (-not (Test-Path -LiteralPath $CompilerPath -PathType Leaf)) {
        throw "Inno Setup compiler not found: $CompilerPath"
    }
    $compilerInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($CompilerPath)
    $compilerProductName = ([string]$compilerInfo.ProductName).Trim()
    $compilerDescription = ([string]$compilerInfo.FileDescription).Trim()
    if ($compilerProductName -cne "Inno Setup" -or
        $compilerDescription -cne "Inno Setup Command-Line Compiler") {
        throw "The resolved compiler does not identify itself as Inno Setup ISCC.exe: $CompilerPath"
    }
    $versionSources = @(
        [pscustomobject]@{ Text = $compilerInfo.ProductVersion; Source = $CompilerPath },
        [pscustomobject]@{ Text = $compilerInfo.FileVersion; Source = $CompilerPath }
    )

    # Official installed builds may stamp ISCC.exe as 0.0.0.0. In that case,
    # the Inno-generated uninstaller beside the compiler carries the package ProductVersion.
    $packageMetadataPath = Join-Path (Split-Path -Parent $CompilerPath) "unins000.exe"
    if (Test-Path -LiteralPath $packageMetadataPath -PathType Leaf) {
        $packageInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($packageMetadataPath)
        if (([string]$packageInfo.ProductName).Trim() -ceq "Inno Setup") {
            $versionSources += @(
                [pscustomobject]@{ Text = $packageInfo.ProductVersion; Source = $packageMetadataPath },
                [pscustomobject]@{ Text = $packageInfo.FileVersion; Source = $packageMetadataPath }
            )
        }
    }

    foreach ($candidate in $versionSources) {
        if ([string]::IsNullOrWhiteSpace([string]$candidate.Text)) {
            continue
        }
        try {
            $parsed = ConvertTo-InnoSetupVersion -VersionText ([string]$candidate.Text)
            if ($parsed.Major -ne 0 -or $parsed.Minor -ne 0 -or
                $parsed.Build -ne 0 -or $parsed.Revision -gt 0) {
                return $parsed
            }
        }
        catch {
            continue
        }
    }
    throw "Could not determine a nonzero Inno Setup compiler version from FileVersionInfo: $CompilerPath"
}

function Get-PublicV011ArchivePolicy {
    param([string]$PolicyPath = (Get-InstallerPolicyPath))

    if (-not (Test-Path -LiteralPath $PolicyPath -PathType Leaf)) {
        throw "Installer payload policy not found: $PolicyPath"
    }
    $document = Get-Content -Raw -LiteralPath $PolicyPath | ConvertFrom-Json
    $sourceProperty = $document.PSObject.Properties["previousHashSource"]
    if ($null -eq $sourceProperty -or $null -eq $document.previousHashSource) {
        throw "Installer payload policy is missing previousHashSource."
    }
    foreach ($property in @("release", "asset", "assetSHA256")) {
        if ($null -eq $document.previousHashSource.PSObject.Properties[$property]) {
            throw "Installer payload policy previousHashSource is missing '$property'."
        }
    }
    $release = [string]$document.previousHashSource.release
    $asset = [string]$document.previousHashSource.asset
    $sha256 = [string]$document.previousHashSource.assetSHA256
    if ([string]::IsNullOrWhiteSpace($release)) {
        throw "Installer payload policy previousHashSource.release is empty."
    }
    if ($asset -cne "obs-auto-framing-v0.1.1-windows-x64.zip") {
        throw "Installer payload policy has an unexpected v0.1.1 archive name: $asset"
    }
    if ($sha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw "Installer payload policy has an invalid lowercase v0.1.1 archive SHA-256."
    }
    return [pscustomobject]@{
        Release = $release
        Asset = $asset
        SHA256 = $sha256
    }
}

function Assert-PublicV011ArchiveIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$ArchiveFileName,
        [Parameter(Mandatory = $true)][string]$ActualSHA256,
        [Parameter(Mandatory = $true)]$Policy
    )

    if ($ArchiveFileName -cne [string]$Policy.Asset) {
        throw "The v0.1.1 upgrade test archive filename must be '$($Policy.Asset)'; found '$ArchiveFileName'."
    }
    if ($ActualSHA256 -notmatch '^[0-9a-fA-F]{64}$') {
        throw "The v0.1.1 upgrade test archive has an invalid SHA-256 value."
    }
    $actualNormalized = $ActualSHA256.ToLowerInvariant()
    if ($actualNormalized -cne [string]$Policy.SHA256) {
        throw "The v0.1.1 upgrade test archive does not match the published public release. " +
            "Expected SHA-256: $($Policy.SHA256) Actual SHA-256: $actualNormalized"
    }
    return $true
}

function Assert-PublicV011UpgradeArchive {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [string]$PolicyPath = (Get-InstallerPolicyPath)
    )

    if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
        throw "The v0.1.1 upgrade test archive was not found: $ArchivePath"
    }
    $policy = Get-PublicV011ArchivePolicy -PolicyPath $PolicyPath
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $ArchivePath).Hash.ToLowerInvariant()
    $null = Assert-PublicV011ArchiveIdentity `
        -ArchiveFileName ([System.IO.Path]::GetFileName($ArchivePath)) `
        -ActualSHA256 $actual -Policy $policy
    return [pscustomobject]@{
        File = [System.IO.Path]::GetFileName($ArchivePath)
        SHA256 = $actual
        Release = $policy.Release
    }
}

function Resolve-InstallerTargetPath {
    param(
        [Parameter(Mandatory = $true)][string]$ObsRoot,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath) -or
        [System.IO.Path]::IsPathRooted($RelativePath) -or
        $RelativePath.StartsWith('\') -or
        $RelativePath.StartsWith('/') -or
        $RelativePath.Contains(':')) {
        throw "Installer path must be a nonempty relative path: $RelativePath"
    }

    $segments = @($RelativePath.Replace('/', '\').Split('\'))
    if ($segments.Count -eq 0 -or
        @($segments | Where-Object {
            [string]::IsNullOrWhiteSpace($_) -or $_ -eq "." -or $_ -eq ".."
        }).Count -gt 0) {
        throw "Installer path contains invalid or traversing segments: $RelativePath"
    }

    $rootFull = [System.IO.Path]::GetFullPath($ObsRoot).TrimEnd('\', '/')
    $targetFull = [System.IO.Path]::GetFullPath((Join-Path $rootFull ($segments -join '\')))
    $rootPrefix = $rootFull + [System.IO.Path]::DirectorySeparatorChar
    if (-not $targetFull.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Installer path escapes the OBS root: $RelativePath"
    }
    return $targetFull
}

function ConvertTo-InstallerRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $pathFull = [System.IO.Path]::GetFullPath($Path)
    $rootPrefix = $rootFull + [System.IO.Path]::DirectorySeparatorChar
    if (-not $pathFull.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside the expected root: $Path"
    }
    return $pathFull.Substring($rootPrefix.Length).Replace('/', '\')
}

function Get-InstallerPayloadDescriptor {
    param([string]$PolicyPath = (Get-InstallerPolicyPath))

    if (-not (Test-Path -LiteralPath $PolicyPath -PathType Leaf)) {
        throw "Installer payload policy not found: $PolicyPath"
    }
    $null = Get-PublicV011ArchivePolicy -PolicyPath $PolicyPath
    $document = Get-Content -Raw -LiteralPath $PolicyPath | ConvertFrom-Json
    if ($document.schemaVersion -ne 1) {
        throw "Unsupported installer payload policy schema: $($document.schemaVersion)"
    }

    $items = @($document.payload)
    if ($items.Count -ne 11) {
        throw "Installer payload policy must contain exactly 11 files; found $($items.Count)."
    }

    $ids = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    $paths = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $items) {
        foreach ($property in @(
            "id", "stagingPath", "relativePath", "shared",
            "recognizedManualUpgrade", "removeOnUninstall", "previousHashes"
        )) {
            if ($null -eq $item.PSObject.Properties[$property]) {
                throw "Installer payload item is missing '$property'."
            }
        }
        if ([string]::IsNullOrWhiteSpace([string]$item.id) -or
            -not $ids.Add([string]$item.id)) {
            throw "Installer payload IDs must be nonempty and unique: $($item.id)"
        }
        if (-not $paths.Add([string]$item.relativePath)) {
            throw "Installer payload destination paths must be unique: $($item.relativePath)"
        }
        $null = Resolve-InstallerTargetPath -ObsRoot ([System.IO.Path]::GetTempPath()) `
            -RelativePath ([string]$item.stagingPath)
        $null = Resolve-InstallerTargetPath -ObsRoot ([System.IO.Path]::GetTempPath()) `
            -RelativePath ([string]$item.relativePath)
        foreach ($previous in @($item.previousHashes)) {
            if ([string]$previous.version -notmatch '^\d+\.\d+\.\d+$' -or
                [string]$previous.sha256 -notmatch '^[0-9a-f]{64}$') {
                throw "Invalid recognized manual-upgrade hash for '$($item.id)'."
            }
        }
    }
    return $items
}

function Get-InstallerExpectedRelativePaths {
    return @(Get-InstallerPayloadDescriptor | ForEach-Object { [string]$_.stagingPath })
}

function Get-ResolvedInstallerPayloadPolicy {
    param([Parameter(Mandatory = $true)][string]$StagingRoot)

    $root = (Resolve-Path -LiteralPath $StagingRoot).Path
    return @(Get-InstallerPayloadDescriptor | ForEach-Object {
        $source = Resolve-InstallerTargetPath -ObsRoot $root -RelativePath $_.stagingPath
        [pscustomobject]@{
            Id = [string]$_.id
            StagingPath = [string]$_.stagingPath
            RelativePath = [string]$_.relativePath
            Shared = [bool]$_.shared
            RecognizedManualUpgrade = [bool]$_.recognizedManualUpgrade
            RemoveOnUninstall = [bool]$_.removeOnUninstall
            PreviousHashes = @($_.previousHashes | ForEach-Object {
                ([string]$_.sha256).ToLowerInvariant()
            })
            InstalledHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $source).Hash.ToLowerInvariant()
        }
    })
}

function Test-InstallerRootLocationPolicy {
    param(
        [string]$ObsRoot,
        [System.IO.DriveType]$DriveType = [System.IO.DriveType]::Unknown
    )

    if ([string]::IsNullOrWhiteSpace($ObsRoot) -or
        -not [System.IO.Path]::IsPathRooted($ObsRoot) -or
        $ObsRoot.StartsWith("\\", [System.StringComparison]::Ordinal)) {
        return $false
    }
    try {
        $rootFull = [System.IO.Path]::GetFullPath($ObsRoot)
        $pathRoot = [System.IO.Path]::GetPathRoot($rootFull)
        if ([string]::IsNullOrWhiteSpace($pathRoot)) {
            return $false
        }
        if (-not $PSBoundParameters.ContainsKey("DriveType")) {
            $DriveType = ([System.IO.DriveInfo]::new($pathRoot)).DriveType
        }
    }
    catch {
        return $false
    }
    return $DriveType -eq [System.IO.DriveType]::Fixed -or
        $DriveType -eq [System.IO.DriveType]::Removable
}

function Test-ObsInstallationRoot {
    param([Parameter(Mandatory = $true)][string]$ObsRoot)
    if (-not (Test-InstallerRootLocationPolicy -ObsRoot $ObsRoot)) {
        return $false
    }
    $rootFull = [System.IO.Path]::GetFullPath($ObsRoot)
    return (Test-Path -LiteralPath (Join-Path $rootFull "bin\64bit\obs64.exe") -PathType Leaf)
}

function Assert-InstallerStaging {
    param([Parameter(Mandatory = $true)][string]$StagingRoot)

    if (-not (Test-Path -LiteralPath $StagingRoot -PathType Container)) {
        throw "Installer staging directory not found: $StagingRoot"
    }
    $root = (Resolve-Path -LiteralPath $StagingRoot).Path
    $expected = @(Get-InstallerExpectedRelativePaths)
    foreach ($relativePath in $expected) {
        $resolved = Resolve-InstallerTargetPath -ObsRoot $root -RelativePath $relativePath
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
            throw "Installer policy failed; missing required file: $relativePath"
        }
    }

    $files = @(Get-ChildItem -LiteralPath $root -Recurse -File)
    $relativeFiles = @($files | ForEach-Object {
        ConvertTo-InstallerRelativePath -Root $root -Path $_.FullName
    })
    $unexpected = @($relativeFiles | Where-Object { $expected -notcontains $_ })
    if ($unexpected.Count -gt 0) {
        throw "Installer policy failed; unexpected files: $($unexpected -join ', ')"
    }

    $blockedExtensions = @(
        ".7z", ".bat", ".c", ".cc", ".cmake", ".cpp", ".cxx", ".exe", ".h", ".hpp",
        ".ilk", ".iobj", ".ipdb", ".iss", ".lib", ".obj", ".pdb", ".ps1", ".pt",
        ".py", ".sha256", ".tar", ".zip"
    )
    $blocked = @($files | Where-Object { $blockedExtensions -contains $_.Extension.ToLowerInvariant() })
    if ($blocked.Count -gt 0) {
        throw "Installer policy failed; source, archive, or build files are forbidden: " +
            (@($blocked | ForEach-Object {
                ConvertTo-InstallerRelativePath -Root $root -Path $_.FullName
            }) -join ', ')
    }

    $privateNamePattern = '(?i)(^|[\\/])(?:yolo26[^\\/]*|[^\\/]*pose[^\\/]*|private[^\\/]*)($|[\\/])'
    $privatePaths = @($relativeFiles | Where-Object { $_ -match $privateNamePattern })
    if ($privatePaths.Count -gt 0) {
        throw "Installer policy failed; private model, pose, or notice names are forbidden: $($privatePaths -join ', ')"
    }
    $models = @(Get-ChildItem -LiteralPath (
        Join-Path $root "data\obs-plugins\obs-auto-framing\models") -File)
    if ($models.Count -ne 1 -or $models[0].Name -cne "yolox_tiny.onnx") {
        throw "Installer policy failed; the normal installer must contain only yolox_tiny.onnx."
    }
}

function Test-InstallerOwnershipManifest {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][object[]]$Policy,
        [Parameter(Mandatory = $true)][string]$ObsRoot,
        [Parameter(Mandatory = $true)][string]$InstalledVersion
    )

    function Invalid([string]$Reason) {
        return [pscustomobject]@{ Valid = $false; Reason = $Reason; Records = @() }
    }

    if ($null -eq $Manifest.Metadata -or $null -eq $Manifest.Files) {
        return Invalid "Manifest metadata or file records are missing."
    }
    $metadata = $Manifest.Metadata
    $rootExpected = [System.IO.Path]::GetFullPath($ObsRoot).TrimEnd('\', '/')
    try {
        $rootRecorded = [System.IO.Path]::GetFullPath([string]$metadata.ObsRoot).TrimEnd('\', '/')
    }
    catch {
        return Invalid "Manifest OBS root is invalid."
    }
    if ([string]$metadata.SchemaVersion -cne "1" -or
        [string]$metadata.InstalledVersion -cne $InstalledVersion -or
        [string]$metadata.FileCount -cne ([string]$Policy.Count) -or
        $metadata.Complete -isnot [bool] -or -not $metadata.Complete -or
        $rootRecorded -ine $rootExpected) {
        return Invalid "Manifest metadata is incomplete or inconsistent."
    }

    $records = @($Manifest.Files)
    if ($records.Count -ne $Policy.Count) {
        return Invalid "Manifest file count does not match the compiled payload."
    }
    for ($index = 0; $index -lt $Policy.Count; $index++) {
        $record = $records[$index]
        $expected = $Policy[$index]
        if ([string]$record.Id -cne $expected.Id -or
            [string]$record.RelativePath -cne $expected.RelativePath -or
            [string]$record.InstalledVersion -cne $InstalledVersion -or
            [string]$record.InstalledSHA256 -cne $expected.InstalledHash -or
            $record.Shared -isnot [bool] -or $record.Shared -ne $expected.Shared -or
            $record.RemoveOnUninstall -isnot [bool] -or
            $record.RemoveOnUninstall -ne $expected.RemoveOnUninstall -or
            $record.CreatedByInstaller -isnot [bool] -or
            $record.ExistedBefore -isnot [bool] -or
            ([string]$record.OriginalSHA256 -ne "" -and
                [string]$record.OriginalSHA256 -notmatch '^[0-9a-f]{64}$')) {
            return Invalid "Manifest file record $index does not match the compiled payload."
        }
        try {
            $null = Resolve-InstallerTargetPath -ObsRoot $ObsRoot `
                -RelativePath ([string]$record.RelativePath)
        }
        catch {
            return Invalid "Manifest file record $index contains an unsafe path."
        }
    }
    return [pscustomobject]@{ Valid = $true; Reason = ""; Records = $records }
}

function Get-InstallerPreflightPlan {
    param(
        [Parameter(Mandatory = $true)][string]$ObsRoot,
        [Parameter(Mandatory = $true)][object[]]$Policy,
        [Parameter(Mandatory = $true)][string]$InstalledVersion,
        $ExistingManifest
    )

    $validatedManifest = $null
    if ($null -ne $ExistingManifest) {
        $validatedManifest = Test-InstallerOwnershipManifest -Manifest $ExistingManifest `
            -Policy $Policy -ObsRoot $ObsRoot -InstalledVersion $InstalledVersion
        if (-not $validatedManifest.Valid) {
            throw "Existing installer manifest is invalid; no payload files may be changed. $($validatedManifest.Reason)"
        }
    }

    $plan = [System.Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $Policy.Count; $index++) {
        $item = $Policy[$index]
        $target = Resolve-InstallerTargetPath -ObsRoot $ObsRoot -RelativePath $item.RelativePath
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
            $plan.Add([pscustomobject]@{
                Id = $item.Id; Action = "InstallNew"; CreatedByInstaller = $true
                ExistedBefore = $false; OriginalSHA256 = ""; TargetPath = $target
            })
            continue
        }

        $currentHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $target).Hash.ToLowerInvariant()
        if ($null -ne $validatedManifest) {
            $record = $validatedManifest.Records[$index]
            if ($currentHash -cne $item.InstalledHash) {
                throw "Installer-owned payload '$($item.RelativePath)' was modified; no files may be changed."
            }
            $plan.Add([pscustomobject]@{
                Id = $item.Id; Action = "CarryPriorInstallerOwnership"
                CreatedByInstaller = [bool]$record.CreatedByInstaller
                ExistedBefore = [bool]$record.ExistedBefore
                OriginalSHA256 = [string]$record.OriginalSHA256
                TargetPath = $target
            })
            continue
        }

        $recognizedCurrentPackage =
            $item.RecognizedManualUpgrade -and $currentHash -ceq $item.InstalledHash
        $recognizedPrevious =
            $item.RecognizedManualUpgrade -and $item.PreviousHashes -ccontains $currentHash
        if (-not $recognizedCurrentPackage -and -not $recognizedPrevious) {
            throw "Unknown or modified payload '$($item.RelativePath)' already exists; no files may be changed."
        }

        $plan.Add([pscustomobject]@{
            Id = $item.Id
            Action = if ($item.Shared -and $currentHash -ceq $item.InstalledHash) {
                "ReuseShared"
            }
            else {
                "UpgradeRecognizedManual"
            }
            CreatedByInstaller = -not $item.Shared
            ExistedBefore = $true
            OriginalSHA256 = $currentHash
            TargetPath = $target
        })
    }
    return @($plan)
}

function New-InstallerOwnershipManifest {
    param(
        [Parameter(Mandatory = $true)][string]$ObsRoot,
        [Parameter(Mandatory = $true)][object[]]$Policy,
        [Parameter(Mandatory = $true)][object[]]$Plan,
        [Parameter(Mandatory = $true)][string]$InstalledVersion
    )

    $files = for ($index = 0; $index -lt $Policy.Count; $index++) {
        [pscustomobject]@{
            Id = $Policy[$index].Id
            RelativePath = $Policy[$index].RelativePath
            InstalledVersion = $InstalledVersion
            InstalledSHA256 = $Policy[$index].InstalledHash
            CreatedByInstaller = [bool]$Plan[$index].CreatedByInstaller
            ExistedBefore = [bool]$Plan[$index].ExistedBefore
            OriginalSHA256 = [string]$Plan[$index].OriginalSHA256
            Shared = [bool]$Policy[$index].Shared
            RemoveOnUninstall = [bool]$Policy[$index].RemoveOnUninstall
        }
    }
    return [pscustomobject]@{
        Metadata = [pscustomobject]@{
            SchemaVersion = "1"; InstalledVersion = $InstalledVersion
            ObsRoot = [System.IO.Path]::GetFullPath($ObsRoot).TrimEnd('\', '/')
            FileCount = [string]$Policy.Count; Complete = $true
        }
        Files = @($files)
    }
}

function Get-InstallerUninstallPlan {
    param(
        [Parameter(Mandatory = $true)][string]$ObsRoot,
        [Parameter(Mandatory = $true)][object[]]$Policy,
        [Parameter(Mandatory = $true)][string]$InstalledVersion,
        [Parameter(Mandatory = $true)]$Manifest
    )

    $validation = Test-InstallerOwnershipManifest -Manifest $Manifest -Policy $Policy `
        -ObsRoot $ObsRoot -InstalledVersion $InstalledVersion
    if (-not $validation.Valid) {
        return @($Policy | ForEach-Object {
            [pscustomobject]@{
                Id = $_.Id; Action = "PreserveInvalidManifest"
                Reason = "Manifest invalid: $($validation.Reason)"
                Path = Resolve-InstallerTargetPath -ObsRoot $ObsRoot -RelativePath $_.RelativePath
            }
        })
    }

    $result = for ($index = 0; $index -lt $Policy.Count; $index++) {
        $item = $Policy[$index]
        $record = $validation.Records[$index]
        $target = Resolve-InstallerTargetPath -ObsRoot $ObsRoot -RelativePath $item.RelativePath
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
            [pscustomobject]@{ Id = $item.Id; Action = "Absent"; Reason = "Already absent."; Path = $target }
            continue
        }
        $currentHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $target).Hash.ToLowerInvariant()
        if ($currentHash -cne $item.InstalledHash) {
            [pscustomobject]@{
                Id = $item.Id; Action = "PreserveModified"
                Reason = "Current hash differs from compiled installed hash."; Path = $target
            }
        }
        elseif (-not $record.CreatedByInstaller -or -not $item.RemoveOnUninstall) {
            [pscustomobject]@{
                Id = $item.Id; Action = "PreservePreExisting"
                Reason = "The installer did not create this file."; Path = $target
            }
        }
        else {
            [pscustomobject]@{
                Id = $item.Id; Action = "RemoveOwned"
                Reason = "Compiled identity, installed hash, and ownership agree."; Path = $target
            }
        }
    }
    return @($result)
}

function Assert-ReleaseChecksum {
    param(
        [Parameter(Mandatory = $true)][string]$ArtifactPath,
        [Parameter(Mandatory = $true)][string]$ChecksumPath
    )
    if (-not (Test-Path -LiteralPath $ArtifactPath -PathType Leaf)) {
        throw "Release artifact not found: $ArtifactPath"
    }
    if (-not (Test-Path -LiteralPath $ChecksumPath -PathType Leaf)) {
        throw "Release checksum not found: $ChecksumPath"
    }
    $checksumText = (Get-Content -Raw -LiteralPath $ChecksumPath).Trim()
    $expectedName = [System.IO.Path]::GetFileName($ArtifactPath)
    if ($checksumText -notmatch '^([0-9a-fA-F]{64}) \*(.+)$' -or $Matches[2] -cne $expectedName) {
        throw "Invalid SHA-256 checksum file: $ChecksumPath"
    }
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $ArtifactPath).Hash -ine $Matches[1]) {
        throw "SHA-256 mismatch for $expectedName."
    }
}

function Assert-StagingMatchesZip {
    param(
        [Parameter(Mandatory = $true)][string]$StagingRoot,
        [Parameter(Mandatory = $true)][string]$ZipPath
    )
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $root = (Resolve-Path -LiteralPath $StagingRoot).Path
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $entries = @($archive.Entries | Where-Object { -not [string]::IsNullOrEmpty($_.Name) })
        $entryNames = @($entries | ForEach-Object { $_.FullName.Replace('/', '\') })
        $stagedFiles = @(Get-ChildItem -LiteralPath $root -Recurse -File)
        $stagedNames = @($stagedFiles | ForEach-Object {
            ConvertTo-InstallerRelativePath -Root $root -Path $_.FullName
        })
        if (@($entryNames | Where-Object { $stagedNames -notcontains $_ }).Count -gt 0 -or
            @($stagedNames | Where-Object { $entryNames -notcontains $_ }).Count -gt 0) {
            throw "Validated ZIP entries do not match installer staging."
        }
        foreach ($entry in $entries) {
            $stagedPath = Resolve-InstallerTargetPath -ObsRoot $root -RelativePath $entry.FullName
            $stream = $entry.Open()
            try {
                $sha = [System.Security.Cryptography.SHA256]::Create()
                try {
                    $entryHash = [System.BitConverter]::ToString(
                        $sha.ComputeHash($stream)).Replace("-", "")
                }
                finally { $sha.Dispose() }
            }
            finally { $stream.Dispose() }
            if ($entryHash -ine (Get-FileHash -Algorithm SHA256 -LiteralPath $stagedPath).Hash) {
                throw "Validated ZIP content differs from installer staging: $($entry.FullName)"
            }
        }
    }
    finally { $archive.Dispose() }
}
