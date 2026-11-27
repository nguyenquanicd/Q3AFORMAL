#include "event_debug.hpp"
#include "event_witness.hpp"
#include "indexed_debug.hpp"
#include "trace_capture.hpp"

#include <algorithm>

namespace q3a::bundle {

VerifiedDebugSession open_event_debug_session(const std::filesystem::path& directory,
    const lowering::EventMaskModel& model, const ProjectInput& project,
    const std::string& name, const MemoryBudget& memory) {
    const auto trace_path = directory / "witness.q3t";
    auto locked = std::make_shared<IndexedDebugInput>(trace_path);
    WriteLockedInput schedule(directory / "witness.schedule");
    trace::EventCursorSamples samples;
    const auto location = trace::verify_event_witness(locked->input.stream(), schedule.stream(),
                                                     model, name, memory, &samples);
    locked->input.rewind();
    schedule.rewind();

    VerifiedDebugSession session;
    auto& view = session.view;
    view.indexed_bytes = std::filesystem::file_size(trace_path);
    const auto indexed_sha = sha256_stream(locked->input.stream(), view.indexed_bytes);
    const auto schedule_sha = sha256_stream(schedule.stream());
    const auto identity = sha256_hex(indexed_sha + "\n" + schedule_sha);
    const auto& properties = model.transition.properties;
    const auto& property = *std::find_if(properties.begin(), properties.end(),
        [&](const auto& item) { return item.name == name; });
    view.run = {{"Bundle", identity}, {"Obligation", property.kind}, {"Property", name},
        {"Result", location.open_assumption ? "Witness pending assumption" :
            property.kind == "cover" ? "Covered" : "Counterexample"},
        {"Profile", lowering::kFreeEventMaskProfile}, {"Trace", "witness.q3t"},
        {"Witness sample", location.domain + " " + std::to_string(location.domain_sample)}};
    view.assertion = property.location;
    view.signals = model.transition.signals;
    std::sort(view.signals.begin(), view.signals.end(),
        [](const auto& a, const auto& b) { return a.name < b.name; });
    for (const auto& check : properties) {
        if (check.kind == "assume") view.assumptions.push_back(check.name);
    }

    constexpr std::size_t initial_signals = 12;
    const auto select = [&](const std::string& signal) {
        if (view.selected.size() < initial_signals &&
            std::find(view.selected.begin(), view.selected.end(), signal) == view.selected.end()) {
            view.selected.push_back(signal);
        }
    };
    for (const auto& [domain, signal] : model.edge_inputs) {
        view.clocks.push_back(domain);
        view.groups["Clock edges"].push_back(signal);
        select(signal);
    }
    for (const auto* signal : trace::select_capture_signals(model.transition, property, {})) {
        view.groups["Default capture"].push_back(signal->name);
        select(signal->name);
    }

    add_project_debug_sources(view, project, memory);
    session.frame_count = location.frame_count;
    session.candidate_frame = location.global_step;
    attach_indexed_debug_input(session, std::move(locked));
    session.describe_cursor = [samples = std::move(samples)](std::uint64_t cursor) {
        std::string summary = "Global step " + std::to_string(cursor);
        for (const auto& [domain, steps] : samples) {
            const auto at = std::lower_bound(steps.begin(), steps.end(), cursor);
            summary += "\r\n" + domain + ": ";
            summary += at != steps.end() && *at == cursor
                ? "sample " + std::to_string(at - steps.begin()) : "idle";
        }
        return summary;
    };
    return session;
}

} // namespace q3a::bundle
