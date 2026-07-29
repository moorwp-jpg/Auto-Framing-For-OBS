# ADR 0002: Bounded asynchronous inference

Status: Accepted

Detector inference runs on a worker with one replaceable pending frame. Pipeline generations invalidate pending and
in-flight work after resets. Bounded scheduling protects render responsiveness and prevents latency accumulation on
slow hardware.
