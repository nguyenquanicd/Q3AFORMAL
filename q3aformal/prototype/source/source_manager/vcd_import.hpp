#pragma once

#include "source_manager.hpp"
#include "../bundle/trace_capture.hpp"
#include "../replay/property_replay.hpp"

#include <functional>
#include <iosfwd>
#include <optional>
#include <string_view>

namespace q3a::trace {

void write_witness_vcd(std::ostream& output, const lowering::TIRModule& module,
                       const replay::FrameView& trace, const CaptureSignals& emitted_signals,
                       std::optional<std::size_t> failure_frame = std::nullopt,
                       std::string_view exporter = "bounded");

// Writes source-replayed logic values, preserving unknown and high-impedance bits.
void write_logic_vcd(std::ostream& output, const lowering::TIRModule& module,
                     std::size_t samples, const CaptureSignals& emitted_signals,
                     const std::function<std::string(std::size_t, const lowering::TIRSignal&)>& bits_at);

// Imports digital VCD for display. Round-trip mode additionally enforces
// Q3A timestamp and two-valued signal constraints.
void import_vcd(std::istream& input, std::ostream& output, bool roundtrip,
                const MemoryBudget& memory);

void verify_witness_vcd(std::istream& input, const lowering::TIRModule& model,
                        const CaptureSignals& signals, const replay::FrameView& frames,
                        bool source_ranges_available, const MemoryBudget& memory);

void write_vcd_viewer(std::istream& input, std::ostream& output, const MemoryBudget& memory);

} // namespace q3a::trace
