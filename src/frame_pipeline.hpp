#pragma once

#include <cstdint>

namespace autoframing {

struct PendingFrameMetadata {
    bool available = false;
    uint64_t timestamp_ns = 0;
    uint64_t generation = 0;
    uint64_t replacement_count = 0;
};

inline bool submit_pending_frame(PendingFrameMetadata& pending, uint64_t timestamp_ns, uint64_t generation) {
    if (generation == 0 || (pending.available && timestamp_ns < pending.timestamp_ns)) {
        return false;
    }
    if (pending.available) {
        ++pending.replacement_count;
    }
    pending.available = true;
    pending.timestamp_ns = timestamp_ns;
    pending.generation = generation;
    return true;
}

inline void invalidate_pending_frame(PendingFrameMetadata& pending) {
    pending.available = false;
    pending.timestamp_ns = 0;
    pending.generation = 0;
}

inline bool pipeline_generation_is_current(uint64_t work_generation, uint64_t current_generation) {
    return work_generation != 0 && work_generation == current_generation;
}

} // namespace autoframing
