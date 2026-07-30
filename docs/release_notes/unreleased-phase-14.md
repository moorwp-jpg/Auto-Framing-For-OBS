# Unreleased public preview

- Added canonical core-only verification and read-only GitHub Actions CI.
- Bounded detector scheduling to one replaceable pending frame and rejected stale pipeline generations.
- Connected adaptive reacquisition to live OBS detector scheduling with separate configured/effective intervals,
  detector-only inference EMA budgeting, completion-based attempts, and a persistent-failure latch.
- Made final generation validation atomic with detection/timing publication and tagged results for consumption checks.
- Consolidated submission, detection-age, inference-budget, and reacquisition fields under one scheduling mutex.
- Hardened ByteTrack low-confidence continuation, bounded occlusion hold, and recently lost-track recovery.
- Rejected non-finite, negative, and greater-than-one detector confidence values before tracking.
- Expanded tracker Runtime Statistics with continuation, recovery, and occlusion counters.
- Documented Subject Lock identity authority, public YOLOX defaults, and packaging safeguards.

No release date or version is assigned.
