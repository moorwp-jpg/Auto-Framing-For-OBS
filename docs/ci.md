# Continuous integration

The `CI` workflow runs on pull requests, pushes to `main`, and manual dispatch with read-only contents permission and
concurrency cancellation. It does not build the OBS plugin, download OBS/ONNX Runtime/models, package, publish, or use
repository secrets.

The five job display names are `Core Build & Tests (Windows)`, `C++ Format`, `PowerShell Syntax`, `Public Installer
Policy`, and `Core Build & Tests (Linux, advisory)`. Linux remains non-blocking.

Every current `uses:` entry is the full SHA
`actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1` (v7.0.1), with
`persist-credentials: false`. That action's exact `action.yml` declares `using: node24`; there are no nested or other
JavaScript actions in the workflow. The current PR run contains no Node.js 20 action in its workflow or job log, so
the reviewed Node.js 20 warning was stale or a runner-transition annotation rather than a current action requiring
an upgrade. No `setup-node`, insecure Node fallback, or runtime-forcing environment variable is used.

Local equivalent:

```powershell
pwsh -NoProfile -File scripts/verify_repo.ps1 -Clean
```
