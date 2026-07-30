# Continuous integration

The `CI` workflow runs on pull requests, pushes to `main`, and manual dispatch with read-only contents permission and
concurrency cancellation. It does not build the OBS plugin, download OBS/ONNX Runtime/models, package, publish, or use
repository secrets.

The stable checks are `Core Build & Tests (Windows)`, `C++ Format`, and `PowerShell Syntax`. `Core Build & Tests
(Linux, advisory)` detects portability regressions but remains non-blocking.

Local equivalent:

```powershell
pwsh -NoProfile -File scripts/verify_repo.ps1 -Clean
```
