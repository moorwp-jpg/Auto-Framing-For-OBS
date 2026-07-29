[CmdletBinding()]
param(
    [string]$BuildDir = "build_verify",
    [ValidateSet("Debug", "Release", "RelWithDebInfo", "MinSizeRel")]
    [string]$BuildConfig = "RelWithDebInfo",
    [switch]$Clean,
    [switch]$SkipFormat
)

$ErrorActionPreference = "Stop"
$projectRoot = (Resolve-Path -LiteralPath (Split-Path -Parent $PSScriptRoot)).Path
$resolvedBuildDir = [System.IO.Path]::GetFullPath((Join-Path $projectRoot $BuildDir))
$projectPrefix = $projectRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) +
    [System.IO.Path]::DirectorySeparatorChar
if (-not $resolvedBuildDir.StartsWith($projectPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "BuildDir must remain inside the repository: $resolvedBuildDir"
}
if ($resolvedBuildDir -eq $projectRoot) {
    throw "BuildDir cannot be the repository root."
}
if ($Clean -and (Test-Path -LiteralPath $resolvedBuildDir)) {
    Remove-Item -LiteralPath $resolvedBuildDir -Recurse -Force
}

$generatorArgs = @()
if ($env:OS -eq "Windows_NT") {
    $cl = Get-Command cl.exe -ErrorAction SilentlyContinue
    $gxx = Get-Command g++.exe -ErrorAction SilentlyContinue
    $mingwMake = Get-Command mingw32-make.exe -ErrorAction SilentlyContinue
    if ($cl) {
        $generatorArgs = @("-G", "Visual Studio 18 2026", "-A", "x64")
    } elseif ($gxx -and $mingwMake) {
        $generatorArgs = @("-G", "MinGW Makefiles")
    }
}

& cmake -S $projectRoot -B $resolvedBuildDir @generatorArgs `
    "-DBUILD_PLUGIN=OFF" "-DENABLE_TESTS=ON" "-DCMAKE_BUILD_TYPE=$BuildConfig"
if ($LASTEXITCODE -ne 0) { throw "Core configure failed." }

& cmake --build $resolvedBuildDir --config $BuildConfig
if ($LASTEXITCODE -ne 0) { throw "Core build failed." }

& ctest --test-dir $resolvedBuildDir -C $BuildConfig --output-on-failure
if ($LASTEXITCODE -ne 0) { throw "Core tests failed." }

if (-not $SkipFormat) {
    & (Join-Path $PSScriptRoot "check_format.ps1")
}
& (Join-Path $PSScriptRoot "check_powershell_syntax.ps1")
