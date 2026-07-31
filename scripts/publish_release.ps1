<#
.SYNOPSIS
Validates the four public Windows release assets and optionally creates a GitHub prerelease.

.DESCRIPTION
Dry run is the default. Pass -Publish -Draft to create the preferred inspection draft,
or -Publish only after final maintainer approval to create the final prerelease.
#>
[CmdletBinding()]
param(
    [string]$Tag,
    [string]$Title,
    [string]$OutputDir = "out/release",
    [string]$NotesPath,
    [string]$TargetSha,
    [switch]$Publish,
    [switch]$Draft,
    [switch]$NoAuthCheck
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "release_policy.ps1")

$releaseRepository = "moorwp-jpg/Auto-Framing-For-OBS"

function ConvertTo-ProjectPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $script:ProjectRoot $Path))
}

function Resolve-RequiredFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Description not found: $Path"
    }
    return (Resolve-Path -LiteralPath $Path).Path
}

function Assert-AssetChecksum {
    param(
        [Parameter(Mandatory = $true)][string]$ArtifactPath,
        [Parameter(Mandatory = $true)][string]$ChecksumPath
    )
    $checksumText = (Get-Content -Raw -LiteralPath $ChecksumPath).Trim()
    $artifactName = [System.IO.Path]::GetFileName($ArtifactPath)
    if ($checksumText -notmatch '^([0-9a-fA-F]{64}) \*(.+)$' -or
        $Matches[2] -cne $artifactName) {
        throw "Invalid SHA-256 checksum file: $ChecksumPath"
    }
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $ArtifactPath).Hash -ine $Matches[1]) {
        throw "SHA-256 mismatch for $artifactName."
    }
}

function Resolve-GitHubCli {
    $command = Get-Command gh -ErrorAction SilentlyContinue
    if ($null -ne $command) { return $command.Source }
    foreach ($candidate in @(
        "C:\Program Files\GitHub CLI\gh.exe",
        "C:\Program Files (x86)\GitHub CLI\gh.exe",
        (Join-Path $env:LOCALAPPDATA "Programs\GitHub CLI\gh.exe")
    )) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and
            (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    return $null
}

function Invoke-GitText {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $output = & git @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed: $($output | Out-String)"
    }
    return ($output | Out-String).Trim()
}

$script:ProjectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$buildspec = Get-Content -Raw -LiteralPath (
    Join-Path $ProjectRoot "buildspec.json") | ConvertFrom-Json
$pluginName = [string]$buildspec.name
$displayName = [string]$buildspec.displayName
$version = [string]$buildspec.version
$releaseChannel = [string]$buildspec.releaseChannel
if ([string]::IsNullOrWhiteSpace($pluginName) -or
    [string]::IsNullOrWhiteSpace($displayName) -or
    [string]::IsNullOrWhiteSpace($version) -or
    [string]::IsNullOrWhiteSpace($releaseChannel)) {
    throw "buildspec.json is missing required release metadata."
}
if ([string]::IsNullOrWhiteSpace($Tag)) { $Tag = "v$version" }
if ($Tag -cne "v$version") {
    throw "Release tag '$Tag' does not match buildspec version '$version'."
}
if ([string]::IsNullOrWhiteSpace($Title)) {
    $Title = "$displayName v$version $releaseChannel"
}
if ([string]::IsNullOrWhiteSpace($NotesPath)) {
    $NotesPath = "docs/release_notes/$Tag.md"
}
if ($Publish -and $NoAuthCheck) {
    throw "-NoAuthCheck is permitted only for a dry run."
}
if ($Publish -and -not [string]::IsNullOrWhiteSpace($TargetSha)) {
    throw "-TargetSha is permitted only for dry runs; publishing derives it from verified main."
}
if ($releaseChannel -ine "Preview") {
    throw "This publisher is configured for a Preview prerelease, found '$releaseChannel'."
}

