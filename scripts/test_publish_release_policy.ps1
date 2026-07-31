[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "release_policy.ps1")

function Assert-Rejected {
    param([scriptblock]$Action, [string]$Description)
    try { & $Action }
    catch {
        Write-Host "Rejected as expected: $Description"
        return
    }
    throw "Release policy failed to reject: $Description"
}

$sha = "1234567890abcdef1234567890abcdef12345678"
$assets = @("installer.exe", "installer.exe.sha256", "package.zip", "package.zip.sha256")
$arguments = @(New-ReleaseCreateArguments `
    -Repository "moorwp-jpg/Auto-Framing-For-OBS" -Tag "v0.2.0" `
    -Title "OBS Auto Framing v0.2.0 Preview" -NotesPath "notes.md" `
    -Assets $assets -TargetSha $sha -Draft)

foreach ($required in @(
    "--prerelease", "--draft", "--target", $sha, "--repo",
    "moorwp-jpg/Auto-Framing-For-OBS"
)) {
    if ($arguments -cnotcontains $required) {
        throw "Release command is missing required argument: $required"
    }
}
Assert-Rejected {
    New-ReleaseCreateArguments -Repository "owner/repo" -Tag "v0.2.0" -Title "title" `
        -NotesPath "notes" -Assets $assets -TargetSha "main"
} "symbolic release target"
Assert-Rejected {
    New-ReleaseCreateArguments -Repository "owner/repo" -Tag "v0.2.0" -Title "title" `
        -NotesPath "notes" -Assets @("one") -TargetSha $sha
} "incomplete asset list"

$identity = Assert-ReleaseMainIdentity -Branch "main" -WorkingTreeStatus "" `
    -HeadSha $sha -LocalMainSha $sha -TrackingMainSha $sha -RemoteMainSha $sha
if ($identity -cne $sha) { throw "Matching release main identity was not returned." }
foreach ($case in @(
    @{ Branch = "feature"; Status = ""; Head = $sha; Local = $sha; Tracking = $sha; Remote = $sha },
    @{ Branch = "main"; Status = " M file"; Head = $sha; Local = $sha; Tracking = $sha; Remote = $sha },
    @{ Branch = "main"; Status = ""; Head = $sha; Local = ("a" * 40); Tracking = $sha; Remote = $sha },
    @{ Branch = "main"; Status = ""; Head = $sha; Local = $sha; Tracking = ("b" * 40); Remote = $sha },
    @{ Branch = "main"; Status = ""; Head = $sha; Local = $sha; Tracking = $sha; Remote = ("c" * 40) }
)) {
    Assert-Rejected {
        Assert-ReleaseMainIdentity -Branch $case.Branch -WorkingTreeStatus $case.Status `
            -HeadSha $case.Head -LocalMainSha $case.Local `
            -TrackingMainSha $case.Tracking -RemoteMainSha $case.Remote
    } "unsafe publish identity"
}

if ((ConvertFrom-LsRemoteMain "$sha`trefs/heads/main") -cne $sha) {
    throw "Direct remote main output was not parsed."
}
Assert-Rejected {
    ConvertFrom-LsRemoteMain "$sha`trefs/heads/main`n$sha`trefs/heads/other"
} "ambiguous direct remote output"

Assert-Rejected {
    Assert-ReleaseAvailability -LocalTagExists $true -RemoteTagOutput "" `
        -ReleaseExists $false -Tag "v0.2.0"
} "existing local tag"
Assert-Rejected {
    Assert-ReleaseAvailability -LocalTagExists $false `
        -RemoteTagOutput "$sha`trefs/tags/v0.2.0" -ReleaseExists $false -Tag "v0.2.0"
} "existing remote tag"
Assert-Rejected {
    Assert-ReleaseAvailability -LocalTagExists $false -RemoteTagOutput "" `
        -ReleaseExists $true -Tag "v0.2.0"
} "existing GitHub release"
if ((Get-ReleaseOperation -Publish $false) -cne "DryRunNoWrite") {
    throw "Default release operation was not a no-write dry run."
}

Write-Host "Release publisher policy tests passed."
