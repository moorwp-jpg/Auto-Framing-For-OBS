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

    update_reacquisition(runtime, config, {1300000000ULL, false, false, false, false, false, true});
    update_reacquisition(runtime, config, {1800000000ULL, false, false, false, false, false, true});
    require(runtime.state == ReacquisitionState::Stable && runtime.successes == 1,
            "stable confirmations end reacquisition");

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
    require(consume_detector_completion(scheduling), "completion event is consumed once");
    require(!consume_detector_completion(scheduling), "completion event is not counted twice");

    scheduling.reacquisition.state = ReacquisitionState::Reacquiring;
    require(update_effective_detection_interval(scheduling, 150) == 150 && scheduling.interval_budget_limited,
            "inference budget limits a requested burst");
    reset_detection_scheduling(scheduling, 200);
    require(update_effective_detection_interval(scheduling, 200) == 200,
            "stable scheduling uses the configured interval");

    ReacquisitionConfig bounded = public_reacquisition_config(150);
    bounded.maximum_attempts = 2;
    ReacquisitionRuntime persistent;
    update_reacquisition(persistent, bounded, {1000000000ULL, false, true});
    require(persistent.state == ReacquisitionState::Uncertain && persistent.attempts == 0,
            "lock loss starts uncertainty without counting a scheduling check");
    update_reacquisition(persistent, bounded, {1100000000ULL, false, true, false, false, false, false, true});
    require(persistent.attempts == 1, "one completed detector inference counts as one attempt");
    update_reacquisition(persistent, bounded, {1200000000ULL, false, true, false, false, false, false, true});
    require(persistent.state == ReacquisitionState::Stable && persistent.failures == 1 && persistent.failure_latched,
            "maximum real attempts latch a bounded failure");
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
