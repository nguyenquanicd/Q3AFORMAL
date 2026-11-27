#include "native_debug_win32.hpp"

#include <iostream>

namespace q3a::debug {

int run_native_debug(const bundle::VerifiedDebugSession&, const std::filesystem::path&) {
    std::cerr << "Q3A_GUI_UNSUPPORTED use the debug command or trace view-vcd for offline HTML on Linux\n";
    return 2;
}

int capture_native_workload(const bundle::VerifiedDebugSession&, const NativeCaptureRequest&, std::ostream&) {
    std::cerr << "Q3A_GUI_UNSUPPORTED native Windows viewport benchmarks are unavailable on Linux\n";
    return 2;
}

} // namespace q3a::debug
