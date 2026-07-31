# Install OBS Auto Framing

OBS Auto Framing v0.2.0 Preview is available as a Windows installer and a portable/manual ZIP. Both contain only the
public YOLOX-Tiny package and use ONNX Runtime CPU by default.

## Recommended Windows installer

1. Close OBS Studio.
2. Download `obs-auto-framing-v0.2.0-windows-x64-installer.exe` and its `.sha256` file.
3. Run the installer. Administrator permission is required when OBS is under Program Files.
4. Select the OBS root containing `bin\64bit\obs64.exe`.
5. Start OBS, select a video source, open Filters, and add the `Auto Framing` video filter.

The installer supports the standard Program Files installation, custom installation paths, portable OBS roots, and
prepared development/runtime roots. It refuses an invalid directory and never creates a fake OBS installation. It
also refuses installation, upgrade, repair, and uninstallation while `obs64.exe` is running.

For unattended installation into a user-writable portable or test root, pass `/CURRENTUSER` together with Inno
Setup's silent options and `/DIR=<OBS root>`. Program Files installations keep the default administrator requirement.
Silent validation failures return a nonzero process exit code.

The v0.2.0 installer is currently unsigned. Windows SmartScreen may warn about an unsigned new application; verify
the downloaded SHA-256 checksum and that the file came from the project’s GitHub Release before continuing.

## Portable or manual ZIP

1. Close OBS Studio.
2. Find the OBS root containing `bin\64bit\obs64.exe`.
3. Extract `obs-auto-framing-v0.2.0-windows-x64.zip` into that root.
4. Start OBS and add the `Auto Framing` video filter.

The release ZIP installs this runtime layout:

```text
obs-plugins\64bit\obs-auto-framing.dll
obs-plugins\64bit\onnxruntime.dll
data\obs-plugins\obs-auto-framing\effects\crop.effect
data\obs-plugins\obs-auto-framing\locale\en-US.ini
data\obs-plugins\obs-auto-framing\models\yolox_tiny.onnx
```

The ZIP also contains `README.md`, `LICENSE`, `SECURITY.md`, `docs\install.md`, `docs\troubleshooting.md`, and
`THIRD_PARTY_NOTICES.md`.

## Upgrade behavior

The installer uses one stable AppId across public versions and remembers the selected OBS root. Repair or upgrade
defaults to that same standard, custom, or portable root and validates it again before writing. Silent repair fails
if a remembered root is no longer valid unless `/DIR=<valid OBS root>` is supplied.

Installing v0.2.0 over the exact published v0.1.1 manual ZIP layout recognizes the verified v0.1.1 hashes for the
plugin DLL, effect, locale, YOLOX-Tiny model, and shared runtime. The v0.2.0 replacements for the four non-shared
plugin files become installer-owned and are removable on uninstall. OBS scenes, profiles, source settings, and
plugin configuration are not removed.

`obs-plugins\64bit\onnxruntime.dll` is treated as shared. An identical pre-existing runtime is reused. The installer
also recognizes the exact runtime published in the v0.1.1 public ZIP and replaces it as the documented compatibility
decision for that supported upgrade. Any other differing runtime stops installation with a compatibility message
instead of being silently replaced. A recognized v0.1.1 or otherwise pre-existing runtime remains classified as
shared/pre-existing and is preserved on uninstall. A runtime first created by this installer is removable only while
its hash still matches the compiled installed hash.

Every expected destination is classified before any payload write. An existing non-shared file that is neither
proven by a complete valid installer manifest nor an exact recognized public package file is rejected as unknown or
locally modified. The installer does not overwrite or back up that file; it leaves the entire payload unchanged.

## Default model policy

The normal installer and ZIP contain only `yolox_tiny.onnx`. YOLOX-Nano, YOLOX-S, and compatible custom YOLOX models
remain optional. This release does not include YOLO26 or pose models.

Recommended first settings:

- Detection Model: `Balanced - YOLOX-Tiny`
- Tracking Algorithm: `ByteTrack`
- Framing Preset: `Headroom` or `Presenter Smooth`

## Uninstall

Installer users can remove OBS Auto Framing through Windows Installed Apps or the generated uninstaller under:

```text
<ObsRoot>\data\obs-plugins\obs-auto-framing\installer
```

Close OBS first. Uninstall candidates come only from the 11-file payload descriptor compiled into the installer.
Manifest paths, IDs, file counts, hashes, and shared/removal classifications are checked against that descriptor and
never select deletion targets. A file is removed only when the complete manifest is valid, its fixed allowlisted
path and compiled installed hash agree, its current hash is unchanged, and its recorded provenance permits removal.

If any manifest metadata or record is missing, malformed, swapped, duplicated, or changed, the uninstaller logs the
validation reason and preserves every payload file. It also preserves modified files and all pre-existing files,
including a pre-existing or subsequently changed shared ONNX Runtime. Empty OBS Auto Framing-owned directories are
removed only after valid cleanup; generic OBS directories are never recursively deleted.

ZIP installations require manual removal. Close OBS, remove
`obs-plugins\64bit\obs-auto-framing.dll` and `data\obs-plugins\obs-auto-framing`, and remove
`obs-plugins\64bit\onnxruntime.dll` only when no other OBS plugin depends on it.

## Development/runtime installation

For local testing against an OBS build runtime:

```powershell
.\scripts\install_to_obs.ps1 `
    -PluginBuildDir .\build_x64\bin\RelWithDebInfo `
    -ObsRuntimeRoot <ObsRuntimeRoot>
```

`install_to_obs.ps1` is for local testing. `scripts\package_release.ps1` and `scripts\build_installer.ps1` create
public release artifacts.
