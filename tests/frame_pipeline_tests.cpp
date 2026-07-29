#include "frame_pipeline.hpp"
#include "reacquisition.hpp"

#include <cstdlib>
#include <iostream>

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

    std::cout << "frame pipeline tests passed\n";
    return 0;
}