$outputPath = ConvertTo-ProjectPath -Path $OutputDir
$baseName = "$pluginName-$Tag-windows-x64"
$zipPath = Resolve-RequiredFile (Join-Path $outputPath "$baseName.zip") "Release ZIP"
$zipChecksumPath = Resolve-RequiredFile "$zipPath.sha256" "Release ZIP checksum"
$installerPath = Resolve-RequiredFile (Join-Path $outputPath "$baseName-installer.exe") `
    "Release installer"
$installerChecksumPath = Resolve-RequiredFile "$installerPath.sha256" `
    "Release installer checksum"
$notesPathResolved = Resolve-RequiredFile (ConvertTo-ProjectPath $NotesPath) "Release notes"
Assert-AssetChecksum $zipPath $zipChecksumPath
Assert-AssetChecksum $installerPath $installerChecksumPath
$assets = @($installerPath, $installerChecksumPath, $zipPath, $zipChecksumPath)

$ghPath = $null
if (-not $NoAuthCheck) {
    $ghPath = Resolve-GitHubCli
    if ([string]::IsNullOrWhiteSpace($ghPath)) {
        throw "GitHub CLI 'gh' was not found. Install it and run 'gh auth login'."
    }
    & $ghPath auth status *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "GitHub CLI authentication failed. Run 'gh auth login' and try again."
    }
}

if ($Publish) {
    $fetchOutput = & git fetch --prune origin main --tags 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "git fetch --prune origin main --tags failed: $($fetchOutput | Out-String)"
    }
    $branch = Invoke-GitText @("branch", "--show-current")
    $status = Invoke-GitText @("status", "--porcelain")
    $headSha = Invoke-GitText @("rev-parse", "HEAD")
    $localMain = Invoke-GitText @("rev-parse", "main")
    $trackingMain = Invoke-GitText @("rev-parse", "origin/main")
    $remoteOutput = Invoke-GitText @("ls-remote", "origin", "refs/heads/main")
    $remoteMain = ConvertFrom-LsRemoteMain $remoteOutput
    $targetSha = Assert-ReleaseMainIdentity -Branch $branch `
        -WorkingTreeStatus $status -HeadSha $headSha -LocalMainSha $localMain `
        -TrackingMainSha $trackingMain -RemoteMainSha $remoteMain
}
else {
    if ([string]::IsNullOrWhiteSpace($TargetSha)) {
        $targetSha = Invoke-GitText @("rev-parse", "main")
    }
    elseif ($TargetSha -notmatch '^[0-9a-fA-F]{40}$') {
        throw "-TargetSha must be a full 40-character commit SHA."
    }
    else {
        $targetSha = $TargetSha.ToLowerInvariant()
    }
}

$releaseArguments = New-ReleaseCreateArguments -Repository $releaseRepository `
    -Tag $Tag -Title $Title -NotesPath $notesPathResolved -Assets $assets `
    -TargetSha $targetSha -Draft:$Draft
$commandPreview = "gh " + (Format-ReleaseCommandLine $releaseArguments)

if (-not $Publish) {
    Write-Host "Dry run only. No tag or GitHub release was created."
    if ($NoAuthCheck) { Write-Host "GitHub CLI authentication was skipped for this dry run." }
    Write-Host "Validated release assets:"
    $assets | ForEach-Object { Write-Host "  $_" }
    Write-Host "Release target:"
    Write-Host "  $targetSha"
    Write-Host "Command that would be run:"
    Write-Host "  $commandPreview"
    exit 0
}

& git show-ref --verify --quiet "refs/tags/$Tag"
$localTagExists = $LASTEXITCODE -eq 0
$remoteTag = & git ls-remote --tags origin "refs/tags/$Tag" 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Could not verify the remote tag state: $($remoteTag | Out-String)"
}
& $ghPath release view $Tag --repo $releaseRepository *> $null
$releaseExists = $LASTEXITCODE -eq 0
Assert-ReleaseAvailability -LocalTagExists $localTagExists `
    -RemoteTagOutput (($remoteTag | Out-String).Trim()) `
    -ReleaseExists $releaseExists -Tag $Tag

Write-Host "Creating GitHub Preview prerelease $Tag at $targetSha..."
Write-Host $commandPreview
& $ghPath @releaseArguments
if ($LASTEXITCODE -ne 0) {
    throw "GitHub Release publishing failed with exit code $LASTEXITCODE."
}
Write-Host "GitHub prerelease created: $Tag"
