#pragma once

#include "debug_view.hpp"
#include "indexed_trace.hpp"
#include "../source_manager/source_manager.hpp"
#include "../source_manager/write_locked_input.hpp"

#include <memory>
#include <mutex>

namespace q3a::bundle {

struct IndexedDebugInput {
    explicit IndexedDebugInput(const std::filesystem::path& path) : input(path) {}
    WriteLockedInput input;
    std::mutex readers;
};

inline void attach_indexed_debug_input(VerifiedDebugSession& session, std::shared_ptr<IndexedDebugInput> input) {
    session.write_window = [input](std::ostream& out, std::uint64_t first, std::uint64_t last,
                                   const std::vector<std::string>& selected) {
        const std::lock_guard<std::mutex> guard(input->readers);
        input->input.rewind();
        trace::write_indexed_window(input->input.stream(), out, first, last, selected);
    };
    session.find_transition = [input = std::move(input)](const std::string& signal,
                                                         std::uint64_t cursor, bool forward) {
        const std::lock_guard<std::mutex> guard(input->readers);
        input->input.rewind();
        return trace::find_indexed_transition(input->input.stream(), signal, cursor, forward);
    };
}

inline void add_project_debug_sources(DebugView& view, const ProjectInput& project, const MemoryBudget& memory) {
    std::uint64_t remaining = 8 * 1024 * 1024;
    for (const bool property_file : {true, false}) {
        for (const auto* collection : {&project.sources, &project.headers}) {
            for (const auto& source : *collection) {
                if ((source.relative_path == view.assertion.file) != property_file ||
                    source.contents.size() > remaining || view.sources.count(source.relative_path)) continue;
                memory.check(source.contents.size());
                view.sources.emplace(source.relative_path, std::string(source.contents.begin(), source.contents.end()));
                remaining -= source.contents.size();
            }
        }
    }
}

} // namespace q3a::bundle
