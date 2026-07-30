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
    struct TickSnapshot {
        int settings_value = 0;
        uint64_t generation = 0;
    };
    const TickSnapshot captured{14, 7};
    const uint64_t generation_after_reset = 8;
    require(captured.settings_value == 14 && captured.generation == 7,
            "settings snapshot remains associated with its captured generation");
    require(!pipeline_generation_is_current(captured.generation, generation_after_reset),
            "reset invalidates the complete settings-generation snapshot");

    PendingFrameMetadata pending;
    require(submit_pending_frame(pending, 100, 1, 1), "current tick can submit its first frame");
    require(submit_pending_frame(pending, 200, 1, 1), "newer current-generation frame replaces pending work");
    require(pending.timestamp_ns == 200 && pending.generation == 1 && pending.replacement_count == 1,
            "pending work preserves the settings snapshot generation");
    require(!submit_pending_frame(pending, 150, 1, 1), "older frame cannot replace newer same-generation work");
    require(!submit_pending_frame(pending, 300, 1, 2), "stale tick cannot submit under the live generation");
    require(submit_pending_frame(pending, 50, 2, 2), "new current tick replaces stale pending work");
    require(pending.timestamp_ns == 50 && pending.generation == 2,
            "replacement uses the generation belonging to the new settings snapshot");
    require(!submit_pending_frame(pending, 400, 1, 2), "stale tick cannot replace newer current-generation work");
    invalidate_pending_frame(pending);
    require(!pending.available && pending.generation == 0, "reset invalidates pending work");
    require(pipeline_generation_is_current(4, 4), "current generation is accepted");
    require(!pipeline_generation_is_current(3, 4), "stale generation is rejected");
    require(result_generation_is_consumable(4, 4), "current result generation is consumable");
    require(!result_generation_is_consumable(3, 4), "stale result generation is not consumable");
    const uint64_t copied_generation = 4;
    require(!result_generation_is_consumable(copied_generation, 5),
            "a generation reset after result copy invalidates tracking consumption");
    require(result_generation_disposition(4, 4, 4) == ResultGenerationDisposition::Consume,
            "result generation N is consumed only by tick N");
    require(result_generation_disposition(4, 5, 5) == ResultGenerationDisposition::DiscardStale,
            "current tick discards an obsolete result");
    require(result_generation_disposition(5, 4, 5) == ResultGenerationDisposition::LeaveAvailable,
            "old tick neither consumes nor clears a newer result");
    require(result_generation_disposition(4, 4, 5) == ResultGenerationDisposition::LeaveAvailable,
            "stale tick abandons copied state after reset");

    int processed_timestamp = 1;
    int reacquisition_state = 2;
    int runtime_state = 3;
    int debug_state = 4;
    require(!commit_if_generation_current(4, 5, [&] { processed_timestamp = 10; }),
            "stale tick cannot update the processed detection timestamp");
    require(!commit_if_generation_current(4, 5, [&] { reacquisition_state = 20; }),
            "stale tick cannot update reacquisition state");
    require(!commit_if_generation_current(4, 5, [&] { runtime_state = 30; }),
            "stale tick cannot overwrite reset runtime state");
    require(!commit_if_generation_current(4, 5, [&] { debug_state = 40; }), "stale tick cannot publish debug state");
    require(processed_timestamp == 1 && reacquisition_state == 2 && runtime_state == 3 && debug_state == 4,
            "reset-owned publication state remains unchanged after stale commit attempts");

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
    require(record_current_detector_completion(scheduling, 4, 200.0), "second finite inference updates timing");
    require(scheduling.smoothed_detector_inference_ms == 120.0, "EMA uses the stable alpha");
    require(!record_current_detector_completion(scheduling, 4, std::numeric_limits<double>::quiet_NaN()),
            "non-finite inference is ignored");
    require(!record_current_detector_completion(scheduling, 4, -1.0), "negative inference is ignored");
    require(scheduling.smoothed_detector_inference_ms == 120.0, "invalid timing preserves the EMA");
    require(consume_detector_completions_if_current(scheduling, 3, 4) == 0,
            "stale tick cannot consume current completions");
    require(scheduling.pending_detector_completions == 2, "rejected stale consumption preserves current events");
    require(consume_detector_completions_if_current(scheduling, 4, 4) == 2,
            "tick consumes all completions belonging to its generation");
    require(consume_detector_completions_if_current(scheduling, 4, 4) == 0, "completion events are not counted twice");
    require(record_current_detector_completion(scheduling, 5, 120.0), "new generation records its completion");
    require(consume_detector_completions_if_current(scheduling, 4, 5) == 0,
            "old tick cannot consume new-generation completions");
    require(scheduling.pending_detector_completions == 1 && scheduling.completion_generation == 5,
            "new-generation completion remains available");
    reset_detection_scheduling(scheduling, 150);
    require(scheduling.pending_detector_completions == 0 && scheduling.completion_generation == 0,
            "reset clears prior-generation completion state");
    scheduling.completion_generation = 5;
    scheduling.pending_detector_completions = std::numeric_limits<uint32_t>::max() - 1;
    require(record_current_detector_completion(scheduling, 5, 120.0), "completion counter accepts a finite update");
    require(record_current_detector_completion(scheduling, 5, 120.0), "completion counter safely accepts saturation");
    require(consume_detector_completions_if_current(scheduling, 5, 5) == std::numeric_limits<uint32_t>::max(),
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
