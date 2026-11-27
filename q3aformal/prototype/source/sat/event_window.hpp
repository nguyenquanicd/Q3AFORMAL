#pragma once

#include "../lowering/event_mask_source.hpp"
#include "transition_encoder.hpp"

#include <optional>

namespace q3a::sat {

enum class EventWindowOutcome { Witness, Complete, Incomplete, Inconsistent, Inconclusive };

struct EventWindowResult {
    EventWindowOutcome outcome = EventWindowOutcome::Inconclusive;
    std::optional<std::size_t> witness_frame;
    std::vector<std::int8_t> assignment;
    bool witness_has_open_assumption = false;
};

// Use a window with encoded transitions and constrained assumptions from
// model.transition. Additional caller constraints may fix part of the schedule.
// Complete means no completed witness and no reachable pending obligation.
EventWindowResult classify_event_window(const lowering::EventMaskModel& model,
    const std::string& property, TransitionCnfEncoder& encoder, Solver& solver);

} // namespace q3a::sat
