#include "lowering.hpp"

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <stdexcept>

namespace q3a::lowering {

const std::string& antecedent_history_guard(
    const TIRProperty& property) noexcept {
    return property.split_history_guards
        ? property.antecedent_history_guard_signal
        : property.history_guard_signal;
}

const std::string& consequent_history_guard(
    const TIRProperty& property) noexcept {
    return property.split_history_guards
        ? property.consequent_history_guard_signal
        : property.history_guard_signal;
}

std::string expression_semantic_key(const TypedExpression& expression) {
    std::string key = expression.kind + ":" + expression.value + ":" +
        std::to_string(expression.width) + ":" +
        (expression.is_signed ? "s" : "u") + "(";
    for (const auto& operand : expression.operands) {
        key += expression_semantic_key(operand);
        key.push_back(';');
    }
    key.push_back(')');
    return key;
}

std::vector<TIRSequencePath> sequence_paths(const TIRSequence& sequence) {
    const auto& automaton = sequence.automaton;
    if (sequence.terms.empty() || sequence.terms.size() != automaton.transitions.size() ||
        automaton.start_state != 0 || automaton.accepting_state == 0 ||
        automaton.accepting_state > sequence.terms.size() ||
        automaton.state_count != automaton.accepting_state + 1) {
        throw std::invalid_argument("invalid sequence start, accepting state or term count");
    }
    std::vector<TIRSequencePath> paths;
    std::uint64_t from = 0;
    std::uint64_t next_internal = 1;
    std::size_t begin = 0;
    for (std::size_t index = 0; index < sequence.terms.size(); ++index) {
        const auto& edge = automaton.transitions[index];
        if (edge.source_state != from) {
            throw std::invalid_argument("invalid sequence automaton path order");
        }
        if (edge.target_state == automaton.accepting_state) {
            paths.push_back({begin, index + 1});
            begin = index + 1;
            from = 0;
        } else {
            if (edge.target_state != next_internal || next_internal >= automaton.accepting_state) {
                throw std::invalid_argument("invalid sequence automaton path order");
            }
            from = next_internal++;
        }
    }
    if (begin != sequence.terms.size() || next_internal != automaton.accepting_state) {
        throw std::invalid_argument("incomplete sequence automaton path");
    }
    return paths;
}

std::uint64_t sequence_maximum_offset(const TIRSequence& sequence,
                                      std::optional<std::uint64_t> maximum_paths) {
    constexpr auto limit = std::numeric_limits<std::uint64_t>::max();
    std::uint64_t maximum = 0;
    std::uint64_t total_paths = 0;
    for (const auto& path : sequence_paths(sequence)) {
        std::uint64_t offset = 0;
        std::uint64_t expansions = 1;
        for (auto index = path.begin; index < path.end; ++index) {
            const auto& edge = sequence.automaton.transitions[index];
            const auto& term = sequence.terms[index];
            if (edge.repeat_min == 0 || edge.repeat_max < edge.repeat_min ||
                edge.delay_cycles != term.delay_from_previous ||
                edge.repeat_min != term.repeat_min || edge.repeat_max != term.repeat_max ||
                edge.predicate.width != 1 ||
                expression_semantic_key(edge.predicate) != expression_semantic_key(term.predicate)) {
                throw std::invalid_argument("sequence term and automaton transition disagree");
            }
            if (maximum_paths) {
                const auto choices = edge.repeat_max - edge.repeat_min + 1;
                if (expansions > *maximum_paths / choices) {
                    throw std::invalid_argument("sequence expansion exceeds " +
                        std::to_string(*maximum_paths) + " paths");
                }
                expansions *= choices;
            }
            const auto repetitions = edge.repeat_max - 1;
            if (repetitions > limit - edge.delay_cycles ||
                offset > limit - edge.delay_cycles - repetitions) {
                throw std::invalid_argument("sequence offset overflows the supported range");
            }
            offset += edge.delay_cycles + repetitions;
        }
        if (maximum_paths) {
            if (expansions > *maximum_paths - total_paths) {
                throw std::invalid_argument("sequence expansion exceeds " +
                    std::to_string(*maximum_paths) + " paths");
            }
            total_paths += expansions;
        }
        maximum = std::max(maximum, offset);
    }
    return maximum;
}

std::optional<std::uint64_t> bounded_scalar_sequence_horizon(const TIRSequence& sequence) {
    try {
        const auto offset = sequence_maximum_offset(sequence);
        if (offset <= 10000) return offset;
    } catch (const std::invalid_argument&) {
    }
    return std::nullopt;
}

bool is_same_sample_sequence(const TIRSequence& sequence) {
    // The scalar optimization conjoins all terms, so it applies to one path only.
    const auto offset = bounded_scalar_sequence_horizon(sequence);
    return offset.has_value() && *offset == 0 &&
        sequence.automaton.state_count == sequence.terms.size() + 1;
}

std::optional<std::uint64_t> bounded_induction_property_horizon(
    const TIRProperty& property) {
    constexpr std::uint64_t maximum_horizon = 10000;
    if (!property.consequent.has_value()) {
        if (!property.implication.empty() && property.implication != "sequence") {
            return std::nullopt;
        }
        if (property.kind != "assert" && property.kind != "assume") {
            return std::nullopt;
        }
        const auto horizon = bounded_scalar_sequence_horizon(property.antecedent);
        if (!horizon.has_value()) return std::nullopt;
        if (*horizon != 0 && !property.split_history_guards &&
            !property.history_guard_signal.empty()) {
            return std::nullopt;
        }
        return horizon;
    }

    if (property.implication != "overlapped" &&
        property.implication != "nonoverlapped") {
        return std::nullopt;
    }
    const auto antecedent_horizon =
        bounded_scalar_sequence_horizon(property.antecedent);
    const auto consequent_horizon =
        bounded_scalar_sequence_horizon(*property.consequent);
    if (!antecedent_horizon.has_value() || !consequent_horizon.has_value()) {
        return std::nullopt;
    }
    const bool delayed_operand = *antecedent_horizon != 0 ||
        *consequent_horizon != 0;
    if (property.kind != "assert" && property.kind != "assume") {
        return std::nullopt;
    }
    if (!property.split_history_guards &&
        !property.history_guard_signal.empty() &&
        (property.implication != "overlapped" || delayed_operand)) {
        return std::nullopt;
    }
    const auto implication_delta =
        property.implication == "nonoverlapped" ? std::uint64_t{1} : 0;
    if (*antecedent_horizon > maximum_horizon - implication_delta ||
        *consequent_horizon > maximum_horizon - implication_delta -
            *antecedent_horizon) {
        return std::nullopt;
    }
    return *antecedent_horizon + implication_delta + *consequent_horizon;
}

} // namespace q3a::lowering
