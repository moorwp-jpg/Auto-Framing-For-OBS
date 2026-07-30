# Recommended main-branch ruleset

After CI has completed successfully, configure this manually in GitHub:

- Require pull requests and conversation resolution.
- Use zero required approvals while there is one maintainer.
- Require `Core Build & Tests (Windows)`, `C++ Format`, and `PowerShell Syntax`.
- Keep the Linux core job advisory.
- Block force pushes and restrict branch deletion.
- Initially allow administrators to bypass only through pull requests.

This repository does not configure or change its own ruleset.
