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

A settings or model reset increments `pipeline_generation`, invalidates pending work, and clears scheduling and result
state through their normal mutexes. Completed detector inference—not a scheduling check—counts as a reacquisition
attempt. A bounded failure latches until the triggering condition clears, preventing rapid timeout/restart loops.

## Authority and recovery

Detection produces candidates. ByteTrack or Simple IoU owns identity and continuity. Subject Lock filters tracked IDs;
it cannot create or replace an identity. ByteTrack creates tracks only from high-confidence candidates.
Lower-confidence candidates may continue compatible active tracks but cannot create arbitrary subjects. Recently lost
recovery requires spatial compatibility and is time-bounded. Occlusion hold is predicted, time-bounded, and does not
change IDs. Live tracker, Subject Lock, detector-age, and completion snapshots feed the reacquisition state machine
once per tick. Only a current detector result with a compatible high-confidence candidate is a stable confirmation.

## Shared state

Locks are narrow and snapshot-oriented: settings, detector lifecycle, pending worker input, detection scheduling,
published results, tracker state, runtime text, and debug data have separate synchronization. Expensive inference,
tracking, crop calculation, logging, and property formatting occur without the scheduling lock.

The worker's final generation check is inside `detection_result_mutex`, making validation atomic with result
publication. Published results carry `latest_detection_generation`; tick and debug consumers verify that tag again.
For a current completion the worker uses result → scheduling → runtime order. Reset increments the generation first,
then takes result, scheduling, tracking, debug, and runtime locks sequentially rather than nesting them. It never takes
the detector lock from a result or scheduling critical section. Therefore a worker either publishes before reset and
the reset clears it, or observes the new generation while holding the result lock and discards it.

## Crop and failure behavior

The crop controller owns presenter/group selection, aspect preservation, zoom limits, bounds clamping, dead-zone and
smoothing behavior, and return to full frame. Invalid or non-finite geometry is rejected. Missing models or detector
errors publish no usable target and allow the crop to return safely to the full source.

## Distribution boundary

Public inference is YOLOX-compatible. YOLOX-Tiny is the bundled/default CPU model; Nano, S, and compatible custom ONNX
models remain optional. Packages use explicit allowlists and generated models, archives, installers, checksums, and
build output remain outside source control.
