[CmdletBinding()]
param(
    [switch]$Fix
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$formatVersion = (Get-Content -LiteralPath (Join-Path $projectRoot ".clang-format-version") -Raw).Trim()
$clangFormat = if ($env:CLANG_FORMAT) { $env:CLANG_FORMAT } else { "clang-format" }

try {
    $versionText = (& $clangFormat --version 2>&1 | Out-String).Trim()
} catch {
    throw "clang-format $formatVersion.x is required. Set CLANG_FORMAT to its executable."
}
if ($LASTEXITCODE -ne 0 -or $versionText -notmatch "version\s+$([regex]::Escape($formatVersion))(\.|$)") {
    throw "Expected clang-format $formatVersion.x, found: $versionText"
}

$files = @(
    Get-ChildItem -LiteralPath (Join-Path $projectRoot "src"), (Join-Path $projectRoot "tests") -Recurse -File |
        Where-Object { $_.Extension -in ".cpp", ".hpp" } |
        Sort-Object FullName
)
if ($files.Count -eq 0) {
    throw "No C++ files were found."
}

if ($Fix) {
    & $clangFormat -i --style=file --fallback-style=none @($files.FullName)
} else {
    & $clangFormat --dry-run --Werror --style=file --fallback-style=none @($files.FullName)
}
if ($LASTEXITCODE -ne 0) {
    throw "C++ formatting check failed."
}
