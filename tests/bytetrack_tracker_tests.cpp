#include "tracker/bytetrack_tracker.hpp"

#include <algorithm>
#include <cmath>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>

using namespace autoframing;

namespace {

void require(bool condition, const std::string& message) {
    if (!condition) {
        throw std::runtime_error(message);
    }
}

Detection detection(Rect box, float confidence) {
    Detection result;
    result.box = box;
    result.confidence = confidence;
    result.class_id = 0;
    return result;
}

ByteTrackConfig test_config() {
    ByteTrackConfig config;
    config.track_high_thresh = 0.50f;
    config.track_low_thresh = 0.10f;
    config.new_track_thresh = 0.60f;
    config.match_thresh = 0.20f;
    config.track_buffer_frames = 2;
    config.occlusion_hold_ms = 0;
    config.locked_occlusion_hold_ms = 0;
    return config;
}

std::vector<int> sorted_ids(const std::vector<PersonTrack>& tracks) {
    std::vector<int> ids;
    ids.reserve(tracks.size());
    for (const PersonTrack& track : tracks) {
        ids.push_back(track.id);
    }
    std::sort(ids.begin(), ids.end());
    return ids;
}

PersonTrack debug_track_by_id(const ByteTrackTracker& tracker, int id) {
    for (const PersonTrack& track : tracker.debug_tracks()) {
        if (track.id == id) {
            return track;
        }
    }
    throw std::runtime_error("debug track id not found");
}

void stable_id_across_moving_detections() {
    ByteTrackTracker tracker(test_config());

    std::vector<PersonTrack> tracks = tracker.update({detection({100.0f, 100.0f, 60.0f, 160.0f}, 0.90f)}, 1);
    require(tracks.size() == 1, "first moving detection creates one track");
    const int id = tracks.front().id;

    for (int frame = 2; frame <= 8; ++frame) {
        const float x = 100.0f + static_cast<float>(frame - 1) * 6.0f;
        tracks = tracker.update({detection({x, 100.0f, 60.0f, 160.0f}, 0.88f)}, static_cast<uint64_t>(frame));
        require(tracks.size() == 1, "moving detection keeps one active track");
        require(tracks.front().id == id, "moving detection keeps the same track id");
        require(tracks.front().state == TrackState::Tracked || tracks.front().state == TrackState::New,
                "moving track is active");
    }
}

void low_confidence_recovery_keeps_same_id() {
    ByteTrackTracker tracker(test_config());

    std::vector<PersonTrack> tracks = tracker.update({detection({120.0f, 90.0f, 70.0f, 170.0f}, 0.92f)}, 1);
    require(tracks.size() == 1, "initial high-score detection creates a track");
    const int id = tracks.front().id;

    tracks = tracker.update({detection({123.0f, 90.0f, 70.0f, 170.0f}, 0.18f)}, 2);
    require(tracks.size() == 1, "low-score detection keeps the track active");
    require(tracks.front().id == id, "low-score detection keeps the same id");
    require(tracks.front().confidence < 0.50f, "low-score detection confidence is preserved");
    require(tracker.lost_track_count() == 0, "low-score recovery does not mark the track lost");
}

void lost_track_is_removed_after_buffer() {
    ByteTrackTracker tracker(test_config());

    std::vector<PersonTrack> tracks = tracker.update({detection({80.0f, 70.0f, 50.0f, 150.0f}, 0.90f)}, 1);
    require(tracks.size() == 1, "initial detection creates a buffered track");

    tracks = tracker.update({}, 2);
    require(tracks.empty(), "first missing frame hides the track from active output");
    require(tracker.lost_track_count() == 1, "first missing frame marks the track lost");

    tracks = tracker.update({}, 3);
    require(tracks.empty(), "second missing frame keeps the track inactive");
    require(tracker.lost_track_count() == 1, "track remains lost through the configured buffer");

    tracks = tracker.update({}, 4);
    require(tracks.empty(), "third missing frame has no active track");
    require(tracker.lost_track_count() == 0, "track is removed after exceeding the buffer");
    require(tracker.debug_tracks().empty(), "removed track is absent from debug tracks");
}

void new_person_gets_new_id() {
    ByteTrackTracker tracker(test_config());

    std::vector<PersonTrack> tracks = tracker.update({detection({60.0f, 80.0f, 50.0f, 150.0f}, 0.90f)}, 1);
    require(tracks.size() == 1, "first person creates one track");
    const int first_id = tracks.front().id;

    tracks = tracker.update(
        {
            detection({64.0f, 80.0f, 50.0f, 150.0f}, 0.90f),
            detection({260.0f, 82.0f, 50.0f, 150.0f}, 0.91f),
        },
        2);
    require(tracks.size() == 2, "second person creates a second active track");

    const std::vector<int> ids = sorted_ids(tracks);
    require(ids.front() == first_id, "original person keeps the original id");
    require(ids.back() != first_id, "new person receives a new id");
}

void two_person_near_crossing_smoke() {
    ByteTrackConfig config = test_config();
    config.match_thresh = 0.10f;
    ByteTrackTracker tracker(config);

    std::vector<PersonTrack> tracks = tracker.update(
        {
            detection({80.0f, 90.0f, 46.0f, 150.0f}, 0.90f),
            detection({260.0f, 90.0f, 46.0f, 150.0f}, 0.91f),
        },
        1);
    require(tracks.size() == 2, "near crossing starts with two tracks");
    const std::vector<int> original_ids = sorted_ids(tracks);

    for (int frame = 2; frame <= 6; ++frame) {
        const float left_x = 80.0f + static_cast<float>(frame - 1) * 18.0f;
        const float right_x = 260.0f - static_cast<float>(frame - 1) * 18.0f;
        tracks = tracker.update(
            {
                detection({left_x, 90.0f, 46.0f, 150.0f}, 0.88f),
                detection({right_x, 90.0f, 46.0f, 150.0f}, 0.89f),
            },
            static_cast<uint64_t>(frame));
        require(tracks.size() == 2, "near crossing keeps two active tracks");
        require(sorted_ids(tracks) == original_ids, "near crossing does not create replacement ids");
    }
}

void locked_track_blocks_new_subjects() {
    ByteTrackTracker tracker(test_config());

    std::vector<PersonTrack> tracks = tracker.update({detection({60.0f, 80.0f, 50.0f, 150.0f}, 0.90f)}, 1);
    require(tracks.size() == 1, "initial subject creates one track before locking");
    const int locked_id = tracks.front().id;

    TrackerUpdateOptions options;
    options.allow_new_tracks = false;
    options.locked_track_ids = {locked_id};

    tracks = tracker.update(
        {
            detection({64.0f, 80.0f, 50.0f, 150.0f}, 0.90f),
            detection({260.0f, 82.0f, 50.0f, 150.0f}, 0.95f),
        },
        2, options);

    require(tracks.size() == 1, "locked tracker returns only the locked subject");
    require(tracks.front().id == locked_id, "locked subject keeps the same id");
    require(tracker.debug_tracks().size() == 1, "locked tracker does not create a new track");
}

void predict_keeps_active_track_without_incrementing_missed_frames() {
    ByteTrackTracker tracker(test_config());
    constexpr uint64_t start_ns = 1000000000ULL;
    constexpr uint64_t detection_step_ns = 150000000ULL;
    constexpr uint64_t prediction_step_ns = 50000000ULL;

    std::vector<PersonTrack> tracks = tracker.update({detection({100.0f, 100.0f, 60.0f, 160.0f}, 0.90f)}, start_ns);
    require(tracks.size() == 1, "initial detection creates one track before prediction");
    const int id = tracks.front().id;

    tracks = tracker.update({detection({130.0f, 100.0f, 60.0f, 160.0f}, 0.90f)}, start_ns + detection_step_ns);
    require(tracks.size() == 1 && tracks.front().id == id, "second detection keeps the same track before prediction");
    const float before_center_x = tracks.front().box.center_x();

    tracks = tracker.predict(start_ns + detection_step_ns + prediction_step_ns);
    require(tracks.size() == 1, "predict returns the active track");
    require(tracks.front().id == id, "predict keeps the same track id");
    require(tracks.front().box.center_x() > before_center_x, "predict advances the active track box");

    const PersonTrack debug_track = debug_track_by_id(tracker, id);
    require(debug_track.missed_frames == 0, "predict does not increment missed frames");
    require(debug_track.state == TrackState::Tracked || debug_track.state == TrackState::New,
            "predict keeps track active");
    require(tracker.lost_track_count() == 0, "predict does not mark the track lost");
}

void stale_prediction_guard_holds_track_without_marking_lost() {
    ByteTrackConfig config = test_config();
    config.prediction_drift_guard_ms = 200;
    config.prediction_hold_ms = 400;
    ByteTrackTracker tracker(config);
    constexpr uint64_t start_ns = 1000000000ULL;
    constexpr uint64_t detection_step_ns = 100000000ULL;

    std::vector<PersonTrack> tracks = tracker.update({detection({100.0f, 100.0f, 60.0f, 160.0f}, 0.90f)}, start_ns);
    require(tracks.size() == 1, "initial stale-guard detection creates one track");
    const int id = tracks.front().id;

    tracks = tracker.update({detection({140.0f, 100.0f, 60.0f, 160.0f}, 0.90f)}, start_ns + detection_step_ns);
    require(tracks.size() == 1 && tracks.front().id == id, "second stale-guard detection keeps the same id");

    tracks = tracker.predict(start_ns + detection_step_ns + 100000000ULL);
    require(tracks.size() == 1, "fresh prediction returns the active track");
    const float guarded_center_x = tracks.front().box.center_x();

    tracks = tracker.predict(start_ns + detection_step_ns + 900000000ULL);
    require(tracks.size() == 1, "stale prediction still returns the active track");
    require(tracks.front().id == id, "stale prediction keeps the same track id");
    require(std::fabs(tracks.front().box.center_x() - guarded_center_x) < 0.01f,
            "stale prediction holds the last predicted box");

    const PersonTrack debug_track = debug_track_by_id(tracker, id);
    require(debug_track.missed_frames == 0, "stale prediction does not increment missed frames");
    require(debug_track.state == TrackState::Tracked || debug_track.state == TrackState::New,
            "stale prediction keeps track active");
    require(tracker.lost_track_count() == 0, "stale prediction does not mark the track lost");
}

void update_with_no_detections_still_marks_track_lost_after_prediction() {
    ByteTrackTracker tracker(test_config());
    constexpr uint64_t start_ns = 1000000000ULL;

    std::vector<PersonTrack> tracks = tracker.update({detection({100.0f, 100.0f, 60.0f, 160.0f}, 0.90f)}, start_ns);
    require(tracks.size() == 1, "initial detection creates one track before missing update");
    const int id = tracks.front().id;

    tracks = tracker.predict(start_ns + 16000000ULL);
    require(tracks.size() == 1, "predict keeps the track visible before missing update");
    require(debug_track_by_id(tracker, id).missed_frames == 0,
            "predict leaves missed frames unchanged before missing update");

    tracks = tracker.update({}, start_ns + 32000000ULL);
    require(tracks.empty(), "empty detector update hides the track after prediction");
    require(tracker.lost_track_count() == 1, "empty detector update still marks the track lost");
    const PersonTrack debug_track = debug_track_by_id(tracker, id);
    require(debug_track.missed_frames == 1, "empty detector update increments missed frames once");
    require(debug_track.state == TrackState::Lost, "empty detector update marks the track lost");
}

void subject_lock_filters_predicted_tracks() {
    ByteTrackTracker tracker(test_config());
    constexpr uint64_t start_ns = 1000000000ULL;

    std::vector<PersonTrack> tracks = tracker.update(
        {
            detection({60.0f, 80.0f, 50.0f, 150.0f}, 0.90f),
            detection({260.0f, 82.0f, 50.0f, 150.0f}, 0.95f),
        },
        start_ns);
    require(tracks.size() == 2, "two subjects create two tracks before locked prediction");

    const int locked_id = sorted_ids(tracks).front();
    TrackerUpdateOptions options;
    options.allow_new_tracks = false;
    options.locked_track_ids = {locked_id};

    tracks = tracker.predict(start_ns + 16000000ULL, options);
    require(tracks.size() == 1, "locked predict returns only the locked subject");
    require(tracks.front().id == locked_id, "locked predict keeps the locked id");
    require(tracker.debug_tracks().size() == 2, "locked predict does not create or remove tracks");
}

void iou_predict_returns_active_tracks_and_respects_lock_options() {
    IouTracker tracker;
    std::vector<PersonTrack> tracks = tracker.update(
        {
            detection({40.0f, 50.0f, 40.0f, 120.0f}, 0.85f),
            detection({180.0f, 52.0f, 40.0f, 120.0f}, 0.86f),
        },
        1);
    require(tracks.size() == 2, "IoU update creates two active tracks before prediction");

    tracks = tracker.predict(2);
    require(tracks.size() == 2, "IoU predict returns active tracks unchanged");

    const int locked_id = sorted_ids(tracks).back();
    TrackerUpdateOptions options;
    options.allow_new_tracks = false;
    options.locked_track_ids = {locked_id};

    tracks = tracker.predict(3, options);
    require(tracks.size() == 1, "IoU predict respects locked track ids");
    require(tracks.front().id == locked_id, "IoU predict returns the requested locked id");

    tracks = tracker.update({}, 4);
    require(tracks.empty(), "IoU empty update still hides active tracks");
    require(tracker.lost_track_count() == 2, "IoU empty update still marks tracks lost");
}

void bounded_occlusion_hold_expires() {
    ByteTrackConfig config = test_config();
    config.occlusion_hold_ms = 100;
    config.locked_occlusion_hold_ms = 200;
    ByteTrackTracker tracker(config);
    constexpr uint64_t start_ns = 1000000000ULL;

    std::vector<PersonTrack> tracks = tracker.update({detection({100.0f, 80.0f, 60.0f, 160.0f}, 0.90f)}, start_ns);
    require(tracks.size() == 1, "occlusion test creates a track");
    tracks = tracker.update({}, start_ns + 50000000ULL);
    require(tracks.size() == 1 && tracks.front().occlusion_hold, "brief occlusion keeps the predicted track");
    require(tracker.diagnostics().occlusion_hold_active, "occlusion diagnostics become active");
    tracks = tracker.predict(start_ns + 150000000ULL);
    require(tracks.empty(), "occlusion hold expires after its bounded duration");
}

void recently_lost_recovery_is_identity_safe() {
    ByteTrackTracker tracker(test_config());
    constexpr uint64_t start_ns = 1000000000ULL;
    std::vector<PersonTrack> tracks = tracker.update({detection({100.0f, 80.0f, 60.0f, 160.0f}, 0.90f)}, start_ns);
    const int id = tracks.front().id;
    tracker.update({}, start_ns + 10000000ULL);

    tracks = tracker.update({detection({104.0f, 82.0f, 60.0f, 160.0f}, 0.91f)}, start_ns + 20000000ULL);
    require(tracks.size() == 1 && tracks.front().id == id, "nearby recently lost track keeps its identity");
    require(tracker.diagnostics().recently_lost_recovery_successes == 1, "recovery success is counted");

    tracker.update({}, start_ns + 30000000ULL);
    tracks = tracker.update({detection({700.0f, 500.0f, 60.0f, 160.0f}, 0.99f)}, start_ns + 40000000ULL);
    require(tracks.size() == 1 && tracks.front().id != id, "distant detection cannot steal a lost identity");
}

void invalid_detections_are_rejected() {
    ByteTrackTracker tracker(test_config());
    const float invalid = std::numeric_limits<float>::quiet_NaN();
    const std::vector<PersonTrack> tracks = tracker.update({detection({invalid, 1.0f, 20.0f, 20.0f}, 0.99f)}, 1);
    require(tracks.empty(), "non-finite detection geometry is rejected");
}

void invalid_confidence_is_rejected_without_corrupting_tracks() {
    const std::vector<float> invalid_confidences = {
        std::numeric_limits<float>::quiet_NaN(),
        std::numeric_limits<float>::infinity(),
        -std::numeric_limits<float>::infinity(),
        -0.01f,
        1.01f,
    };

    for (const float invalid_confidence : invalid_confidences) {
        ByteTrackTracker creation_tracker(test_config());
        require(creation_tracker.update({detection({100.0f, 80.0f, 60.0f, 160.0f}, invalid_confidence)}, 1000000000ULL)
                    .empty(),
                "invalid confidence cannot create a track");

        ByteTrackTracker update_tracker(test_config());
        const std::vector<PersonTrack> initial =
            update_tracker.update({detection({100.0f, 80.0f, 60.0f, 160.0f}, 0.90f)}, 1000000000ULL);
        require(initial.size() == 1, "valid confidence creates the reference track");
        const int id = initial.front().id;

        const std::vector<PersonTrack> updated =
            update_tracker.update({detection({101.0f, 80.0f, 60.0f, 160.0f}, invalid_confidence)}, 1010000000ULL);
        require(updated.empty(), "invalid confidence cannot update a nearby active track");
        const PersonTrack safe_track = debug_track_by_id(update_tracker, id);
        require(safe_track.id == id && safe_track.confidence == 0.90f,
                "invalid confidence leaves the existing track confidence safe");
    }
}

} // namespace

int main() {
    try {
        stable_id_across_moving_detections();
        low_confidence_recovery_keeps_same_id();
        lost_track_is_removed_after_buffer();
        new_person_gets_new_id();
        two_person_near_crossing_smoke();
        locked_track_blocks_new_subjects();
        predict_keeps_active_track_without_incrementing_missed_frames();
        stale_prediction_guard_holds_track_without_marking_lost();
        update_with_no_detections_still_marks_track_lost_after_prediction();
        subject_lock_filters_predicted_tracks();
        iou_predict_returns_active_tracks_and_respects_lock_options();
        bounded_occlusion_hold_expires();
        recently_lost_recovery_is_identity_safe();
        invalid_detections_are_rejected();
        invalid_confidence_is_rejected_without_corrupting_tracks();
    } catch (const std::exception& error) {
        std::cerr << "bytetrack_tracker_tests failed: " << error.what() << '\n';
        return 1;
    }

    std::cout << "bytetrack_tracker_tests passed\n";
    return 0;
}
