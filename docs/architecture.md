# Architecture

## Pipeline

`filter_video` captures supported source frames. A worker owns detector initialization and inference, publishes
generation-tagged results, and never runs on the OBS render thread. `video_tick` consumes detections, advances the
selected tracker, updates Subject Lock and crop state, and publishes atomic crop values. `video_render` only applies
the prepared crop.

The worker has one replaceable pending frame. Newer eligible work replaces obsolete pending work, so slow inference
cannot create queue growth. A settings or model reset increments `pipeline_generation`, invalidates pending work, and
causes in-flight results from older generations to be discarded before publication.

## Authority and recovery

Detection produces candidates. ByteTrack or Simple IoU owns identity and continuity. Subject Lock filters tracked IDs;
it cannot create or replace an identity. ByteTrack creates tracks only from high-confidence candidates.
Lower-confidence candidates may continue compatible active tracks but cannot create arbitrary subjects. Recently lost
recovery requires spatial compatibility and is time-bounded. Occlusion hold is predicted, time-bounded, and does not
change IDs.

## Shared state

Locks are narrow and snapshot-oriented: settings, detector lifecycle, pending worker input, published results, tracker
state, runtime text, and debug data have separate synchronization. Expensive inference and formatting occur without
holding unrelated locks. Reset paths take these locks sequentially.

## Crop and failure behavior

The crop controller owns presenter/group selection, aspect preservation, zoom limits, bounds clamping, dead-zone and
smoothing behavior, and return to full frame. Invalid or non-finite geometry is rejected. Missing models or detector
errors publish no usable target and allow the crop to return safely to the full source.

## Distribution boundary

Public inference is YOLOX-compatible. YOLOX-Tiny is the bundled/default CPU model; Nano, S, and compatible custom ONNX
models remain optional. Packages use explicit allowlists and generated models, archives, installers, checksums, and
build output remain outside source control.
