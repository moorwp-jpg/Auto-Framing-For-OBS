# ADR 0001: Tracking owns identity

Status: Accepted

Person detection produces candidates. ByteTrack or Simple IoU exclusively creates and maintains track IDs. Subject
Lock constrains selection using those IDs. This prevents confidence fluctuations or composition logic from silently
switching subjects.
