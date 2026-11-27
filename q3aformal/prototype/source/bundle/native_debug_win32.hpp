
#pragma once

#include "debug_view.hpp"
#include "waveform_win32.hpp"
#include <chrono>
#include <filesystem>
#include <iosfwd>

namespace q3a::debug {

WaveViewport read_verified_viewport(const bundle::VerifiedDebugSession& session,
    std::uint64_t first, std::uint64_t last, std::uint64_t cursor,
    const std::vector<std::string>& selected);

int run_native_debug(const bundle::VerifiedDebugSession& session, const std::filesystem::path& test_path = {});

struct NativeCaptureRequest {
    std::uint64_t span;
    std::vector<std::pair<std::uint64_t, std::uint64_t>> viewports;
    std::filesystem::path session_output;
    bool show_window;
    std::chrono::steady_clock::time_point started;
};

int capture_native_workload(const bundle::VerifiedDebugSession& session, const NativeCaptureRequest& request,
                            std::ostream& output);

} // namespace q3a::debug

