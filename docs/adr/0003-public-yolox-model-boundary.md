# ADR 0003: Public YOLOX model boundary

Status: Accepted

The public detector path accepts YOLOX-Nano, YOLOX-Tiny, YOLOX-S, and compatible custom ONNX models. YOLOX-Tiny with
ONNX Runtime CPU is the default and bundled baseline. Package validation admits only explicitly selected public
payloads.
