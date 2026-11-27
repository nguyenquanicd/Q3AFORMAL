
#pragma once

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

namespace q3a::debug {

struct WaveChange {
    std::uint64_t frame;
    std::uint64_t value;
};

struct WaveSignal {
    std::wstring name;
    unsigned width;
    std::vector<WaveChange> changes;
};

struct WaveSampleRange {
    std::uint64_t first;
    std::uint64_t last;
};

struct WaveViewport {
    std::uint64_t first;
    std::uint64_t last;
    std::uint64_t cursor;
    std::optional<std::uint64_t> witness;
    std::vector<WaveSignal> signals;
    unsigned radix = 16;
    std::vector<std::uint64_t> markers{};
    std::vector<WaveSampleRange> asserted_resets{};
};

std::size_t visible_wave_lanes(const RECT& bounds, const WaveViewport& view);
std::uint64_t sample_at_pixel(const RECT& bounds, const WaveViewport& view, int x);
void append_asserted_reset_ranges(WaveViewport& view, const WaveSignal& reset, bool active_high);
void paint_waveform(HDC context, const RECT& bounds, const WaveViewport& view);

} // namespace q3a::debug

