[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$scripts = @(Get-ChildItem -LiteralPath (Join-Path $projectRoot "scripts") -Recurse -File -Filter "*.ps1")
$failed = $false

foreach ($script in $scripts) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$tokens, [ref]$errors)
    foreach ($parseError in $errors) {
        $failed = $true
        Write-Error -ErrorAction Continue (
            "{0}:{1}:{2}: {3}" -f $script.FullName, $parseError.Extent.StartLineNumber,
            $parseError.Extent.StartColumnNumber, $parseError.Message
        )
    }
}

if ($failed) {
    throw "PowerShell syntax validation failed."
}
Write-Host "PowerShell syntax validation passed for $($scripts.Count) scripts."
