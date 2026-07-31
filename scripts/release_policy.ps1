[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

function Quote-ReleaseArgument {
    param([Parameter(Mandatory = $true)][string]$Argument)
    if ($Argument -match '^[A-Za-z0-9_./:=+\\-]+$') {
        return $Argument
    }
    return '"' + ($Argument -replace '"', '\"') + '"'
}

function Format-ReleaseCommandLine {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    return ($Arguments | ForEach-Object {
        Quote-ReleaseArgument -Argument $_
    }) -join " "
}

function New-ReleaseCreateArguments {
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string]$Tag,
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$NotesPath,
        [Parameter(Mandatory = $true)][string[]]$Assets,
        [Parameter(Mandatory = $true)][string]$TargetSha,
        [switch]$Draft
    )

    if ($TargetSha -notmatch '^[0-9a-f]{40}$') {
        throw "Release target is not an exact 40-character commit SHA: $TargetSha"
    }
    if ($Assets.Count -ne 4) {
        throw "A public release must contain exactly four assets."
    }
    $arguments = @("release", "create", $Tag) + $Assets + @(
        "--title", $Title,
        "--notes-file", $NotesPath,
        "--prerelease",
        "--target", $TargetSha,
        "--repo", $Repository
    )
    if ($Draft) {
        $arguments += "--draft"
    }
    return $arguments
}

function Assert-ReleaseMainIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$Branch,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$WorkingTreeStatus,
        [Parameter(Mandatory = $true)][string]$HeadSha,
        [Parameter(Mandatory = $true)][string]$LocalMainSha,
        [Parameter(Mandatory = $true)][string]$TrackingMainSha,
        [Parameter(Mandatory = $true)][string]$RemoteMainSha
    )

    if ($Branch -cne "main") {
        throw "Publishing is allowed only from main; current branch is '$Branch'."
    }
    if (-not [string]::IsNullOrWhiteSpace($WorkingTreeStatus)) {
        throw "Publishing requires a clean working tree."
    }
    foreach ($entry in @{
        HEAD = $HeadSha
        main = $LocalMainSha
        "origin/main" = $TrackingMainSha
        "remote main" = $RemoteMainSha
    }.GetEnumerator()) {
        if ($entry.Value -notmatch '^[0-9a-f]{40}$') {
            throw "$($entry.Key) did not resolve to an exact commit SHA."
        }
    }
    if ($HeadSha -cne $LocalMainSha -or
        $HeadSha -cne $TrackingMainSha -or
        $HeadSha -cne $RemoteMainSha) {
        throw "HEAD, local main, origin/main, and the directly queried remote main must be identical."
    }
    return $HeadSha
}

function ConvertFrom-LsRemoteMain {
    param([Parameter(Mandatory = $true)][string]$Output)
    $lines = @($Output -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($lines.Count -ne 1 -or $lines[0] -notmatch '^([0-9a-f]{40})\s+refs/heads/main$') {
        throw "Direct remote main query returned an unexpected result."
    }
    return $Matches[1]
}

function Assert-ReleaseAvailability {
    param(
        [Parameter(Mandatory = $true)][bool]$LocalTagExists,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$RemoteTagOutput,
        [Parameter(Mandatory = $true)][bool]$ReleaseExists,
        [Parameter(Mandatory = $true)][string]$Tag
    )
    if ($LocalTagExists) { throw "Tag already exists locally: $Tag" }
    if (-not [string]::IsNullOrWhiteSpace($RemoteTagOutput)) {
        throw "Tag already exists on origin: $Tag"
    }
    if ($ReleaseExists) { throw "GitHub release already exists: $Tag" }
}

function Get-ReleaseOperation {
    param([bool]$Publish)
    if ($Publish) { return "Publish" }
    return "DryRunNoWrite"
}
