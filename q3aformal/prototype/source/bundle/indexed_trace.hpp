#pragma once

#include "../replay/property_replay.hpp"

#include <cstdint>
#include <iosfwd>
#include <optional>
#include <string>
#include <vector>

namespace q3a::trace {

inline constexpr char kIndexedTraceRole[] = "indexed_witness_trace";
inline constexpr char kIndexedInductionRole[] = "indexed_induction_witness";

void write_indexed_trace(std::ostream& output, const lowering::TIRModule& model,
                         const std::vector<replay::Frame>& frames,
                         const std::string& property, std::uint64_t candidate);

// Requires a seekable stream. Reads only the dictionary and the selected
// block/signal records. JSON values are hexadecimal strings to retain 64 bits.
void write_indexed_window(std::istream& input, std::ostream& output,
                          std::uint64_t first, std::uint64_t last,
                          const std::vector<std::string>& signals);

// Finds a change strictly before or after cursor using only the requested
// signal records. A repeated initial sample at a block boundary is not a change.
std::optional<std::uint64_t> find_indexed_transition(std::istream& input, const std::string& signal,
                                                    std::uint64_t cursor, bool forward);

// The frame view is valid for the duration of visit and retains two time blocks.
void visit_indexed_witness(
    std::istream& input, const lowering::TIRModule& model, const std::string& property,
    std::optional<std::size_t> expected_frames, const std::function<void(std::uint64_t)>& check_memory,
    const std::function<void(const replay::FrameView&, std::size_t)>& visit);

} // namespace q3a::trace
