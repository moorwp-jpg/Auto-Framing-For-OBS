# v0.2.0 Preview release layout

`<ObsRoot>` is an OBS Studio Windows x64 installation, portable root, or prepared runtime root containing
`bin\64bit\obs64.exe`.

## Validated public staging and ZIP

`scripts\package_release.ps1` builds an explicit public staging directory:

```text
out\release\staging\obs-plugins\64bit\obs-auto-framing.dll
out\release\staging\obs-plugins\64bit\onnxruntime.dll
out\release\staging\data\obs-plugins\obs-auto-framing\effects\crop.effect
out\release\staging\data\obs-plugins\obs-auto-framing\locale\en-US.ini
out\release\staging\data\obs-plugins\obs-auto-framing\models\yolox_tiny.onnx
out\release\staging\docs\install.md
out\release\staging\docs\troubleshooting.md
out\release\staging\LICENSE
out\release\staging\README.md
out\release\staging\SECURITY.md
out\release\staging\THIRD_PARTY_NOTICES.md
```

It then creates:

```text
out\release\obs-auto-framing-v0.2.0-windows-x64.zip
out\release\obs-auto-framing-v0.2.0-windows-x64.zip.sha256
```

The normal package contains only YOLOX-Tiny. `-IncludeNano` and `-IncludeSmall` remain available for intentional
non-default ZIPs, but those outputs are not valid input for the normal v0.2.0 installer.

## Installer

After packaging, run:

```powershell
.\scripts\test_installer_policy.ps1
.\scripts\build_installer.ps1
```

The installer builder verifies the ZIP checksum, compares every staged file with the ZIP, applies the installer
allowlist, and then invokes Inno Setup 6. It creates:

```text
out\release\obs-auto-framing-v0.2.0-windows-x64-installer.exe
out\release\obs-auto-framing-v0.2.0-windows-x64-installer.exe.sha256
```

Runtime files are installed into their normal OBS locations. Documentation and installer ownership data are kept
under `data\obs-plugins\obs-auto-framing`, and Inno Setup keeps its uninstaller in that same plugin-owned tree.

## Release assets

The v0.2.0 Preview prerelease must contain exactly:

```text
obs-auto-framing-v0.2.0-windows-x64-installer.exe
obs-auto-framing-v0.2.0-windows-x64-installer.exe.sha256
obs-auto-framing-v0.2.0-windows-x64.zip
obs-auto-framing-v0.2.0-windows-x64.zip.sha256
```

Generated staging, ZIP, checksum, and installer files remain ignored by Git and must not be committed.
