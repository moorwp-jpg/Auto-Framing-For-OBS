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
    [switch]$Publish,
    [switch]$Draft,
    [switch]$NoAuthCheck
)

$ErrorActionPreference = "Stop"

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
    if ($checksumText -notmatch '^([0-9a-fA-F]{64}) \*(.+)$') {
        throw "Invalid SHA-256 checksum format: $ChecksumPath"
    }
    if ($Matches[2] -cne $artifactName) {
        throw "Checksum file names '$($Matches[2])', expected '$artifactName'."
    }
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $ArtifactPath).Hash
    if ($actual -ine $Matches[1]) {
        throw "SHA-256 mismatch for $artifactName."
    }
}

function Quote-Argument {
    param([Parameter(Mandatory = $true)][string]$Argument)

    if ($Argument -match '^[A-Za-z0-9_./:=+\\-]+$') {
        return $Argument
    }
    return '"' + ($Argument -replace '"', '\"') + '"'
}

function Format-CommandLine {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    return ($Arguments | ForEach-Object { Quote-Argument -Argument $_ }) -join " "
}

function Resolve-GitHubCli {
    $command = Get-Command gh -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }
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
$buildspec = Get-Content -Raw -LiteralPath (Join-Path $ProjectRoot "buildspec.json") | ConvertFrom-Json
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
if ([string]::IsNullOrWhiteSpace($Tag)) {
    $Tag = "v$version"
}
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
if ($releaseChannel -ine "Preview") {
    throw "This publisher is configured for a Preview prerelease, found channel '$releaseChannel'."
}

$outputPath = ConvertTo-ProjectPath -Path $OutputDir
$baseName = "$pluginName-$Tag-windows-x64"
$zipPath = Resolve-RequiredFile -Path (Join-Path $outputPath "$baseName.zip") -Description "Release ZIP"
$zipChecksumPath = Resolve-RequiredFile -Path "$zipPath.sha256" -Description "Release ZIP checksum"
$installerPath = Resolve-RequiredFile -Path (Join-Path $outputPath "$baseName-installer.exe") -Description "Release installer"
$installerChecksumPath = Resolve-RequiredFile -Path "$installerPath.sha256" -Description "Release installer checksum"
$notesPathResolved = Resolve-RequiredFile -Path (ConvertTo-ProjectPath -Path $NotesPath) -Description "Release notes"

Assert-AssetChecksum -ArtifactPath $zipPath -ChecksumPath $zipChecksumPath
Assert-AssetChecksum -ArtifactPath $installerPath -ChecksumPath $installerChecksumPath

$assets = @($installerPath, $installerChecksumPath, $zipPath, $zipChecksumPath)
$releaseArguments = @("release", "create", $Tag) + $assets + @(
    "--title", $Title,
    "--notes-file", $notesPathResolved,
    "--prerelease"
)
if ($Draft) {
    $releaseArguments += "--draft"
}
$commandPreview = "gh " + (Format-CommandLine -Arguments $releaseArguments)

$ghPath = $null
if (-not $NoAuthCheck) {
    $ghPath = Resolve-GitHubCli
    if ([string]::IsNullOrWhiteSpace($ghPath)) {
        throw "GitHub CLI 'gh' was not found. Install it from https://cli.github.com/ and run 'gh auth login'."
    }
    & $ghPath auth status *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "GitHub CLI authentication failed. Run 'gh auth login' and try again."
    }
}

if (-not $Publish) {
    Write-Host "Dry run only. No tag or GitHub release was created."
    if ($NoAuthCheck) {
        Write-Host "GitHub CLI authentication was skipped for this dry run."
    }
    Write-Host "Validated release assets:"
    foreach ($asset in $assets) {
        Write-Host "  $asset"
    }
    Write-Host "Release notes:"
    Write-Host "  $notesPathResolved"
    Write-Host "Command that would be run:"
    Write-Host "  $commandPreview"
    exit 0
}

$branch = Invoke-GitText -Arguments @("branch", "--show-current")
if ($branch -cne "main") {
    throw "Publishing is allowed only from main; current branch is '$branch'."
}
$status = Invoke-GitText -Arguments @("status", "--porcelain")
if (-not [string]::IsNullOrWhiteSpace($status)) {
    throw "Publishing requires a clean working tree."
}
$localMain = Invoke-GitText -Arguments @("rev-parse", "main")
$originMain = Invoke-GitText -Arguments @("rev-parse", "origin/main")
if ($localMain -cne $originMain) {
    throw "Local main ($localMain) does not match origin/main ($originMain). Pull the merged public main first."
}

& git show-ref --verify --quiet "refs/tags/$Tag"
if ($LASTEXITCODE -eq 0) {
    throw "Tag already exists locally: $Tag"
}
$remoteTag = & git ls-remote --tags origin "refs/tags/$Tag" 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Could not verify the remote tag state: $($remoteTag | Out-String)"
}
if (-not [string]::IsNullOrWhiteSpace(($remoteTag | Out-String).Trim())) {
    throw "Tag already exists on origin: $Tag"
}

& $ghPath release view $Tag *> $null
if ($LASTEXITCODE -eq 0) {
    throw "GitHub release already exists: $Tag"
}

Write-Host "Creating GitHub Preview prerelease $Tag..."
Write-Host $commandPreview
& $ghPath @releaseArguments
if ($LASTEXITCODE -ne 0) {
    throw "GitHub Release publishing failed with exit code $LASTEXITCODE."
}
Write-Host "GitHub prerelease created: $Tag"
