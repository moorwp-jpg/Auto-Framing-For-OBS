# Script guidance

- Use `$ErrorActionPreference = "Stop"` and validate paths and inputs explicitly.
- Resolve project-relative paths safely, including paths containing spaces.
- Package from explicit public allowlists and never include non-public models or notices.
- Tests never publish, install, uninstall, or alter repository settings; publishing defaults to dry run.
- Keep generated artifacts outside Git and make missing-input and include/exclude errors actionable.
