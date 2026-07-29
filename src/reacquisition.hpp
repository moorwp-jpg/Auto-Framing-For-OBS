#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>

namespace autoframing {

enum class ReacquisitionState {
    Stable,
    Uncertain,
    Reacquiring,
    OcclusionHold,
};

inline const char* reacquisition_state_to_string(ReacquisitionState state) {
    switch (state) {
    case ReacquisitionState::Uncertain:
        return "Uncertain";
    case ReacquisitionState::Reacquiring:
        return "Reacquiring";
    case ReacquisitionState::OcclusionHold:
        return "Occlusion hold";
    case ReacquisitionState::Stable:
    default:
        return "Stable";
    }
}

struct ReacquisitionConfig {
    uint32_t normal_interval_ms = 150;
    uint32_t burst_interval_ms = 75;
    uint32_t uncertain_delay_ms = 150;
    uint32_t stable_recovery_ms = 450;
    uint32_t maximum_burst_ms = 2500;
    uint32_t maximum_attempts = 12;
    double inference_safety_multiplier = 1.25;
};

struct ReacquisitionInput {
    uint64_t now_ns = 0;
    bool occlusion_hold = false;
    bool locked_subject_missing = false;
    bool low_confidence_update = false;
    bool stale_detection = false;
    bool recently_lost_recovery = false;
    bool high_confidence_confirmation = false;
    bool detection_attempted = false;
};

struct ReacquisitionRuntime {
    ReacquisitionState state = ReacquisitionState::Stable;
    const char* reason = "stable tracking";
    uint64_t state_started_ns = 0;
    uint64_t stable_since_ns = 0;
    uint32_t attempts = 0;
    uint32_t successes = 0;
    uint32_t failures = 0;
};

inline ReacquisitionConfig public_reacquisition_config(uint32_t configured_interval_ms) {
    ReacquisitionConfig config;
    config.normal_interval_ms = std::clamp<uint32_t>(configured_interval_ms, 16, 2000);
    config.burst_interval_ms = std::max<uint32_t>(50, std::min<uint32_t>(100, config.normal_interval_ms));
    return config;
}

inline bool reacquisition_requested(const ReacquisitionInput& input) {
    return input.occlusion_hold || input.locked_subject_missing || input.low_confidence_update ||
           input.stale_detection || input.recently_lost_recovery;
}

inline const char* reacquisition_reason(const ReacquisitionInput& input) {
    if (input.locked_subject_missing)
        return "locked subject missing";
    if (input.occlusion_hold)
        return "occlusion hold";
    if (input.recently_lost_recovery)
        return "recently lost-track recovery";
    if (input.low_confidence_update)
        return "low-confidence continuation";
    if (input.stale_detection)
        return "stale detector confirmation";
    return "stable tracking";
}

inline uint64_t elapsed_ms(uint64_t start_ns, uint64_t now_ns) {
    return start_ns == 0 || now_ns < start_ns ? 0 : (now_ns - start_ns) / 1000000ULL;
}

inline void update_reacquisition(ReacquisitionRuntime& runtime, const ReacquisitionConfig& config,
                                 const ReacquisitionInput& input) {
    if (input.detection_attempted && runtime.state != ReacquisitionState::Stable &&
        runtime.attempts < std::numeric_limits<uint32_t>::max()) {
        ++runtime.attempts;
    }

    const bool requested = reacquisition_requested(input);
    if (runtime.state == ReacquisitionState::Stable && requested) {
        runtime.state = input.occlusion_hold ? ReacquisitionState::OcclusionHold : ReacquisitionState::Uncertain;
        runtime.reason = reacquisition_reason(input);
        runtime.state_started_ns = input.now_ns;
        runtime.stable_since_ns = 0;
        runtime.attempts = 0;
        return;
    }

    if (runtime.state != ReacquisitionState::Stable &&
        (elapsed_ms(runtime.state_started_ns, input.now_ns) >= config.maximum_burst_ms ||
         runtime.attempts >= config.maximum_attempts)) {
        ++runtime.failures;
        runtime = {ReacquisitionState::Stable, "reacquisition bounded timeout", 0, 0, 0, runtime.successes,
                   runtime.failures};
        return;
    }

    if (requested) {
        runtime.reason = reacquisition_reason(input);
        if (input.occlusion_hold) {
            runtime.state = ReacquisitionState::OcclusionHold;
        } else if (elapsed_ms(runtime.state_started_ns, input.now_ns) >= config.uncertain_delay_ms) {
            runtime.state = ReacquisitionState::Reacquiring;
        }
        runtime.stable_since_ns = 0;
        return;
    }

    if (runtime.state == ReacquisitionState::Stable)
        return;

    if (!input.high_confidence_confirmation) {
        runtime.stable_since_ns = 0;
        return;
    }
    if (runtime.stable_since_ns == 0)
        runtime.stable_since_ns = input.now_ns;
    if (elapsed_ms(runtime.stable_since_ns, input.now_ns) >= config.stable_recovery_ms) {
        ++runtime.successes;
        runtime = {ReacquisitionState::Stable, "stable tracking", 0, 0, 0, runtime.successes, runtime.failures};
    }
}

inline uint32_t effective_detection_interval_ms(const ReacquisitionConfig& config,
                                                const ReacquisitionRuntime& runtime, double smoothed_inference_ms,
                                                bool* budget_limited = nullptr) {
    const uint32_t requested =
        runtime.state == ReacquisitionState::Stable ? config.normal_interval_ms : config.burst_interval_ms;
    const double finite_inference = std::isfinite(smoothed_inference_ms) ? std::max(0.0, smoothed_inference_ms) : 0.0;
    const uint32_t budget = static_cast<uint32_t>(
        std::min<double>(std::numeric_limits<uint32_t>::max(),
                         std::ceil(finite_inference * config.inference_safety_multiplier)));
    const uint32_t effective = std::max(requested, budget);
    if (budget_limited)
        *budget_limited = effective > requested;
    return effective;
}

} // namespace autoframing
