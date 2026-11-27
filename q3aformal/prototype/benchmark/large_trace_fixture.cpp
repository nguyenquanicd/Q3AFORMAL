#include "../source/bundle/debug_view.hpp"
#include "../source/bundle/indexed_trace.hpp"

#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string_view>

int main(int argc, char** argv) {
    try {
        const bool sparse = argc == 3 && std::string_view(argv[2]) == "--sparse";
        if (argc != 2 && !sparse) {
            throw std::invalid_argument("usage: large_trace_fixture OUTPUT_DIRECTORY [--sparse]");
        }
        const std::filesystem::path directory(argv[1]);
        const auto trace = directory / "trace.q3atrace";
        constexpr std::size_t frame_count = 10001;
        constexpr std::size_t signal_count = 384;
        constexpr char signal_name[] = "lane_000";
        const q3a::frontend::SourceLocation source{"fixture.sv", 1, 1, 0};

        q3a::lowering::TIRModule model;
        for (std::size_t i = 0; i < signal_count; ++i) {
            const auto name = "lane_" + std::to_string(1000 + i).substr(1);
            model.signals.emplace_back(name, 32, false, "input", source);
        }
        {
            std::vector<q3a::replay::Frame> frames(frame_count);
            for (std::size_t frame = 0; frame < frame_count; ++frame) {
                for (std::size_t i = 0; i < signal_count; ++i) {
                    auto sample = frame;
                    if (sparse) {
                        sample = frame >= 256 ? 1 : 0;
                        if (frame >= 9984 || (i == 25 && frame == 9983)) sample = 2;
                    }
                    frames[frame].emplace(model.signals[i].name, sample * 1024 + i);
                }
            }
            std::ofstream output(trace, std::ios::binary);
            output.exceptions(std::ios::failbit | std::ios::badbit);
            q3a::trace::write_indexed_trace(output, model, frames, "p_synthetic", 0);
            output.close();
        }
        std::ifstream input(trace, std::ios::binary);
        if (!input) throw std::runtime_error("Cannot reopen fixture trace");
        std::ostringstream snapshot;
        q3a::trace::write_indexed_window(input, snapshot, 0, 31, {signal_name});

        q3a::bundle::DebugView view;
        view.run = {{"Result", "SYNTHETIC"}, {"Trace", "trace.q3atrace"}};
        view.signals = model.signals;
        view.selected = {signal_name};
        view.assertion = source;
        view.sources.emplace("fixture.sv", "// Synthetic trace fixture\n");
        view.initial_window = snapshot.str();
        view.verification_log = "Synthetic renderer fixture. No proof status.";
        view.indexed_bytes = std::filesystem::file_size(trace);
        std::ofstream page(directory / "page.html", std::ios::binary);
        page.exceptions(std::ios::failbit | std::ios::badbit);
        q3a::bundle::write_debug_page(page, view);
        page.close();
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
