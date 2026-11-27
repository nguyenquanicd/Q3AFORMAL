#include "event_witness.hpp"
#include "indexed_trace.hpp"
#include "../source_manager/platform_support.hpp"

#include <algorithm>
#include <array>
#include <istream>
#include <iomanip>
#include <ostream>
#include <stdexcept>

namespace q3a::trace {
namespace {

class ScheduleMatch final : public std::streambuf {
public:
    explicit ScheduleMatch(std::istream& input) : input_(input) {}

private:
    std::streamsize xsputn(const char* bytes, std::streamsize count) override {
        std::array<char, 256> buffer{};
        for (std::streamsize offset = 0; offset < count;) {
            const auto length = std::min<std::streamsize>(count - offset, buffer.size());
            if (!input_.read(buffer.data(), length) ||
                traits_type::compare(bytes + offset, buffer.data(), static_cast<std::size_t>(length)) != 0) {
                throw std::invalid_argument("event schedule differs from source replay");
            }
            offset += length;
        }
        return count;
    }

    int_type overflow(int_type byte) override {
        if (traits_type::eq_int_type(byte, traits_type::eof())) return traits_type::not_eof(byte);
        const auto value = traits_type::to_char_type(byte);
        xsputn(&value, 1);
        return byte;
    }

    std::istream& input_;
};

const lowering::TIRProperty& find_property(const lowering::EventMaskModel& model, const std::string& name) {
    const auto& properties = model.transition.properties;
    const auto found = std::find_if(properties.begin(), properties.end(),
        [&](const auto& property) { return property.name == name; });
    if (model.transition.semantic_profile != lowering::kFreeEventMaskProfile ||
        found == properties.end() || model.property_domains.count(name) != 1 ||
        (found->kind != "assert" && found->kind != "cover")) {
        throw std::invalid_argument("event witness requires a source-bound assertion or cover");
    }
    return *found;
}

void check_replay(const lowering::EventMaskModel& model, const lowering::TIRProperty& property,
                  const replay::FrameView& frames, std::size_t candidate) {
    const auto checked = property.kind == "cover"
        ? replay::validate_bounded_cover_view(model.transition, frames, property.name, candidate)
        : replay::validate_bounded_counterexample_view(model.transition, frames, property.name, candidate);
    if (!checked.validated) throw std::invalid_argument("event witness replay rejected: " + checked.message);
}

void write_bindings(std::ostream& output, const lowering::EventMaskModel& model) {
    for (const auto& [clock, signal] : model.edge_inputs) {
        output << "domain " << std::quoted(clock) << ' ' << std::quoted(signal) << '\n';
    }
    for (const auto& [signal, clock] : model.state_domains) {
        output << "state " << std::quoted(signal) << ' ' << std::quoted(clock) << '\n';
    }
    for (const auto& [property, clock] : model.property_domains) {
        output << "check " << std::quoted(property) << ' ' << std::quoted(clock) << '\n';
    }
}

EventWitnessLocation write_schedule(std::ostream& output, const lowering::EventMaskModel& model,
    const lowering::TIRProperty& property, const replay::FrameView& frames, std::size_t candidate,
    const MemoryBudget& memory, EventCursorSamples* samples = nullptr) {
    const auto model_identity = sha256_generated([&](auto& identity) {
        identity << serialize_tir(model.transition) << '\n';
        write_bindings(identity, model);
    });
    const auto& target_domain = model.property_domains.at(property.name);
    EventWitnessLocation result{candidate, target_domain, 0, frames.size(), false};
    const auto& last = frames[frames.size() - 1];
    for (const auto& check : model.transition.properties) {
        if (check.kind != "assume") continue;
        const auto pending = model.pending_at_boundary.find(check.name);
        if (pending != model.pending_at_boundary.end() && last.at(pending->second) != 0) {
            result.open_assumption = true;
            break;
        }
    }
    output << "Q3AFORMAL_EVENT_SCHEDULE 1\nmodel_sha256 " << model_identity
           << "\nproperty " << std::quoted(property.name) << "\nkind " << property.kind
           << "\nframes " << std::to_string(frames.size()) << "\ncandidate " << std::to_string(candidate) << '\n';
    write_bindings(output, model);
    if (samples) for (const auto& domain : model.edge_inputs) samples->try_emplace(domain.first);
    std::vector<std::uint64_t> next_sample(model.edge_inputs.size());
    bool sampled_candidate = false;
    for (std::size_t step = 0; step < frames.size(); ++step) {
        memory.check();
        const auto& values = frames[step];
        output << "step " << std::to_string(step);
        std::size_t i = 0;
        for (const auto& [domain, signal] : model.edge_inputs) {
            const auto edge = values.at(signal);
            if (edge > 1) throw std::invalid_argument("event mask value is outside the Boolean model");
            if (edge == 1) {
                const auto sample = next_sample[i]++;
                if (samples) samples->at(domain).push_back(step);
                output << ' ' << std::to_string(sample);
                if (step == candidate && domain == target_domain) {
                    result.domain_sample = sample;
                    sampled_candidate = true;
                }
            } else {
                output << " -";
            }
            ++i;
        }
        output << '\n';
    }
    if (!sampled_candidate) throw std::invalid_argument("candidate step has no edge in its source domain");
    if (!output) throw std::runtime_error("failed to write event schedule");
    return result;
}

} // namespace

EventWitnessLocation write_event_witness(std::ostream& indexed, std::ostream& schedule,
    const lowering::EventMaskModel& model, const std::string& name,
    const std::vector<replay::Frame>& frames, std::size_t candidate, const MemoryBudget& memory) {
    const auto& property = find_property(model, name);
    memory.check();
    const replay::FrameView view(frames.size(), [&](std::size_t frame) -> const replay::Frame& {
        memory.check();
        return frames.at(frame);
    });
    check_replay(model, property, view, candidate);
    write_indexed_trace(indexed, model.transition, frames, name, candidate);
    return write_schedule(schedule, model, property, view, candidate, memory);
}

EventWitnessLocation verify_event_witness(std::istream& indexed, std::istream& schedule,
    const lowering::EventMaskModel& model, const std::string& name, const MemoryBudget& memory,
    EventCursorSamples* samples) {
    const auto& property = find_property(model, name);
    EventWitnessLocation result;
    EventCursorSamples validated;
    visit_indexed_witness(indexed, model.transition, name, std::nullopt,
        [&](std::uint64_t bytes) { memory.check(bytes); },
        [&](const replay::FrameView& frames, std::size_t candidate) {
            check_replay(model, property, frames, candidate);
            ScheduleMatch match(schedule);
            std::ostream expected(&match);
            expected.exceptions(std::ios::badbit | std::ios::failbit);
            result = write_schedule(expected, model, property, frames, candidate, memory, samples ? &validated : nullptr);
            if (schedule.peek() != std::istream::traits_type::eof() || schedule.bad()) {
                throw std::invalid_argument("event schedule has unexpected trailing data");
            }
        });
    if (samples) *samples = std::move(validated);
    return result;
}

} // namespace q3a::trace
