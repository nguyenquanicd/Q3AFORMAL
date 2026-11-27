#pragma once

#include "../lowering/lowering.hpp"

#include <functional>
#include <iosfwd>
#include <map>
#include <optional>

namespace q3a::bundle {

struct DebugView {
    std::map<std::string, std::string> run;
    std::vector<std::string> assumptions;
    std::vector<std::string> clocks;
    std::vector<lowering::TIRSignal> signals;
    std::vector<std::string> selected;
    std::map<std::string, std::string> resets;
    std::map<std::string, std::vector<std::string>> groups;
    frontend::SourceLocation assertion;
    std::map<std::string, std::string> sources;
    std::string initial_window;
    std::string verification_log;
    std::uint64_t indexed_bytes = 0;
};

// The reader holds the exact indexed witness used to initialize the view.
// Repeated requests read only the selected time blocks and signals.
struct VerifiedDebugSession {
    DebugView view;
    std::uint64_t frame_count = 0;
    std::uint64_t candidate_frame = 0;
    std::function<void(std::ostream&, std::uint64_t, std::uint64_t,
                       const std::vector<std::string>&)> write_window;
    std::function<std::optional<std::uint64_t>(const std::string&, std::uint64_t, bool)> find_transition;
    std::function<std::string(std::uint64_t)> describe_cursor;
};

void write_debug_page(std::ostream& output, const DebugView& view);

} // namespace q3a::bundle
