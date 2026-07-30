#pragma once

#include "reacquisition.hpp"

#include <cmath>
#include <cstdint>
#include <limits>
#include <utility>

namespace autoframing {

struct PendingFrameMetadata {
    bool available = false;
    uint64_t timestamp_ns = 0;
    uint64_t generation = 0;
    uint64_t replacement_count = 0;
};

inline bool pipeline_generation_is_current(uint64_t work_generation, uint64_t current_generation) {
    return work_generation != 0 && work_generation == current_generation;
}

inline bool pending_frame_submission_is_allowed(bool pending_available, uint64_t pending_timestamp_ns,
                                                uint64_t pending_generation, uint64_t candidate_timestamp_ns,
                                                uint64_t tick_generation, uint64_t current_generation) {
    if (!pipeline_generation_is_current(tick_generation, current_generation)) {
        return false;
    }
    if (!pending_available || pending_generation != tick_generation) {
        return true;
    }
    return candidate_timestamp_ns >= pending_timestamp_ns;
}

inline bool submit_pending_frame(PendingFrameMetadata& pending, uint64_t timestamp_ns, uint64_t tick_generation,
                                 uint64_t current_generation) {
    if (!pending_frame_submission_is_allowed(pending.available, pending.timestamp_ns, pending.generation, timestamp_ns,
                                             tick_generation, current_generation)) {
        return false;
    }
    if (pending.available && pending.generation == tick_generation) {
        ++pending.replacement_count;
    }
    pending.available = true;
    pending.timestamp_ns = timestamp_ns;
    pending.generation = tick_generation;
    return true;
}

inline void invalidate_pending_frame(PendingFrameMetadata& pending) {
    pending.available = false;
    pending.timestamp_ns = 0;
    pending.generation = 0;
}

template <typename Commit>
inline bool commit_if_generation_current(uint64_t tick_generation, uint64_t current_generation, Commit&& commit) {
    if (!pipeline_generation_is_current(tick_generation, current_generation)) {
        return false;
    }
    std::forward<Commit>(commit)();
    return true;
}

enum class ResultGenerationDisposition {
    Consume,
    DiscardStale,
    LeaveAvailable,
};

inline ResultGenerationDisposition result_generation_disposition(uint64_t result_generation, uint64_t tick_generation,
                                                                 uint64_t current_generation) {
    if (!pipeline_generation_is_current(tick_generation, current_generation)) {
        return ResultGenerationDisposition::LeaveAvailable;
    }
    if (result_generation == tick_generation) {
        return ResultGenerationDisposition::Consume;
    }
    return pipeline_generation_is_current(result_generation, current_generation)
               ? ResultGenerationDisposition::LeaveAvailable
               : ResultGenerationDisposition::DiscardStale;
}

struct DetectionSchedulingState {
    uint64_t last_submit_ns = 0;
    uint64_t last_detection_age_log_ns = 0;
    uint64_t last_processed_detection_timestamp_ns = 0;
    double smoothed_detector_inference_ms = 0.0;
    double last_detector_inference_ms = 0.0;
    ReacquisitionRuntime reacquisition;
    uint32_t effective_interval_ms = 150;
    bool interval_budget_limited = false;
    uint64_t completion_generation = 0;
    uint32_t pending_detector_completions = 0;
};

inline void reset_detection_scheduling(DetectionSchedulingState& state, uint32_t configured_interval_ms) {
    state = {};
    state.effective_interval_ms = public_reacquisition_config(configured_interval_ms).normal_interval_ms;
}

inline bool record_current_detector_completion(DetectionSchedulingState& state, uint64_t completion_generation,
                                               double inference_ms, double alpha = 0.20) {
    if (completion_generation == 0 || !std::isfinite(inference_ms) || inference_ms < 0.0 || !std::isfinite(alpha) ||
        alpha <= 0.0 || alpha > 1.0) {
        return false;
    }

    if (state.pending_detector_completions > 0 && state.completion_generation != completion_generation) {
        state.pending_detector_completions = 0;
    }
    state.completion_generation = completion_generation;
    state.last_detector_inference_ms = inference_ms;
    if (state.smoothed_detector_inference_ms <= 0.0 || !std::isfinite(state.smoothed_detector_inference_ms)) {
        state.smoothed_detector_inference_ms = inference_ms;
    } else {
        state.smoothed_detector_inference_ms += alpha * (inference_ms - state.smoothed_detector_inference_ms);
    }
    if (state.pending_detector_completions < std::numeric_limits<uint32_t>::max()) {
        ++state.pending_detector_completions;
    }
    return true;
}

inline bool record_detector_completion_if_current(DetectionSchedulingState& state, uint64_t work_generation,
                                                  uint64_t current_generation, double inference_ms,
                                                  double alpha = 0.20) {
    return pipeline_generation_is_current(work_generation, current_generation) &&
           record_current_detector_completion(state, work_generation, inference_ms, alpha);
}

inline uint32_t consume_detector_completions_if_current(DetectionSchedulingState& state, uint64_t tick_generation,
                                                        uint64_t current_generation) {
    if (!pipeline_generation_is_current(tick_generation, current_generation) ||
        state.completion_generation != tick_generation) {
        return 0;
    }
    const uint32_t completions = state.pending_detector_completions;
    state.completion_generation = 0;
    state.pending_detector_completions = 0;
    return completions;
}

inline uint32_t update_effective_detection_interval(DetectionSchedulingState& state, uint32_t configured_interval_ms) {
    const ReacquisitionConfig config = public_reacquisition_config(configured_interval_ms);
    state.effective_interval_ms = effective_detection_interval_ms(
        config, state.reacquisition, state.smoothed_detector_inference_ms, &state.interval_budget_limited);
    return state.effective_interval_ms;
}

inline bool detection_submission_due(const DetectionSchedulingState& state, uint64_t now_ns) {
    if (state.last_submit_ns == 0 || now_ns < state.last_submit_ns)
        return true;
    return now_ns - state.last_submit_ns >= static_cast<uint64_t>(state.effective_interval_ms) * 1000000ULL;
}

inline double stale_detection_age_threshold_ms(uint32_t configured_interval_ms, uint32_t effective_interval_ms) {
    const uint32_t expected_interval_ms = std::max(configured_interval_ms, effective_interval_ms);
    return std::max(500.0, static_cast<double>(expected_interval_ms) * 2.0);
}

inline bool result_generation_is_consumable(uint64_t result_generation, uint64_t current_generation) {
    return pipeline_generation_is_current(result_generation, current_generation);
}

} // namespace autoframing
