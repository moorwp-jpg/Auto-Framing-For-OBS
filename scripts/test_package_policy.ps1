[CmdletBinding()]
param(
    [ValidateSet("Debug", "Release", "RelWithDebInfo", "MinSizeRel")]
    [string]$BuildConfig = "RelWithDebInfo"
)

$ErrorActionPreference = "Stop"
$packageScript = Join-Path $PSScriptRoot "package_release.ps1"

function Assert-PackageRejected {
    param(
        [string[]]$Arguments,
        [string]$Description
    )

    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $packageScript `
        -BuildConfig $BuildConfig -NoChecksum @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorAction
    if ($exitCode -eq 0) {
        throw "Package policy failed to reject: $Description"
    }
    Write-Host "Rejected as expected: $Description"
}

foreach ($blockedContent in "Pt", "NestedZip", "Pdb", "UnexpectedModel", "SourceFile") {
    Assert-PackageRejected -Arguments @("-TestBlockedContent", $blockedContent) -Description $blockedContent
}
Assert-PackageRejected -Arguments @("-TestOmitTiny") -Description "missing YOLOX-Tiny"

Write-Host "Public package policy rejection tests passed."
