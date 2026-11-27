#pragma once

#include "../lowering/event_mask_source.hpp"
#include "../replay/property_replay.hpp"

#include <iosfwd>

namespace q3a {
class MemoryBudget;

namespace trace {

using EventCursorSamples = std::map<std::string, std::vector<std::uint64_t>>;

struct EventWitnessLocation {
    std::size_t global_step = 0;
    std::string domain;
    std::uint64_t domain_sample = 0;
    std::size_t frame_count = 0;
    bool open_assumption = false;
};

// The indexed trace owns signal values. The schedule holds the source-bound
// clock roster and the zero-based sample index of each active domain per step.
EventWitnessLocation write_event_witness(std::ostream& indexed, std::ostream& schedule,
    const lowering::EventMaskModel& model, const std::string& property,
    const std::vector<replay::Frame>& frames, std::size_t candidate, const MemoryBudget& memory);

EventWitnessLocation verify_event_witness(std::istream& indexed, std::istream& schedule,
    const lowering::EventMaskModel& model, const std::string& property, const MemoryBudget& memory,
    EventCursorSamples* samples = nullptr);

} // namespace trace
} // namespace q3a
