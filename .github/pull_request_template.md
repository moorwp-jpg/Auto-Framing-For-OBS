## Summary

Describe the public-facing change and why it is safe for preview users.

## Verification

- [ ] `pwsh -NoProfile -File scripts/verify_repo.ps1`
- [ ] Packaging boundary reviewed when applicable
- [ ] Documentation updated when behavior or workflow changed

## Validation status

- Full plugin build: not run / passed / failed
- Public package validation: not run / passed / failed
- Manual OBS validation: not run / performed (describe)

## Public boundary

- [ ] No generated models, packages, installers, checksums, build output, or private assets are included.
- [ ] YOLOX-Tiny remains the default public model.
