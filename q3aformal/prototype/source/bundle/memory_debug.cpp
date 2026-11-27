#include "memory_debug.hpp"
#include "indexed_debug.hpp"
#include "windows_file_path.hpp"
#include "../lowering/state_transition.hpp"
#include "../source_manager/memory_proof.hpp"

#include <algorithm>

namespace q3a::bundle {

VerifiedDebugSession open_memory_range_debug_session(const std::filesystem::path& trace_path,
    const lowering::TIRModule& model, const ProjectInput& project, const std::string& property,
    const MemoryBudget& memory) {
    const auto path = detail::absolute_windows_file_path(trace_path);
    auto input = std::make_shared<IndexedDebugInput>(path);
    auto witness = memory_proof::reopen_range_trace(model, property, input->input.stream(), memory);
    input->input.rewind();

    VerifiedDebugSession session;
    auto& view = session.view;
    view.indexed_bytes = std::filesystem::file_size(path);
    view.run = {{"Bundle", sha256_stream(input->input.stream(), view.indexed_bytes)},
        {"Obligation", "memory-range"}, {"Property", property}, {"Trace", path.filename().u8string()},
        {"Profile", model.semantic_profile}, {"Result", witness.boundary_incomplete
            ? "Range witness pending assumption" : "First invalid memory access"}};
    view.assertion = witness.accesses.front().location;
    view.signals = model.signals;
    view.clocks = model.clocks;
    std::sort(view.signals.begin(), view.signals.end(), [](const auto& a, const auto& b) { return a.name < b.name; });
    for (const auto& check : model.properties) {
        if (check.kind == "assume") view.assumptions.push_back(check.name);
    }

    auto& controls = view.groups["Invalid access controls"];
    for (const auto& access : witness.accesses) {
        for (const auto* name : {&access.enable_signal, &access.address_signal}) {
            if (std::find(controls.begin(), controls.end(), *name) == controls.end()) controls.push_back(*name);
        }
    }
    view.selected = controls;
    auto& data = view.groups["Memory data and cells"];
    for (const auto& signal : view.signals) {
        if (data.size() == 12) break;
        if (signal.role != "state" && signal.role != "output") continue;
        data.push_back(signal.name);
        if (view.selected.size() < 12 &&
            std::find(view.selected.begin(), view.selected.end(), signal.name) == view.selected.end()) {
            view.selected.push_back(signal.name);
        }
    }
    if (data.empty()) view.groups.erase("Memory data and cells");

    add_project_debug_sources(view, project, memory);
    session.frame_count = witness.frame + 1;
    session.candidate_frame = witness.frame;
    attach_indexed_debug_input(session, std::move(input));
    session.describe_cursor = [witness = std::move(witness)](std::uint64_t cursor) {
        std::string text = "Sample " + std::to_string(cursor);
        if (witness.boundary_incomplete) text += " (pending assumption)";
        if (cursor != witness.frame) return text + " (legal prefix)";
        for (const auto& access : witness.accesses) {
            const char* operation = access.property == lowering::kMemoryReadRange ? "Read" : "Write";
            text += "\r\n" + std::string(operation) + " " + access.address_signal + " = " +
                std::to_string(access.address) + " outside [" + std::to_string(access.first) + ".." +
                std::to_string(access.last) + "] at " + access.location.file + ":" +
                std::to_string(access.location.line);
        }
        return text;
    };
    return session;
}

} // namespace q3a::bundle
