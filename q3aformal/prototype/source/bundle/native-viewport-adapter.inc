
q3a::debug::WaveViewport read_native_wave_viewport(const VerifiedDebugSession& session,
    std::uint64_t first, std::uint64_t last, std::uint64_t cursor,
    const std::vector<std::string>& selected) {
    if (first > last || last >= session.frame_count || cursor >= session.frame_count) {
        throw std::invalid_argument("native waveform time range is invalid");
    }
    std::vector<std::string> requested = selected;
    for (const auto& [name, polarity] : session.view.resets) {
        if (std::find(requested.begin(), requested.end(), name) == requested.end()) requested.push_back(name);
    }
    if (requested.empty()) return {first, last, cursor, session.candidate_frame, {}};
    std::ostringstream text;
    session.write_window(text, first, last, requested);
    const auto document = JsonParser(text.str()).parse();
    if (document.at("schema").string() != "Q3A-TRACE-WINDOW-1" ||
        document.at("first").number() != first || document.at("last").number() != last ||
        document.at("candidate_frame").number() != session.candidate_frame) {
        throw std::runtime_error("the trace window identity differs from the session");
    }
    q3a::debug::WaveViewport view{first, last, cursor, session.candidate_frame, {}};
    const auto& signals = document.at("signals").array();
    if (signals.size() != requested.size()) throw std::runtime_error("trace signal selection changed");
    for (std::size_t index = 0; index < signals.size(); ++index) {
        const auto& signal = signals[index];
        const auto& name = signal.at("name").string();
        if (name != requested[index]) throw std::runtime_error("trace signal order changed");
        if (name.size() > static_cast<std::size_t>(std::numeric_limits<int>::max()))
            throw std::runtime_error("trace name is too long");
        const auto before = static_cast<int>(name.size());
        const auto length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, name.data(), before, nullptr, 0);
        if (length <= 0) throw std::runtime_error("cannot decode trace signal name");
        std::wstring title(static_cast<std::size_t>(length), L'\0');
        if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, name.data(), before, title.data(), length) != length)
            throw std::runtime_error("cannot decode trace signal name");
        const auto width = signal.at("width").number();
        if (width == 0 || width > 64) throw std::runtime_error("invalid trace signal width");
        q3a::debug::WaveSignal lane{std::move(title), static_cast<unsigned>(width), {}};
        for (const auto& entry : signal.at("changes").array()) {
            const auto& change = entry.array();
            if (change.size() != 2) throw std::runtime_error("invalid trace change pair");
            const auto& encoded = change[1].string();
            if (encoded.size() < 3 || encoded.compare(0, 2, "0x") != 0)
                throw std::runtime_error("invalid trace value");
            std::uint64_t value{};
            const auto end = encoded.data() + encoded.size();
            const auto converted = std::from_chars(encoded.data() + 2, end, value, 16);
            if (converted.ec != std::errc{} || converted.ptr != end)
                throw std::runtime_error("invalid trace value");
            lane.changes.push_back({change[0].number(), value});
        }
        const auto reset = session.view.resets.find(name);
        if (reset != session.view.resets.end()) {
            q3a::debug::append_asserted_reset_ranges(view, lane, reset->second == "high");
        }
        if (index < selected.size()) view.signals.push_back(std::move(lane));
    }
    return view;
}


