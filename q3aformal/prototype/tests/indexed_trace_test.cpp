#include "../source/bundle/indexed_trace.hpp"

#include <cassert>
#include <iostream>
#include <sstream>
#include <stdexcept>

class CountedBuffer final : public std::stringbuf {
public:
    explicit CountedBuffer(const std::string& bytes)
        : std::stringbuf(bytes, std::ios::in | std::ios::binary) {}

    std::streamsize bytes_read = 0;

protected:
    std::streamsize xsgetn(char* output, std::streamsize amount) override {
        const auto count = std::stringbuf::xsgetn(output, amount);
        bytes_read += count;
        return count;
    }
};

int main() {
    q3a::lowering::TIRModule model;
    model.signals.emplace_back("wide", 64, false, "input", q3a::frontend::SourceLocation{});
    for (int i = 0; i < 24; ++i) {
        model.signals.emplace_back("unused_" + std::to_string(i), 16, false,
                                   "input", q3a::frontend::SourceLocation{});
    }
    std::vector<q3a::replay::Frame> frames(1024);
    for (std::size_t frame = 0; frame < frames.size(); ++frame) {
        for (const auto& signal : model.signals) frames[frame][signal.name] = frame;
        frames[frame]["wide"] = (frame < 258 ? 0xffffffffffffffffULL : 0xaULL);
    }
    std::ostringstream binary;
    q3a::trace::write_indexed_trace(binary, model, frames, "p_test", 258);
    const auto bytes = binary.str();
    CountedBuffer buffer(bytes);
    std::istream input(&buffer);
    std::ostringstream result;
    q3a::trace::write_indexed_window(input, result, 255, 260, {"wide"});
    assert(result.str().find("\"changes\":[[255,\"0xffffffffffffffff\"],[258,\"0xa\"]]") != std::string::npos);
    assert(result.str().find("unused_") == std::string::npos);
    assert(buffer.bytes_read < static_cast<std::streamsize>(bytes.size() / 10));
    std::cout << "Indexed fixture read " << buffer.bytes_read << " of " << bytes.size()
              << " bytes for one signal across two blocks\n";

    std::istringstream full(bytes);
    q3a::trace::visit_indexed_witness(full, model, "p_test", frames.size(),
        [](std::uint64_t) {},
        [&](const q3a::replay::FrameView& view, std::size_t candidate) {
            assert(candidate == 258);
            assert(view.size() == frames.size());
            for (std::size_t i = 0; i < frames.size(); ++i) assert(view[i] == frames[i]);
            for (std::size_t i : {255, 256, 257, 511, 512, 0, 1023, 255}) {
                assert(view[i] == frames[i]);
            }
        });

    auto malformed = bytes;
    malformed.back() = static_cast<char>(0x80);
    std::istringstream invalid_input(malformed);
    bool rejected = false;
    try {
        q3a::trace::write_indexed_window(invalid_input, result, 255, 260, {"wide"});
    } catch (const std::invalid_argument&) {
        rejected = true;
    }
    assert(rejected);
}
