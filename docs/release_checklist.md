# v0.2.0 Preview release checklist

Use this checklist first on the release-preparation PR, then repeat it against artifacts built from the merged public
`main`. Do not tag or publish from a feature branch.

## Repository and verification

- [ ] Confirm `buildspec.json` reports `0.2.0` and `Preview`.
- [ ] Confirm the working tree is clean and public `main` matches `origin/main`.
- [ ] Run canonical RelWithDebInfo verification.
- [ ] Run canonical Debug verification.
- [ ] Build the full public plugin with MSVC.
- [ ] Confirm the compiled plugin reports `0.2.0 Preview`.
- [ ] Run `scripts\test_package_policy.ps1`.
- [ ] Run `scripts\test_installer_policy.ps1`.
- [ ] Run `scripts\test_publish_release_policy.ps1`.

## Package and installer

- [ ] Run `scripts\package_release.ps1`.
- [ ] Confirm the ZIP and staging match the allowlist in `docs\release_layout.md`.
- [ ] Confirm YOLOX-Tiny is present and Nano, S, YOLO26, pose, private assets, sources, PDBs, and nested archives are absent.
- [ ] Run `scripts\build_installer.ps1` with Inno Setup 6.7.3 or newer; record the detected compiler path and version.
- [ ] Confirm `RedirectionGuard=yes`, `AllowUNCPath=no`, and `AllowNetworkDrive=no` remain explicit.
- [ ] Confirm the installer is unsigned unless an actual code-signing step was completed.
- [ ] Record SHA-256 hashes for the ZIP and installer.

## Runtime validation

- [ ] Clean install into a disposable OBS 32.1.2 root.
- [ ] Reject a root without `bin\64bit\obs64.exe` and confirm no files were written.
- [ ] Reject install while `obs64.exe` is running.
- [ ] Reinstall/repair v0.2.0 without duplicate or nested paths.
- [ ] Upgrade the v0.1.1 public manual layout while preserving OBS configuration.
- [ ] Uninstall that upgrade and confirm the plugin DLL, effect, locale, Tiny model, and installer docs are gone.
- [ ] Reject unknown or modified plugin, effect, and model files before any payload write.
- [ ] Tamper the manifest path to `bin\64bit\obs64.exe`; confirm uninstall preserves every payload and OBS file.
- [ ] Repair a custom path containing spaces without `/DIR`; confirm the remembered root and ownership are retained.
- [ ] Reject UNC and mapped network-drive roots before any payload write; retain local custom and portable support.
- [ ] Confirm the runtime harness validates the exact published v0.1.1 ZIP SHA-256 before extracting it.
- [ ] Confirm a different pre-existing ONNX Runtime is not silently replaced.
- [ ] Uninstall only hash-proven plugin-owned files.
- [ ] Preserve pre-existing and modified shared ONNX Runtime files.
- [ ] Confirm OBS and unrelated files remain functional after uninstall.
- [ ] Validate silent install and uninstall success and failure exit codes.
- [ ] Confirm the Auto Framing filter appears, YOLOX-Tiny initializes, Runtime Statistics are coherent, and video tests pass.

## Release dry run and post-merge publication

- [ ] Review `docs\release_notes\v0.2.0.md`.
- [ ] Confirm all workflow `uses:` entries remain full-SHA pinned and use Node.js 24-compatible actions.
- [ ] Run `scripts\publish_release.ps1 -NoAuthCheck` and confirm all four assets, exact `--target`, and exact `--repo` appear.
- [ ] Merge only after PR review; do not merge automatically.
- [ ] Rebuild and retest exact final artifacts from merged `main`.
- [ ] Confirm publishing fetches `origin main --tags` and direct remote `main` equals the validated local `HEAD`.
- [ ] Run `scripts\publish_release.ps1 -Publish -Draft`.
- [ ] Inspect tag `v0.2.0`, title `Auto Framing For OBS v0.2.0 Preview`, prerelease status, notes, sizes, and all hashes.
- [ ] Publish the draft only after final maintainer review.
