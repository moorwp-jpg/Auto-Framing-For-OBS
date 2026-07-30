#include "frame_pipeline.hpp"
#include "reacquisition.hpp"

#include <cstdlib>
#include <iostream>
#include <limits>

using namespace autoframing;

namespace {
void require(bool condition, const char* message) {
    if (!condition) {
        std::cerr << "FAILED: " << message << '\n';
        std::exit(1);
    }
}
} // namespace

int main() {
    PendingFrameMetadata pending;
    require(submit_pending_frame(pending, 100, 1), "first frame is accepted");
    require(submit_pending_frame(pending, 200, 1), "newer frame replaces pending work");
    require(pending.timestamp_ns == 200 && pending.replacement_count == 1, "slot remains bounded to newest work");
    require(!submit_pending_frame(pending, 150, 1), "older frame cannot replace newer work");
    invalidate_pending_frame(pending);
    require(!pending.available && pending.generation == 0, "reset invalidates pending work");
    require(pipeline_generation_is_current(4, 4), "current generation is accepted");
    require(!pipeline_generation_is_current(3, 4), "stale generation is rejected");
    require(result_generation_is_consumable(4, 4), "current result generation is consumable");
    require(!result_generation_is_consumable(3, 4), "stale result generation is not consumable");
    const uint64_t copied_generation = 4;
    require(!result_generation_is_consumable(copied_generation, 5),
            "a generation reset after result copy invalidates tracking consumption");

    const ReacquisitionConfig config = public_reacquisition_config(150);
    ReacquisitionRuntime runtime;
    update_reacquisition(runtime, config, {1000000000ULL, false, false, false, true});
    require(runtime.state == ReacquisitionState::Uncertain, "stale confirmation enters uncertainty");
    update_reacquisition(runtime, config, {1200000000ULL, false, false, false, true});
    require(runtime.state == ReacquisitionState::Reacquiring, "continued uncertainty enters reacquisition");

    bool limited = false;
    require(effective_detection_interval_ms(config, runtime, 100.0, &limited) == 125 && limited,
            "inference budget bounds burst scheduling");
    require(effective_detection_interval_ms(config, runtime, 20.0, &limited) == config.burst_interval_ms && !limited,
            "fast inference uses the conservative public burst target");

    update_reacquisition(runtime, config, {1300000000ULL, false, false, false, false, false, true, 1});
    update_reacquisition(runtime, config, {1500000000ULL});
    require(runtime.stable_since_ns == 1300000000ULL, "neutral prediction ticks preserve the stable recovery window");
    ReacquisitionRuntime interrupted_recovery = runtime;
    update_reacquisition(interrupted_recovery, config, {1600000000ULL, false, false, false, false, false, false, 1});
    require(interrupted_recovery.stable_since_ns == 0,
            "a detector completion without confirmation resets the stable recovery window");
    update_reacquisition(runtime, config, {1800000000ULL});
    require(runtime.state == ReacquisitionState::Stable && runtime.successes == 1,
            "one stable confirmation can recover across neutral prediction ticks");

    DetectionSchedulingState scheduling;
    reset_detection_scheduling(scheduling, 150);
    require(scheduling.effective_interval_ms == 150, "reset restores configured stable interval");
    require(!record_detector_completion_if_current(scheduling, 3, 4, 100.0), "stale inference cannot update timing");
    require(scheduling.smoothed_detector_inference_ms == 0.0, "stale inference preserves the timing average");
    require(record_detector_completion_if_current(scheduling, 4, 4, 100.0), "current inference updates timing");
    require(scheduling.smoothed_detector_inference_ms == 100.0, "first inference initializes the EMA");
    require(record_current_detector_completion(scheduling, 200.0), "second finite inference updates timing");
    require(scheduling.smoothed_detector_inference_ms == 120.0, "EMA uses the stable alpha");
    require(!record_current_detector_completion(scheduling, std::numeric_limits<double>::quiet_NaN()),
            "non-finite inference is ignored");
    require(!record_current_detector_completion(scheduling, -1.0), "negative inference is ignored");
    require(scheduling.smoothed_detector_inference_ms == 120.0, "invalid timing preserves the EMA");
    require(consume_detector_completions(scheduling) == 2, "all queued detector completions are consumed");
    require(consume_detector_completions(scheduling) == 0, "completion events are not counted twice");
    scheduling.pending_detector_completions = std::numeric_limits<uint32_t>::max() - 1;
    require(record_current_detector_completion(scheduling, 120.0), "completion counter accepts a finite update");
    require(record_current_detector_completion(scheduling, 120.0), "completion counter safely accepts saturation");
    require(consume_detector_completions(scheduling) == std::numeric_limits<uint32_t>::max(),
            "completion counter saturates instead of wrapping");

    scheduling.reacquisition.state = ReacquisitionState::Reacquiring;
    require(update_effective_detection_interval(scheduling, 150) == 150 && scheduling.interval_budget_limited,
            "inference budget limits a requested burst");
    reset_detection_scheduling(scheduling, 200);
    require(update_effective_detection_interval(scheduling, 200) == 200,
            "stable scheduling uses the configured interval");
    require(stale_detection_age_threshold_ms(150, 150) == 500.0, "normal stale detection keeps the conservative floor");
    require(stale_detection_age_threshold_ms(150, 800) == 1600.0,
            "slow effective inference expands the stale detection window");

    ReacquisitionConfig bounded = public_reacquisition_config(150);
    bounded.maximum_attempts = 2;
    ReacquisitionRuntime persistent;
    update_reacquisition(persistent, bounded, {1000000000ULL, false, true});
    require(persistent.state == ReacquisitionState::Uncertain && persistent.attempts == 0,
            "lock loss starts uncertainty without counting a scheduling check");
    update_reacquisition(persistent, bounded, {1100000000ULL, false, true, false, false, false, false, 2});
    require(persistent.state == ReacquisitionState::Stable && persistent.failures == 1 && persistent.failure_latched,
            "multiple completed detector inferences count separately and latch a bounded failure");
    update_reacquisition(persistent, bounded, {1300000000ULL, false, true});
    require(persistent.state == ReacquisitionState::Stable && persistent.failures == 1 && persistent.failure_latched,
            "persistent trigger does not immediately restart after timeout");
    update_reacquisition(persistent, bounded, {1400000000ULL});
    require(!persistent.failure_latched, "clearing the trigger releases the failure latch");
    update_reacquisition(persistent, bounded, {1500000000ULL, true});
    require(persistent.state == ReacquisitionState::OcclusionHold,
            "a fresh occlusion trigger may start a new bounded cycle");

    require(reacquisition_requested({0, true}), "occlusion hold requests reacquisition");
    require(reacquisition_requested({0, false, true}), "Subject Lock loss requests reacquisition");
    require(reacquisition_requested({0, false, false, true}), "low-confidence continuation requests reacquisition");
    require(reacquisition_requested({0, false, false, false, false, true}),
            "recently lost recovery requests reacquisition");

    std::cout << "frame pipeline tests passed\n";
    return 0;
}
