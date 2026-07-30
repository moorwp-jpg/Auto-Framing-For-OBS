[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

function Get-InstallerExpectedRelativePaths {
    return @(
        "obs-plugins\64bit\obs-auto-framing.dll",
        "obs-plugins\64bit\onnxruntime.dll",
        "data\obs-plugins\obs-auto-framing\effects\crop.effect",
        "data\obs-plugins\obs-auto-framing\locale\en-US.ini",
        "data\obs-plugins\obs-auto-framing\models\yolox_tiny.onnx",
        "docs\install.md",
        "docs\troubleshooting.md",
        "LICENSE",
        "README.md",
        "SECURITY.md",
        "THIRD_PARTY_NOTICES.md"
    )
}

function ConvertTo-InstallerRelativePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $pathFull = [System.IO.Path]::GetFullPath($Path)
    $rootPrefix = $rootFull + [System.IO.Path]::DirectorySeparatorChar
    if (-not $pathFull.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside the expected root: $Path"
    }

    return $pathFull.Substring($rootPrefix.Length).Replace('/', '\')
}

function Resolve-InstallerTargetPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ObsRoot,

        [Parameter(Mandatory = $true)]
        [string]$RelativePath
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath)) {
        throw "Installer manifest path is empty."
    }
    if ([System.IO.Path]::IsPathRooted($RelativePath) -or
        $RelativePath.StartsWith('\') -or
        $RelativePath.StartsWith('/') -or
        $RelativePath.Contains(':')) {
        throw "Installer manifest path must be relative: $RelativePath"
    }

    $segments = @($RelativePath.Replace('/', '\').Split('\'))
    if ($segments.Count -eq 0 -or
        @($segments | Where-Object { [string]::IsNullOrWhiteSpace($_) -or $_ -eq "." -or $_ -eq ".." }).Count -gt 0) {
        throw "Installer manifest path contains invalid or traversing segments: $RelativePath"
    }

    $rootFull = [System.IO.Path]::GetFullPath($ObsRoot).TrimEnd('\', '/')
    $targetFull = [System.IO.Path]::GetFullPath((Join-Path $rootFull ($segments -join '\')))
    $rootPrefix = $rootFull + [System.IO.Path]::DirectorySeparatorChar
    if (-not $targetFull.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Installer manifest path escapes the OBS root: $RelativePath"
    }

    return $targetFull
}

function Test-ObsInstallationRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ObsRoot
    )

    try {
        $rootFull = [System.IO.Path]::GetFullPath($ObsRoot)
    }
    catch {
        return $false
    }

    return (Test-Path -LiteralPath (Join-Path $rootFull "bin\64bit\obs64.exe") -PathType Leaf)
}

function Assert-InstallerStaging {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StagingRoot
    )

    if (-not (Test-Path -LiteralPath $StagingRoot -PathType Container)) {
        throw "Installer staging directory not found: $StagingRoot"
    }

    $root = (Resolve-Path -LiteralPath $StagingRoot).Path
    $expected = @(Get-InstallerExpectedRelativePaths)
    $expectedNormalized = @($expected | ForEach-Object { $_.Replace('/', '\') })

    foreach ($relativePath in $expectedNormalized) {
        $resolved = Resolve-InstallerTargetPath -ObsRoot $root -RelativePath $relativePath
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
            throw "Installer policy failed; missing required file: $relativePath"
        }
    }

    $files = @(Get-ChildItem -LiteralPath $root -Recurse -File)
    $relativeFiles = @($files | ForEach-Object {
        ConvertTo-InstallerRelativePath -Root $root -Path $_.FullName
    })
    $unexpected = @($relativeFiles | Where-Object { $expectedNormalized -notcontains $_ })
    if ($unexpected.Count -gt 0) {
        throw "Installer policy failed; unexpected files: $($unexpected -join ', ')"
    }

    $blockedExtensions = @(
        ".7z", ".bat", ".c", ".cc", ".cmake", ".cpp", ".cxx", ".exe", ".h", ".hpp",
        ".ilk", ".iobj", ".ipdb", ".iss", ".lib", ".obj", ".pdb", ".ps1", ".pt",
        ".py", ".sha256", ".tar", ".zip"
    )
    $blocked = @($files | Where-Object {
        $blockedExtensions -contains $_.Extension.ToLowerInvariant()
    })
    if ($blocked.Count -gt 0) {
        $blockedRelative = @($blocked | ForEach-Object {
            ConvertTo-InstallerRelativePath -Root $root -Path $_.FullName
        })
        throw "Installer policy failed; source, archive, or build files are forbidden: $($blockedRelative -join ', ')"
    }

    $privateNamePattern = '(?i)(^|[\\/])(?:yolo26[^\\/]*|[^\\/]*pose[^\\/]*|private[^\\/]*)($|[\\/])'
    $privatePaths = @($relativeFiles | Where-Object { $_ -match $privateNamePattern })
    if ($privatePaths.Count -gt 0) {
        throw "Installer policy failed; private model, pose, or notice names are forbidden: $($privatePaths -join ', ')"
    }

    $models = @(Get-ChildItem -LiteralPath (Join-Path $root "data\obs-plugins\obs-auto-framing\models") -File)
    if ($models.Count -ne 1 -or $models[0].Name -cne "yolox_tiny.onnx") {
        throw "Installer policy failed; the normal installer must contain only yolox_tiny.onnx."
    }
}

function Assert-ReleaseChecksum {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ArtifactPath,

        [Parameter(Mandatory = $true)]
        [string]$ChecksumPath
    )

    if (-not (Test-Path -LiteralPath $ArtifactPath -PathType Leaf)) {
        throw "Release artifact not found: $ArtifactPath"
    }
    if (-not (Test-Path -LiteralPath $ChecksumPath -PathType Leaf)) {
        throw "Release checksum not found: $ChecksumPath"
    }

    $checksumText = (Get-Content -Raw -LiteralPath $ChecksumPath).Trim()
    $expectedName = [System.IO.Path]::GetFileName($ArtifactPath)
    if ($checksumText -notmatch '^([0-9a-fA-F]{64}) \*(.+)$') {
        throw "Invalid SHA-256 checksum format: $ChecksumPath"
    }
    if ($Matches[2] -cne $expectedName) {
        throw "Checksum names '$($Matches[2])', expected '$expectedName'."
    }

    $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $ArtifactPath).Hash
    if ($actualHash -ine $Matches[1]) {
        throw "SHA-256 mismatch for $expectedName."
    }
}

function Assert-StagingMatchesZip {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StagingRoot,

        [Parameter(Mandatory = $true)]
        [string]$ZipPath
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
                    $entryHash = [System.BitConverter]::ToString($sha.ComputeHash($stream)).Replace("-", "")
                }
                finally {
                    $sha.Dispose()
                }
            }
            finally {
                $stream.Dispose()
            }

            $stagedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $stagedPath).Hash
            if ($entryHash -ine $stagedHash) {
                throw "Validated ZIP content differs from installer staging: $($entry.FullName)"
            }
        }
    }
    finally {
        $archive.Dispose()
    }
}

