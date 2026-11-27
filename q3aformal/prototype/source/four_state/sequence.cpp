#include "sequence.hpp"

#include "../source_manager/platform_support.hpp"

#include <algorithm>
#include <stdexcept>

namespace q3a::four_state {

SequenceExpansion expand_sequence(const lowering::TIRSequence& sequence,
                                  std::size_t last_sample, const MemoryBudget& budget) {
    const auto horizon = lowering::sequence_maximum_offset(sequence, std::nullopt);
    if (horizon > 128) {
        throw std::invalid_argument("four-state sequence must fit the finite 128-sample profile");
    }
    SequenceExpansion result{{}, static_cast<std::size_t>(horizon)};
    constexpr std::size_t maximum_terms = 1000000;
    std::size_t retained_terms = 0;
    for (const auto& path : lowering::sequence_paths(sequence)) {
        // A partial match must leave enough samples for the shortest suffix.
        // Pruning can remove only paths that could not reach any query endpoint.
        std::vector<std::size_t> minimum_suffix(path.end - path.begin + 1, 0);
        for (auto index = path.end; index > path.begin; --index) {
            const auto& term = sequence.terms[index - 1];
            const auto suffix = index - path.begin;
            minimum_suffix[suffix - 1] = minimum_suffix[suffix] +
                term.delay_from_previous + term.repeat_min - 1;
        }
        if (minimum_suffix.front() > last_sample) continue;

        std::vector<std::vector<TermSample>> chains(1);
        for (auto index = path.begin; index < path.end; ++index) {
            const auto& term = sequence.terms[index];
            std::vector<std::vector<TermSample>> following;
            std::size_t expanded_terms = 0;
            for (const auto& chain : chains) {
                const auto from = (chain.empty() ? 0 : chain.back().offset) + term.delay_from_previous;
                const auto latest = last_sample - minimum_suffix[index - path.begin + 1];
                if (from > latest || latest - from + 1 < term.repeat_min) continue;
                const auto max_count = std::min<std::size_t>(term.repeat_max, latest - from + 1);
                const auto choices = max_count - term.repeat_min + 1;
                const auto pending_terms = choices * chain.size() +
                    choices * (term.repeat_min + max_count) / 2;
                if (pending_terms > maximum_terms - retained_terms - expanded_terms) {
                    throw MemoryBudgetExceeded("four-state sequence expansion term budget exceeded");
                }
                budget.check(pending_terms * sizeof(TermSample) +
                    choices * sizeof(std::vector<TermSample>));
                expanded_terms += pending_terms;
                auto expanded = chain;
                for (std::size_t count = 1; count <= max_count; ++count) {
                    expanded.push_back({index, static_cast<std::size_t>(from + count - 1)});
                    if (count < term.repeat_min) continue;
                    following.push_back(expanded);
                }
            }
            if (index + 1 == path.end) retained_terms += expanded_terms;
            chains = std::move(following);
        }
        for (auto& chain : chains) result.paths.push_back(std::move(chain));
    }
    return result;
}

std::vector<bool> matched_ends(const lowering::TIRSequence& sequence,
                               const std::vector<Frame>& trace, std::size_t start,
                               const MemoryBudget& budget) {
    std::vector<bool> matches(trace.size(), false);
    for (const auto& path : lowering::sequence_paths(sequence)) {
        budget.check();
        std::vector<bool> reachable(trace.size(), false);
        reachable.at(start) = true;
        for (auto index = path.begin; index < path.end; ++index) {
            const auto& term = sequence.automaton.transitions[index];
            std::vector<bool> following(trace.size(), false);
            for (std::size_t end = start; end < trace.size(); ++end) {
                if (!reachable[end] || term.delay_cycles >= trace.size() - end) continue;
                auto sample = end + term.delay_cycles;
                for (std::size_t count = 1; sample < trace.size() && count <= term.repeat_max;
                     ++count, ++sample) {
                    if (!predicate_true(term.predicate, trace[sample])) break;
                    if (count >= term.repeat_min) following[sample] = true;
                }
            }
            reachable = std::move(following);
        }
        for (std::size_t end = start; end < trace.size(); ++end) matches[end] = matches[end] || reachable[end];
    }
    return matches;
}

} // namespace q3a::four_state
