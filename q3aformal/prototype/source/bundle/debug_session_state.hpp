
#pragma once

#include "debug_view.hpp"
#include <optional>
#include <string_view>

namespace q3a::bundle {

struct DebugSessionState {
    std::uint64_t frame = 0;
    std::optional<std::uint64_t> first;
    unsigned span = 32;
    std::vector<std::string> signals;
    std::string radix = "Hex";
    std::string group;
    std::map<std::string, std::vector<std::string>> groups;
    std::vector<std::uint64_t> markers;
    frontend::SourceLocation source;
};

DebugSessionState decode_debug_session(const VerifiedDebugSession& session,
                                       const std::string& json);
std::string encode_debug_session(const VerifiedDebugSession& session,
                                 const DebugSessionState& state);

} // namespace q3a::bundle

