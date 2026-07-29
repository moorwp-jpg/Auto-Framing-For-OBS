# Contributing

Windows is the primary supported platform. Portable core development requires CMake, a C++17 compiler, PowerShell,
and clang-format 22.x; it does not require OBS, ONNX Runtime, or model files.

Run the canonical checks before opening a pull request:

```powershell
pwsh -NoProfile -File scripts/verify_repo.ps1 -Clean
```

Keep OBS callbacks thin, place portable behavior in `obs-auto-framing-core`, preserve bounded scheduling and
generation rejection, and add focused tests for behavioral changes. Public packages use YOLOX-Tiny by default.
Generated models, build output, archives, installers, and checksums are release artifacts and must not be committed.

Pull requests must state which automated checks, full plugin build, package validation, and manual OBS tests were
actually performed.
