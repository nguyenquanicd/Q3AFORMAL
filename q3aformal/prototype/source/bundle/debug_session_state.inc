
namespace {

constexpr std::size_t max_session_bytes = 4 * 1024 * 1024;
constexpr std::size_t max_selected_signals = 16;
constexpr std::size_t max_markers = 128;

std::string session_identity(const VerifiedDebugSession& session) {
    return "q3a-debug:" + session.view.run.at("Bundle") + ":" + session.view.run.at("Obligation");
}

bool valid_span(unsigned span) { return span == 16 || span == 32 || span == 64; }

void validate_session_state(const VerifiedDebugSession& session, const DebugSessionState& state) {
    if (state.frame >= session.frame_count || !valid_span(state.span) ||
        (state.first && (*state.first >= session.frame_count ||
                         *state.first > session.frame_count - std::min<std::uint64_t>(session.frame_count, state.span))) ||
        (state.radix != "Hex" && state.radix != "Binary" && state.radix != "Unsigned") ||
        state.signals.size() > max_selected_signals || state.markers.size() > max_markers) {
        throw std::invalid_argument("invalid debug cursor, viewport, radix, or selection size");
    }
    std::set<std::string> known;
    for (const auto& signal : session.view.signals) known.insert(signal.name);
    const auto check_members = [&](const std::vector<std::string>& names) {
        std::set<std::string> seen;
        for (const auto& name : names) {
            if (!known.count(name) || !seen.insert(name).second) {
                throw std::invalid_argument("unknown or repeated debug signal");
            }
        }
    };
    check_members(state.signals);
    for (const auto& [label, names] : state.groups) {
        if (label.empty() || label.size() > 80) throw std::invalid_argument("invalid debug group name");
        check_members(names);
    }
    std::set<std::uint64_t> markers;
    for (auto frame : state.markers) {
        if (frame >= session.frame_count || !markers.insert(frame).second)
            throw std::invalid_argument("invalid or repeated debug marker");
    }
}

} // namespace

DebugSessionState decode_debug_session(const VerifiedDebugSession& session, const std::string& json) {
    if (json.size() > max_session_bytes) throw std::invalid_argument("debug session file exceeds its size limit");
    const auto parsed = JsonParser(json, "debug session").parse();
    const auto schema = parsed.at("schema").number();
    if ((schema != 1 && schema != 2) || parsed.at("key").string() != session_identity(session))
        throw std::invalid_argument("debug session is incompatible with this result bundle");
    DebugSessionState result;
    result.frame = parsed.at("frame").number();
    const auto& span = parsed.at("span").string();
    if (span == "16") result.span = 16;
    else if (span == "32") result.span = 32;
    else if (span == "64") result.span = 64;
    else throw std::invalid_argument("invalid debug zoom span");
    result.radix = parsed.at("radix").string();
    for (const auto& value : parsed.at("signals").array()) result.signals.push_back(value.string());
    result.groups = session.view.groups;
    result.source = session.view.assertion;
    if (schema == 2) {
        if (parsed.at("trace").string() != session.view.run.at("Trace"))
            throw std::invalid_argument("debug session is for another trace");
        const auto& first = parsed.at("viewportStart");
        if (!first.is_null()) result.first = first.number();
        for (const auto& marker : parsed.at("markers").array()) result.markers.push_back(marker.number());
        result.groups.clear();
        for (const auto& item : parsed.at("groups").array()) {
            const auto& entry = item.array();
            if (entry.size() != 2) throw std::invalid_argument("invalid debug session group");
            std::vector<std::string> members;
            for (const auto& name : entry[1].array()) members.push_back(name.string());
            if (!result.groups.emplace(entry[0].string(), std::move(members)).second)
                throw std::invalid_argument("duplicate debug session group");
        }
    }
    const auto& fields = parsed.object();
    const auto group = fields.find("group");
    if (group != fields.end() && result.groups.count(group->second.string())) result.group = group->second.string();
    const auto source = fields.find("source");
    if (source != fields.end() && !source->second.is_null()) {
        const auto& location = source->second;
        const auto& file = location.at("file").string();
        const auto line = location.at("line").number();
        const auto column = location.at("column").number();
        if (session.view.sources.count(file) && line > 0 && column > 0 &&
            line <= std::numeric_limits<std::size_t>::max() && column <= std::numeric_limits<std::size_t>::max()) {
            result.source = {file, static_cast<std::size_t>(line), static_cast<std::size_t>(column), 0};
        }
    }
    validate_session_state(session, result);
    return result;
}

std::string encode_debug_session(const VerifiedDebugSession& session, const DebugSessionState& state) {
    validate_session_state(session, state);
    std::ostringstream out;
    const auto strings = [&](const std::vector<std::string>& items) {
        out << '[';
        const char* delimiter = "";
        for (const auto& item : items) {
            out << delimiter << json_string(item);
            delimiter = ",";
        }
        out << ']';
    };
    out << "{\"schema\":2,\"key\":" << json_string(session_identity(session))
        << ",\"trace\":" << json_string(session.view.run.at("Trace"))
        << ",\"frame\":" << state.frame << ",\"signals\":";
    strings(state.signals);
    out << ",\"span\":" << json_string(std::to_string(state.span)) << ",\"viewportStart\":";
    if (state.first) out << *state.first;
    else out << "null";
    out << ",\"radix\":" << json_string(state.radix) << ",\"group\":" << json_string(state.group)
        << ",\"groups\":[";
    const char* delimiter = "";
    for (const auto& [label, members] : state.groups) {
        out << delimiter << '[' << json_string(label) << ',';
        strings(members);
        out << ']';
        delimiter = ",";
    }
    out << "],\"markers\":[";
    delimiter = "";
    for (auto frame : state.markers) {
        out << delimiter << frame;
        delimiter = ",";
    }
    out << "],\"source\":{\"file\":" << json_string(state.source.file)
        << ",\"line\":" << state.source.line << ",\"column\":" << state.source.column << "}}\n";
    auto encoded = out.str();
    if (encoded.size() > max_session_bytes) throw std::invalid_argument("debug session file exceeds its size limit");
    return encoded;
}

