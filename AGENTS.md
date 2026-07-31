# Codex Repository Guide

## Repository purpose

This is the stable public preview repository for Auto Framing For OBS. Experimental work is developed separately and
must not be mentioned, copied, or enabled accidentally. Public changes use conservative defaults and dependencies
that can be distributed publicly.

## Architecture invariants

- Detection provides candidates; ByteTrack or Simple IoU owns track identity and continuity.
- Subject Lock constrains selection of tracked identities.
- Inference never runs on the OBS render thread.
- Worker scheduling remains bounded and stale pipeline generations are rejected.
- Missing models fail safely.
- YOLOX-Tiny is the public/default model, and packages remain functional without non-public assets.

## Generated artifacts

Never commit `.onnx`, `.pt`, `.zip`, `.exe`, `.pdb`, `.sha256`, build or package-staging directories, generated
installers, or downloaded third-party binaries.

## Verification

Run:

```powershell
pwsh -NoProfile -File scripts/verify_repo.ps1
```

## Definition of done

Relevant tests, C++ formatting, and PowerShell syntax checks pass. Review public packaging boundaries and documentation,
introduce no non-public references or artifacts, and report manual OBS validation truthfully.
