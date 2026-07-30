# Source guidance

- Preserve C++17 and follow the repository `.clang-format`.
- Keep OBS callbacks thin and portable logic in `obs-auto-framing-core`.
- Keep scheduling bounded; never perform inference in render callbacks.
- Bounds-check tensor and frame access and reject non-finite detections and geometry.
- Add focused tests for state transitions, scheduling, tracking, and geometry.
- Update `docs/architecture.md` when shared-state ownership, locking, or pipeline generations change.
