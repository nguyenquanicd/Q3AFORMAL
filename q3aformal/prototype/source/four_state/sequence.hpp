#pragma once

#include "source.hpp"

namespace q3a { class MemoryBudget; }

namespace q3a::four_state {

struct TermSample {
    std::size_t term;
    std::size_t offset;
};

struct SequenceExpansion {
    std::vector<std::vector<TermSample>> paths;
    std::size_t horizon;
};

SequenceExpansion expand_sequence(const lowering::TIRSequence& sequence,
                                  std::size_t last_sample, const MemoryBudget& budget);

// Independently match the original automaton by advancing its per-term frontier.
std::vector<bool> matched_ends(const lowering::TIRSequence& sequence,
                               const std::vector<Frame>& trace, std::size_t start,
                               const MemoryBudget& budget);

} // namespace q3a::four_state
