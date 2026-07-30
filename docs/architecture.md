# Architecture

## Pipeline

`filter_video` captures supported source frames. A worker owns detector initialization and inference, publishes
generation-tagged results, and never runs on the OBS render thread. `video_tick` consumes detections, advances the
selected tracker, updates Subject Lock and crop state, and publishes atomic crop values. `video_render` only applies
the prepared crop.

The worker has one replaceable pending frame. Newer eligible work replaces obsolete pending work, so slow inference
cannot create queue growth. `DetectionSchedulingState`, protected by `detection_scheduling_mutex`, owns submission and
detection-age timestamps, the detector-only inference EMA, reacquisition state, completion-event accounting, and the
effective interval. The configured interval remains the user's target. Uncertain, reacquiring, and occlusion-hold
states request a bounded burst interval, while the smoothed inference cost and safety multiplier establish a minimum
effective interval that slow hardware can actually sustain.

A settings update assigns the new settings and increments `pipeline_generation` in the same `settings_mutex` critical
section. Every tick captures those values as one immutable snapshot and never reloads a newer generation for older
settings. Reset then invalidates pending work and clears scheduling and result state through their normal mutexes
without incrementing the generation again. Completed detector inference—not a scheduling check—counts as a
reacquisition attempt. Pending completions use a generation-scoped saturating counter, so multiple worker completions
cannot collapse into one event or cross a reset. A bounded failure latches until the triggering condition clears,
preventing rapid timeout/restart loops.

## Authority and recovery

Detection produces candidates. ByteTrack or Simple IoU owns identity and continuity. Subject Lock filters tracked IDs;
it cannot create or replace an identity. ByteTrack creates tracks only from high-confidence candidates.
Lower-confidence candidates may continue compatible active tracks but cannot create arbitrary subjects. Recently lost
recovery requires spatial compatibility and is time-bounded. Occlusion hold is predicted, time-bounded, and does not
change IDs. Live tracker, Subject Lock, detector-age, and completion snapshots feed the reacquisition state machine
once per tick. Only a current detector result with a compatible high-confidence candidate is a stable confirmation.
That confirmation starts the stable-recovery window. Neutral prediction ticks preserve the window, while a later
detector completion without confirmation resets it. Detection staleness scales with the inference-budget-aware
effective interval so slow, healthy inference does not continuously trigger reacquisition.

## Shared state

Locks are narrow and snapshot-oriented: settings, detector lifecycle, pending worker input, detection scheduling,
published results, tracker state, runtime text, and debug data have separate synchronization. Expensive inference,
tracking, crop calculation, logging, and property formatting occur without the scheduling lock.

The worker's final generation check is inside `detection_result_mutex`, making validation atomic with result
publication. Published results must match the consuming tick's captured generation. An old tick that encounters a
newer result leaves it available for the next tick. A copied result is revalidated while holding `tracking_mutex`
immediately before tracker application.

Major tick commit stages revalidate the captured generation: worker submission, tracker/crop state, processed
detection time, completion consumption and reacquisition, runtime statistics, and debug overlay data. Tick-owned
runtime fields are committed as one snapshot. Completion events are consumed only by a tick with the same generation.
The tracker-lock-wins ordering permits a current tick already holding `tracking_mutex` to finish its local commit;
reset has already advanced the generation and clears that state after it obtains the lock. If reset wins first, the
old tick observes the new generation and abandons all remaining work. Runtime and debug publication use the same
generation guard, so cleared state cannot be repopulated by an old tick.

For a current completion the worker uses result → scheduling → runtime order. Reset increments the generation while
holding `settings_mutex`, then takes result, scheduling, tracking, debug, and runtime locks sequentially rather than
nesting them. It never takes the detector lock from a result or scheduling critical section. Therefore a worker either
publishes before reset and the reset clears it, or observes the new generation while holding the result lock and
discards it.

## Crop and failure behavior

The crop controller owns presenter/group selection, aspect preservation, zoom limits, bounds clamping, dead-zone and
smoothing behavior, and return to full frame. Invalid or non-finite geometry is rejected. Missing models or detector
errors publish no usable target and allow the crop to return safely to the full source.

## Distribution boundary

Public inference is YOLOX-compatible. YOLOX-Tiny is the bundled/default CPU model; Nano, S, and compatible custom ONNX
models remain optional. Packages use explicit allowlists and generated models, archives, installers, checksums, and
build output remain outside source control.