function Get-SharedRuntimePolicy {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ObsRoot,

        [Parameter(Mandatory = $true)]
        [string]$BundledRuntimePath
    )

    $target = Resolve-InstallerTargetPath -ObsRoot $ObsRoot -RelativePath "obs-plugins\64bit\onnxruntime.dll"
    $bundledHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $BundledRuntimePath).Hash.ToLowerInvariant()
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
        return [pscustomobject]@{
            Action = "Install"
            ExistedBefore = $false
            OriginalHash = ""
            InstalledHash = $bundledHash
        }
    }

    $originalHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $target).Hash.ToLowerInvariant()
    return [pscustomobject]@{
        Action = if ($originalHash -eq $bundledHash) { "Reuse" } else { "RejectConflict" }
        ExistedBefore = $true
        OriginalHash = $originalHash
        InstalledHash = $bundledHash
    }
}

function Get-UninstallOwnershipDecision {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ObsRoot,

        [Parameter(Mandatory = $true)]
        [string]$RelativePath,

        [Parameter(Mandatory = $true)]
        [string]$InstalledHash,

        [Parameter(Mandatory = $true)]
        [bool]$CreatedByInstaller,

        [Parameter(Mandatory = $true)]
        [bool]$SharedRuntime
    )

    $target = Resolve-InstallerTargetPath -ObsRoot $ObsRoot -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
        return [pscustomobject]@{ Action = "Absent"; Reason = "File is already absent."; Path = $target }
    }

    $currentHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $target).Hash
    if ($currentHash -ine $InstalledHash) {
        return [pscustomobject]@{ Action = "Preserve"; Reason = "File changed after installation."; Path = $target }
    }
    if ($SharedRuntime -and -not $CreatedByInstaller) {
        return [pscustomobject]@{ Action = "Preserve"; Reason = "Shared runtime existed before installation."; Path = $target }
    }

    return [pscustomobject]@{ Action = "Remove"; Reason = "Installed hash and ownership match."; Path = $target }
}
