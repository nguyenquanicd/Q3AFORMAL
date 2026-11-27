#include "transition_encoder.hpp"

#include <algorithm>
#include <functional>
#include <limits>
#include <stdexcept>
#include <unordered_map>
#include <unordered_set>

namespace q3a::sat {

Status TransitionCnfEncoder::assertion_activity(
    const AssertionQuery& query, const std::vector<std::int8_t>& feasible_assignment) {
    if (query.always_active) return Status::Satisfiable;
    if (query.activation_literals.empty()) return Status::Unsatisfiable;
    const auto active = std::any_of(query.activation_literals.begin(),
        query.activation_literals.end(), [&](Literal literal) {
            const auto variable = static_cast<std::size_t>(
                literal < 0 ? -static_cast<std::int64_t>(literal) : literal);
            return feasible_assignment.at(variable) == (literal > 0 ? 1 : 0);
        });
    if (active) return Status::Satisfiable;
    return solver_.solve_with_temporary_clause(query.activation_literals).status;
}
namespace {

constexpr std::uint64_t kMaximumTransitions = 10000;
constexpr std::size_t kMaximumSequenceExpansions = 4096;
constexpr std::uint64_t kMaximumSequencePredicateEvaluations = 1000000;

bool is_state_role(const std::string& role) {
    return role == "state" || role == "history_data" ||
        role == "history_valid";
}

std::string source_prefix(const frontend::SourceLocation& location) {
    if (location.file.empty()) return {};
    return location.file + ":" + std::to_string(location.line) + ":" +
        std::to_string(location.column) + ": ";
}

} // namespace

TransitionCnfEncoder::TransitionCnfEncoder(
    Solver& solver, const lowering::TIRModule& module)
    : solver_(solver), module_(module) {
    validate();
}

void TransitionCnfEncoder::validate() const {
    if (module_.semantic_profile == frontend::kFourStateProfile) {
        throw std::invalid_argument("four-state models require the development evaluator");
    }
    if (module_.clocks.size() > 1) {
        throw std::invalid_argument(
            "transition CNF supports exactly one synchronous clock domain");
    }
    std::unordered_map<std::string, const lowering::TIRSignal*> signals;
    for (const auto& signal : module_.signals) {
        if (signal.name.empty() || signal.width == 0 || signal.width > 64) {
            throw std::invalid_argument(source_prefix(signal.location) +
                "signal has an empty name or width outside 1..64: " + signal.name);
        }
        if (!signals.emplace(signal.name, &signal).second) {
            throw std::invalid_argument(source_prefix(signal.location) +
                "duplicate TIR signal: " + signal.name);
        }
        if (signal.role != "input" && signal.role != "output" &&
            signal.role != "internal" && !is_state_role(signal.role)) {
            throw std::invalid_argument(source_prefix(signal.location) +
                "unsupported TIR signal role '" + signal.role + "'");
        }
    }
    for (const auto& guard : module_.history_guards) {
        for (const auto& name : guard.state_chain) {
            const auto signal = signals.find(name);
            if (signal == signals.end() ||
                signal->second->role != "history_valid" ||
                signal->second->width != 1) {
                throw std::invalid_argument(
                    "history guard references a missing or invalid one-bit state: '" +
                    name + "'");
            }
        }
    }

    const std::function<void(const lowering::TypedExpression&)> validate_expression =
        [&](const lowering::TypedExpression& expression) {
            if (expression.kind == "signal") {
                const auto signal = signals.find(expression.value);
                if (signal == signals.end()) {
                    throw std::invalid_argument(source_prefix(expression.location) +
                        "T-IR expression references unknown signal '" +
                        expression.value + "'");
                }
                if (expression.width != signal->second->width ||
                    expression.is_signed != signal->second->is_signed) {
                    throw std::invalid_argument(source_prefix(expression.location) +
                        "T-IR expression type disagrees with signal '" +
                        expression.value + "'");
                }
            }
            for (const auto& operand : expression.operands) {
                validate_expression(operand);
            }
        };

    std::unordered_set<std::string> comb_targets;
    for (const auto& equation : module_.combinational_equations) {
        const auto target = signals.find(equation.target);
        if (target == signals.end()) {
            throw std::invalid_argument(source_prefix(equation.location) +
                "combinational equation targets unknown signal '" + equation.target + "'");
        }
        if (target->second->role == "input" || is_state_role(target->second->role)) {
            throw std::invalid_argument(source_prefix(equation.location) +
                "combinational equation cannot drive " + target->second->role +
                " signal '" + equation.target + "'");
        }
        if (!comb_targets.insert(equation.target).second) {
            throw std::invalid_argument(source_prefix(equation.location) +
                "multiple combinational drivers for '" + equation.target + "'");
        }
        if (equation.target_width != target->second->width ||
            equation.expression.width != target->second->width) {
            throw std::invalid_argument(source_prefix(equation.location) +
                "combinational equation width mismatch for '" + equation.target + "'");
        }
        validate_expression(equation.expression);
    }

    std::unordered_set<std::string> next_targets;
    for (const auto& equation : module_.next_state_equations) {
        const auto target = signals.find(equation.target);
        if (target == signals.end()) {
            throw std::invalid_argument(source_prefix(equation.location) +
                "next-state equation targets unknown signal '" + equation.target + "'");
        }
        if (!is_state_role(target->second->role)) {
            throw std::invalid_argument(source_prefix(equation.location) +
                "next-state equation target is not state: '" + equation.target + "'");
        }
        if (!next_targets.insert(equation.target).second) {
            throw std::invalid_argument(source_prefix(equation.location) +
                "multiple next-state drivers for '" + equation.target + "'");
        }
        if (equation.target_width != target->second->width ||
            equation.expression.width != target->second->width) {
            throw std::invalid_argument(source_prefix(equation.location) +
                "next-state equation width mismatch for '" + equation.target + "'");
        }
        validate_expression(equation.expression);
    }

    for (const auto& signal : module_.signals) {
        if (is_state_role(signal.role) && next_targets.count(signal.name) == 0) {
            throw std::invalid_argument(source_prefix(signal.location) +
                "state signal has no next-state equation: '" + signal.name + "'");
        }
        if (signal.role == "output" && comb_targets.count(signal.name) == 0 &&
            next_targets.count(signal.name) == 0) {
            throw std::invalid_argument(source_prefix(signal.location) +
                "output has no driver in the lowered transition model: '" + signal.name + "'");
        }
    }
}

void TransitionCnfEncoder::equate(
    const std::vector<Literal>& left,
    const std::vector<Literal>& right,
    const lowering::TIREquation& equation) {
    if (left.size() != right.size()) {
        throw std::invalid_argument(source_prefix(equation.location) +
            "bit-blasted equation width mismatch for '" + equation.target + "'");
    }
    for (std::size_t bit = 0; bit < left.size(); ++bit) {
        solver_.add_clause({static_cast<Literal>(-left[bit]), right[bit]});
        solver_.add_clause({left[bit], static_cast<Literal>(-right[bit])});
    }
}

void TransitionCnfEncoder::validate_property_clock_and_guard(
    const lowering::TIRProperty& property) const {
    if (frames_.empty()) {
        throw std::logic_error("encode transition frames before compiling properties");
    }
    if (module_.clocks.size() != 1 || property.clock != module_.clocks.front()) {
        throw std::invalid_argument(source_prefix(property.location) +
            "bounded property clock must match the module's single clock");
    }
    for (const auto* guard_name : {&property.history_guard_signal,
             &lowering::antecedent_history_guard(property),
             &lowering::consequent_history_guard(property)}) {
        if (guard_name->empty()) continue;
        const auto found = frames_.front().find(*guard_name);
        if (found == frames_.front().end() || found->second.size() != 1) {
            throw std::invalid_argument(source_prefix(property.location) +
                "property history guard is missing or is not one bit");
        }
    }
}

void TransitionCnfEncoder::validate_property_expression(
    const lowering::TypedExpression& expression) const {
    if (expression.kind == "signal" || expression.kind == "history_ref") {
        const auto signal = std::find_if(
            module_.signals.begin(), module_.signals.end(),
            [&](const lowering::TIRSignal& candidate) {
                return candidate.name == expression.value;
            });
        if (signal == module_.signals.end() ||
            signal->width != expression.width ||
            signal->is_signed != expression.is_signed) {
            throw std::invalid_argument(source_prefix(expression.location) +
                "property references missing or type-mismatched signal '" +
                expression.value + "'");
        }
    }
    for (const auto& operand : expression.operands) {
        validate_property_expression(operand);
    }
}

std::uint64_t TransitionCnfEncoder::sequence_max_offset(
    const lowering::TIRSequence& sequence) const {
    for (const auto& transition : sequence.automaton.transitions) {
        validate_property_expression(transition.predicate);
    }
    return lowering::sequence_maximum_offset(sequence);
}

Literal TransitionCnfEncoder::make_and(Literal left, Literal right) {
    if (left == 0) return right;
    if (right == 0) return left;
    if (left == right) return left;
    const auto result = static_cast<Literal>(solver_.new_variable());
    solver_.add_clause({static_cast<Literal>(-result), left});
    solver_.add_clause({static_cast<Literal>(-result), right});
    solver_.add_clause({result, static_cast<Literal>(-left),
                        static_cast<Literal>(-right)});
    return result;
}

Literal TransitionCnfEncoder::make_or(Literal left, Literal right) {
    if (left == 0) return right;
    if (right == 0) return left;
    if (left == right) return left;
    const auto result = static_cast<Literal>(solver_.new_variable());
    solver_.add_clause({static_cast<Literal>(-left), result});
    solver_.add_clause({static_cast<Literal>(-right), result});
    solver_.add_clause({static_cast<Literal>(-result), left, right});
    return result;
}

std::vector<TransitionCnfEncoder::SequenceMatch>
TransitionCnfEncoder::sequence_matches(
    const lowering::TIRSequence& sequence,
    std::size_t start_frame,
    std::uint64_t& predicate_budget) {
    std::vector<SequenceMatch> matches;
    const auto last_frame = frames_.size() - 1;
    const auto paths = lowering::sequence_paths(sequence);
    for (const auto& path : paths) {
        std::vector<SequenceMatch> partial{{start_frame, 0}};
        for (auto index = path.begin; index < path.end; ++index) {
            const auto& transition = sequence.automaton.transitions[index];
            std::vector<SequenceMatch> next;
            const bool can_converge = partial.size() > 1 &&
                transition.repeat_min != transition.repeat_max;
            std::unordered_map<std::size_t, std::size_t> endpoint_slots;
            for (const auto& previous : partial) {
                if (transition.delay_cycles > last_frame - previous.end_frame) continue;
                const auto term_start = previous.end_frame +
                    static_cast<std::size_t>(transition.delay_cycles);
                const auto fitting = std::min<std::uint64_t>(transition.repeat_max, frames_.size() - term_start);
                if (fitting < transition.repeat_min) continue;
                Literal term_match = 0;
                for (std::uint64_t repeat = 1; repeat <= fitting; ++repeat) {
                    if (predicate_budget == 0) {
                        throw std::invalid_argument(
                            "sequence predicate expansion exceeds the BMC budget of 1000000 evaluations");
                    }
                    --predicate_budget;
                    const auto sample = term_start + static_cast<std::size_t>(repeat - 1);
                    term_match = make_and(term_match,
                        bitblasters_[sample]->encode_predicate(transition.predicate));
                    if (repeat < transition.repeat_min) continue;
                    const auto match_literal = make_and(previous.match_literal, term_match);
                    // All continuations from this automaton state and end frame
                    // see the same samples. Their enabling conditions can be ORed.
                    if (can_converge) {
                        const auto [slot, inserted] = endpoint_slots.try_emplace(sample, next.size());
                        if (!inserted) {
                            auto& merged = next[slot->second].match_literal;
                            merged = make_or(merged, match_literal);
                            continue;
                        }
                    }
                    next.push_back(SequenceMatch{sample, match_literal});
                    if (next.size() > kMaximumSequenceExpansions) {
                        throw std::invalid_argument(
                            "sequence match count exceeds the BMC limit of 4096 paths");
                    }
                }
            }
            partial = std::move(next);
            if (partial.empty()) break;
        }
        if (paths.size() == 1) return partial;
        matches.insert(matches.end(), partial.begin(), partial.end());
    }
    return matches;
}

void TransitionCnfEncoder::constrain_assumptions() {
    if (frames_.empty()) {
        throw std::logic_error("encode transition frames before compiling properties");
    }
    constrain_assumptions(frames_.size() - 1, false);
}

void TransitionCnfEncoder::constrain_assumptions(
    std::size_t last_relevant_frame) {
    constrain_assumptions(last_relevant_frame, true);
}

void TransitionCnfEncoder::constrain_assumptions(
    std::size_t last_relevant_frame,
    bool truncate_open_temporal_tail) {
    if (frames_.empty()) {
        throw std::logic_error("encode transition frames before compiling properties");
    }
    const auto last_frame = std::min(frames_.size() - 1, last_relevant_frame);
    assumptions_boundary_incomplete_ = false;
    for (const auto& property : module_.properties) {
        if (property.kind != "assume") continue;
        validate_property_clock_and_guard(property);
        if (property.implication.empty() || property.implication == "sequence") {
            const auto assumption_horizon =
                lowering::bounded_scalar_sequence_horizon(property.antecedent);
            if (property.consequent.has_value() || !assumption_horizon.has_value()) {
                throw std::invalid_argument(source_prefix(property.location) +
                    "assumption constraint requires a bounded linear sequence");
            }
            for (const auto& transition : property.antecedent.automaton.transitions) {
                validate_property_expression(transition.predicate);
            }
            if (truncate_open_temporal_tail &&
                *assumption_horizon > last_frame) {
                continue;
            }
            const auto last_assumption_start = truncate_open_temporal_tail
                ? last_frame - static_cast<std::size_t>(*assumption_horizon)
                : last_frame;
            auto predicate_budget = kMaximumSequencePredicateEvaluations;
            for (std::size_t start = 0; start <= last_assumption_start; ++start) {
                if (*assumption_horizon > last_frame - start) {
                    assumptions_boundary_incomplete_ = true;
                    continue;
                }
                const auto matches = sequence_matches(
                    property.antecedent, start, predicate_budget);
                if (matches.empty()) {
                    throw std::logic_error(
                        "complete assumption horizon produced no sequence expansion");
                }
                Literal sequence_match = 0;
                for (const auto& match : matches) {
                    sequence_match = make_or(sequence_match, match.match_literal);
                }
                const auto& guard_name =
                    lowering::antecedent_history_guard(property);
                if (guard_name.empty()) {
                    solver_.add_clause({sequence_match});
                } else {
                    const auto guard = frames_[start].at(
                        guard_name).front();
                    solver_.add_clause({static_cast<Literal>(-guard), sequence_match});
                }
            }
            continue;
        }
        if (property.implication == "overlapped" &&
            property.consequent.has_value() &&
            lowering::is_same_sample_sequence(property.antecedent) &&
            lowering::is_same_sample_sequence(*property.consequent)) {
            std::vector<Literal> antecedent_values;
            antecedent_values.reserve(property.antecedent.automaton.transitions.size());
            for (const auto& transition : property.antecedent.automaton.transitions) {
                validate_property_expression(transition.predicate);
            }
            for (const auto& transition : property.consequent->automaton.transitions) {
                validate_property_expression(transition.predicate);
            }
            for (std::size_t frame = 0; frame <= last_frame; ++frame) {
                antecedent_values.clear();
                for (const auto& transition : property.antecedent.automaton.transitions) {
                    antecedent_values.push_back(
                        bitblasters_[frame]->encode_predicate(transition.predicate));
                }
                for (const auto& transition : property.consequent->automaton.transitions) {
                    std::vector<Literal> clause;
                    clause.reserve(antecedent_values.size() + 3);
                    const auto& antecedent_guard =
                        lowering::antecedent_history_guard(property);
                    const auto& consequent_guard =
                        lowering::consequent_history_guard(property);
                    if (!antecedent_guard.empty()) {
                        const auto guard = frames_[frame].at(
                            antecedent_guard).front();
                        clause.push_back(static_cast<Literal>(-guard));
                    }
                    if (!consequent_guard.empty()) {
                        const auto guard = frames_[frame].at(
                            consequent_guard).front();
                        clause.push_back(static_cast<Literal>(-guard));
                    }
                    for (const auto antecedent_value : antecedent_values) {
                        clause.push_back(static_cast<Literal>(-antecedent_value));
                    }
                    clause.push_back(bitblasters_[frame]->encode_predicate(
                        transition.predicate));
                    solver_.add_clause(std::move(clause));
                }
            }
            continue;
        }
        if ((property.implication != "overlapped" &&
             property.implication != "nonoverlapped") ||
            !property.consequent.has_value()) {
            throw std::invalid_argument(source_prefix(property.location) +
                "unsupported assumption property form");
        }
        const auto consequent_offset = sequence_max_offset(*property.consequent);
        const auto antecedent_offset = sequence_max_offset(property.antecedent);
        auto predicate_budget = kMaximumSequencePredicateEvaluations;
        auto last_assumption_start = last_frame;
        if (truncate_open_temporal_tail) {
            const auto delta = property.implication == "nonoverlapped"
                ? std::uint64_t{1} : 0;
            if (antecedent_offset > std::numeric_limits<std::uint64_t>::max() - delta ||
                consequent_offset > std::numeric_limits<std::uint64_t>::max() - delta -
                    antecedent_offset) {
                throw std::invalid_argument(source_prefix(property.location) +
                    "assumption horizon overflows the supported range");
            }
            const auto assumption_horizon = antecedent_offset + delta + consequent_offset;
            if (assumption_horizon > last_frame) continue;
            last_assumption_start = last_frame -
                static_cast<std::size_t>(assumption_horizon);
        }
        for (std::size_t start = 0; start <= last_assumption_start; ++start) {
            if (antecedent_offset > last_frame - start) {
                assumptions_boundary_incomplete_ = true;
            }
            const auto antecedent_matches = sequence_matches(
                property.antecedent, start, predicate_budget);
            for (const auto& antecedent : antecedent_matches) {
                const auto delta = property.implication == "nonoverlapped" ? 1U : 0U;
                if (delta > last_frame ||
                    antecedent.end_frame > last_frame - delta) {
                    assumptions_boundary_incomplete_ = true;
                    continue;
                }
                const auto consequent_start = antecedent.end_frame + delta;
                if (consequent_offset > last_frame - consequent_start) {
                    assumptions_boundary_incomplete_ = true;
                    continue;
                }
                const auto consequent_matches = sequence_matches(
                    *property.consequent, consequent_start, predicate_budget);
                if (consequent_matches.empty()) {
                    throw std::logic_error(
                        "complete consequent horizon produced no sequence expansion");
                }
                Literal consequent_match = 0;
                for (const auto& match : consequent_matches) {
                    consequent_match = make_or(consequent_match, match.match_literal);
                }
                auto antecedent_match = antecedent.match_literal;
                const auto& antecedent_guard =
                    lowering::antecedent_history_guard(property);
                const auto& consequent_guard =
                    lowering::consequent_history_guard(property);
                if (!antecedent_guard.empty()) {
                    antecedent_match = make_and(antecedent_match,
                        frames_[start].at(antecedent_guard).front());
                }
                if (!consequent_guard.empty()) {
                    antecedent_match = make_and(antecedent_match,
                        frames_[consequent_start].at(consequent_guard).front());
                }
                solver_.add_clause({static_cast<Literal>(-antecedent_match),
                                    consequent_match});
            }
        }
    }
}

TransitionCnfEncoder::AssertionQuery TransitionCnfEncoder::add_assertion_violation(
    const std::string& property_name) {
    if (frames_.empty()) {
        throw std::logic_error("encode transition frames before compiling properties");
    }
    const auto property = std::find_if(
        module_.properties.begin(), module_.properties.end(),
        [&](const lowering::TIRProperty& candidate) {
            return candidate.name == property_name && candidate.kind == "assert";
        });
    if (property == module_.properties.end()) {
        const auto named_property = std::find_if(
            module_.properties.begin(), module_.properties.end(),
            [&](const lowering::TIRProperty& candidate) {
                return candidate.name == property_name;
            });
        if (named_property == module_.properties.end()) {
            throw std::invalid_argument("unknown assertion property name '" +
                property_name + "'");
        }
        throw std::invalid_argument("bounded query target must have kind 'assert'");
    }
    validate_property_clock_and_guard(*property);
    AssertionQuery query;
    if (property->implication.empty() || property->implication == "sequence") {
        if (property->consequent.has_value()) {
            throw std::invalid_argument(source_prefix(property->location) +
                "standalone sequence assertion cannot have a consequent");
        }
        const auto sequence_horizon =
            lowering::bounded_scalar_sequence_horizon(property->antecedent);
        if (!sequence_horizon.has_value()) {
            throw std::invalid_argument(source_prefix(property->location) +
                "bounded sequence assertion requires a supported linear sequence");
        }
        for (const auto& transition : property->antecedent.automaton.transitions) {
            validate_property_expression(transition.predicate);
        }
        const auto& antecedent_guard =
            lowering::antecedent_history_guard(*property);
        auto predicate_budget = kMaximumSequencePredicateEvaluations;
        const auto last_frame = frames_.size() - 1;
        query.always_active = antecedent_guard.empty() && *sequence_horizon <= last_frame;
        for (std::size_t start = 0; start < frames_.size(); ++start) {
            if (*sequence_horizon > last_frame - start) {
                query.boundary_incomplete = true;
                continue;
            }
            const auto matches = sequence_matches(
                property->antecedent, start, predicate_budget);
            if (matches.empty()) {
                throw std::logic_error(
                    "complete assertion horizon produced no sequence expansion");
            }
            Literal sequence_match = 0;
            for (const auto& match : matches) {
                sequence_match = make_or(sequence_match, match.match_literal);
            }
            if (antecedent_guard.empty()) {
                query.violation_literals.push_back(
                    static_cast<Literal>(-sequence_match));
            } else {
                const auto guard = frames_[start].at(
                    antecedent_guard).front();
                query.activation_literals.push_back(guard);
                query.violation_literals.push_back(make_and(
                    guard, static_cast<Literal>(-sequence_match)));
            }
            query.violation_frames.push_back(start);
        }
        return query;
    }

    if ((property->implication != "overlapped" &&
         property->implication != "nonoverlapped") ||
        !property->consequent.has_value()) {
        throw std::invalid_argument(source_prefix(property->location) +
            "unsupported assertion implication form");
    }
    const auto consequent_offset = sequence_max_offset(*property->consequent);
    const auto antecedent_offset = sequence_max_offset(property->antecedent);
    auto predicate_budget = kMaximumSequencePredicateEvaluations;
    const auto last_frame = frames_.size() - 1;
    for (std::size_t start = 0; start < frames_.size(); ++start) {
        if (antecedent_offset > last_frame - start) {
            query.boundary_incomplete = true;
        }
        const auto antecedent_matches = sequence_matches(
            property->antecedent, start, predicate_budget);
        for (const auto& antecedent : antecedent_matches) {
            const auto delta = property->implication == "nonoverlapped" ? 1U : 0U;
            if (delta > last_frame ||
                antecedent.end_frame > last_frame - delta) {
                query.boundary_incomplete = true;
                continue;
            }
            const auto consequent_start = antecedent.end_frame + delta;
            if (consequent_offset > last_frame - consequent_start) {
                query.boundary_incomplete = true;
                continue;
            }
            const auto consequent_matches = sequence_matches(
                *property->consequent, consequent_start, predicate_budget);
            if (consequent_matches.empty()) {
                throw std::logic_error(
                    "complete consequent horizon produced no sequence expansion");
            }
            Literal consequent_match = 0;
            for (const auto& match : consequent_matches) {
                consequent_match = make_or(consequent_match, match.match_literal);
            }
            auto antecedent_match = antecedent.match_literal;
            const auto& antecedent_guard =
                lowering::antecedent_history_guard(*property);
            const auto& consequent_guard =
                lowering::consequent_history_guard(*property);
            if (!antecedent_guard.empty()) {
                antecedent_match = make_and(antecedent_match,
                    frames_[start].at(antecedent_guard).front());
            }
            if (!consequent_guard.empty()) {
                antecedent_match = make_and(antecedent_match,
                    frames_[consequent_start].at(consequent_guard).front());
            }
            query.activation_literals.push_back(antecedent_match);
            const auto failure = make_and(
                antecedent_match, static_cast<Literal>(-consequent_match));
            query.violation_literals.push_back(failure);
            query.violation_frames.push_back(consequent_start);
        }
    }
    return query;
}

std::vector<Literal> TransitionCnfEncoder::encode_induction_obligation(
    const lowering::TIRProperty& property, std::uint64_t depth, bool base) {
    const auto horizon = lowering::bounded_induction_property_horizon(property);
    if (property.kind != "assert" || !horizon || depth == 0 ||
        *horizon > 10000 || depth > 10000 - *horizon) {
        throw std::invalid_argument("unsupported induction target or depth");
    }
    for (const auto& assumption : module_.properties) {
        if (assumption.kind == "assume" &&
            !lowering::bounded_induction_property_horizon(assumption)) {
            throw std::invalid_argument("unsupported induction assumption");
        }
    }
    const auto final_frame = static_cast<std::size_t>(depth - (base ? 1 : 0) + *horizon);
    encode(final_frame, base);
    constrain_assumptions(final_frame);
    if (assumptions_boundary_incomplete()) {
        throw std::invalid_argument("induction obligation has an incomplete assumption boundary");
    }

    std::vector<Literal> property_values;
    property_values.reserve(static_cast<std::size_t>(depth + (base ? 0 : 1)));
    if (base) {
        std::vector<Literal> violations;
        violations.reserve(static_cast<std::size_t>(depth));
        for (std::uint64_t frame = 0; frame < depth; ++frame) {
            const auto value = encode_induction_assertion_at_frame(property.name, frame);
            property_values.push_back(value);
            violations.push_back(-value);
        }
        solver_.add_clause(violations);
    } else {
        for (std::uint64_t frame = 0; frame < depth; ++frame) {
            const auto value = encode_induction_assertion_at_frame(property.name, frame);
            property_values.push_back(value);
            solver_.add_clause({value});
        }
        const auto next = encode_induction_assertion_at_frame(property.name, depth);
        property_values.push_back(next);
        solver_.add_clause({-next});
    }
    return property_values;
}

Literal TransitionCnfEncoder::encode_induction_assertion_at_frame(
    const std::string& property_name, std::size_t frame) {
    if (frames_.empty()) {
        throw std::logic_error("encode transition frames before compiling properties");
    }
    if (frame >= frames_.size()) {
        throw std::out_of_range("induction property frame is outside the encoded model");
    }
    const auto property = std::find_if(
        module_.properties.begin(), module_.properties.end(),
        [&](const lowering::TIRProperty& candidate) {
            return candidate.name == property_name && candidate.kind == "assert";
        });
    if (property == module_.properties.end()) {
        throw std::invalid_argument(
            "induction target must be an assertion property");
    }
    if (!lowering::bounded_induction_property_horizon(*property).has_value()) {
        throw std::invalid_argument(source_prefix(property->location) +
            "unsupported assertion or implication form for k-induction");
    }
    Literal predicate = 0;
    if (!property->consequent.has_value()) {
        validate_property_clock_and_guard(*property);
        for (const auto& transition : property->antecedent.automaton.transitions) {
            validate_property_expression(transition.predicate);
        }
        auto predicate_budget = kMaximumSequencePredicateEvaluations;
        const auto matches = sequence_matches(
            property->antecedent, frame, predicate_budget);
        if (matches.empty()) {
            throw std::logic_error(
                "complete induction horizon produced no scalar sequence expansion");
        }
        for (const auto& match : matches) {
            predicate = make_or(predicate, match.match_literal);
        }
        const auto& antecedent_guard =
            lowering::antecedent_history_guard(*property);
        if (!antecedent_guard.empty()) {
            predicate = make_or(static_cast<Literal>(-
                frames_[frame].at(antecedent_guard).front()), predicate);
        }
    } else if ((property->implication == "overlapped" ||
                property->implication == "nonoverlapped") &&
               property->consequent.has_value()) {
        validate_property_clock_and_guard(*property);
        for (const auto& transition : property->antecedent.automaton.transitions) {
            validate_property_expression(transition.predicate);
        }
        for (const auto& transition : property->consequent->automaton.transitions) {
            validate_property_expression(transition.predicate);
        }
        const auto& antecedent_guard =
            lowering::antecedent_history_guard(*property);
        const auto& consequent_guard =
            lowering::consequent_history_guard(*property);
        auto predicate_budget = kMaximumSequencePredicateEvaluations;
        const auto antecedent_matches = sequence_matches(
            property->antecedent, frame, predicate_budget);
        const auto last_frame = frames_.size() - 1;
        const auto delta = property->implication == "nonoverlapped"
            ? std::size_t{1} : std::size_t{0};
        for (const auto& antecedent : antecedent_matches) {
            if (delta > last_frame || antecedent.end_frame > last_frame - delta) {
                throw std::out_of_range(
                    "induction implication exceeds the encoded sample window");
            }
            const auto consequent_start = antecedent.end_frame + delta;
            const auto consequent_matches = sequence_matches(
                *property->consequent, consequent_start, predicate_budget);
            if (consequent_matches.empty()) {
                throw std::logic_error(
                    "complete induction horizon produced no consequent sequence expansion");
            }
            Literal consequent_match = 0;
            for (const auto& match : consequent_matches) {
                consequent_match = make_or(consequent_match, match.match_literal);
            }
            auto obligation = make_or(
                static_cast<Literal>(-antecedent.match_literal),
                consequent_match);
            if (!antecedent_guard.empty()) {
                obligation = make_or(static_cast<Literal>(-
                    frames_[frame].at(antecedent_guard).front()), obligation);
            }
            if (!consequent_guard.empty()) {
                obligation = make_or(static_cast<Literal>(-
                    frames_[consequent_start].at(consequent_guard).front()),
                    obligation);
            }
            predicate = make_and(predicate, obligation);
        }
    } else {
        throw std::invalid_argument(source_prefix(property->location) +
            "unsupported assertion or implication form for k-induction");
    }
    if (property->split_history_guards ||
        property->history_guard_signal.empty()) return predicate;

    const auto guard = frames_[frame].at(property->history_guard_signal).front();
    return make_or(static_cast<Literal>(-guard), predicate);
}

TransitionCnfEncoder::CoverQuery TransitionCnfEncoder::add_cover_hit(
    const std::string& property_name) {
    if (frames_.empty()) {
        throw std::logic_error("encode transition frames before compiling properties");
    }
    const auto property = std::find_if(
        module_.properties.begin(), module_.properties.end(),
        [&](const lowering::TIRProperty& candidate) {
            return candidate.name == property_name && candidate.kind == "cover";
        });
    if (property == module_.properties.end()) {
        const auto named_property = std::find_if(
            module_.properties.begin(), module_.properties.end(),
            [&](const lowering::TIRProperty& candidate) {
                return candidate.name == property_name;
            });
        if (named_property == module_.properties.end()) {
            throw std::invalid_argument("unknown cover property name '" +
                property_name + "'");
        }
        throw std::invalid_argument("bounded query target must have kind 'cover'");
    }
    validate_property_clock_and_guard(*property);
    const bool implication_cover = property->implication == "overlapped" ||
        property->implication == "nonoverlapped";
    if ((implication_cover != property->consequent.has_value()) ||
        (!implication_cover && !property->implication.empty() &&
         property->implication != "sequence")) {
        throw std::invalid_argument(source_prefix(property->location) +
            "bounded cover supports scalar, linear sequence, and linear implication goals");
    }

    CoverQuery query;
    const auto last_frame = frames_.size() - 1;
    auto predicate_budget = kMaximumSequencePredicateEvaluations;
    if (implication_cover) {
        const auto antecedent_offset = sequence_max_offset(property->antecedent);
        const auto consequent_offset = sequence_max_offset(*property->consequent);
        const auto delta = property->implication == "nonoverlapped" ? 1U : 0U;
        for (std::size_t start = 0; start < frames_.size(); ++start) {
            if (antecedent_offset > last_frame - start) {
                query.boundary_limited = true;
            }
            const auto antecedent_matches = sequence_matches(
                property->antecedent, start, predicate_budget);
            for (const auto& antecedent : antecedent_matches) {
                if (delta > last_frame ||
                    antecedent.end_frame > last_frame - delta) {
                    query.boundary_limited = true;
                    continue;
                }
                const auto consequent_start = antecedent.end_frame + delta;
                const bool incomplete = consequent_offset > last_frame - consequent_start;
                if (incomplete) {
                    query.boundary_limited = true;
                }
                const auto consequent_matches = sequence_matches(
                    *property->consequent, consequent_start, predicate_budget);
                if (consequent_matches.empty() && !incomplete) {
                    throw std::logic_error(
                        "complete cover consequent horizon produced no sequence expansion");
                }
                for (const auto& consequent : consequent_matches) {
                    auto hit = make_and(antecedent.match_literal,
                                        consequent.match_literal);
                    const auto& antecedent_guard =
                        lowering::antecedent_history_guard(*property);
                    const auto& consequent_guard =
                        lowering::consequent_history_guard(*property);
                    if (!antecedent_guard.empty()) {
                        hit = make_and(hit, frames_[start].at(
                            antecedent_guard).front());
                    }
                    if (!consequent_guard.empty()) {
                        hit = make_and(hit, frames_[consequent_start].at(
                            consequent_guard).front());
                    }
                    query.hit_literals.push_back(hit);
                    query.hit_frames.push_back(consequent.end_frame);
                }
            }
        }
        return query;
    }

    const auto& automaton = property->antecedent.automaton;
    if (automaton.transitions.size() == 1) {
        const auto& transition = automaton.transitions.front();
        if (transition.delay_cycles == 0 && transition.repeat_min == 1 &&
            transition.repeat_max == 1) {
            validate_property_expression(transition.predicate);
            const auto& antecedent_guard =
                lowering::antecedent_history_guard(*property);
            for (std::size_t frame = 0; frame < frames_.size(); ++frame) {
                auto hit = bitblasters_[frame]->encode_predicate(transition.predicate);
                if (!antecedent_guard.empty()) {
                    hit = make_and(hit, frames_[frame].at(
                        antecedent_guard).front());
                }
                query.hit_literals.push_back(hit);
                query.hit_frames.push_back(frame);
            }
            return query;
        }
    }

    const auto maximum_offset = sequence_max_offset(property->antecedent);
    for (std::size_t start = 0; start < frames_.size(); ++start) {
        if (maximum_offset > last_frame - start) query.boundary_limited = true;
        const auto matches = sequence_matches(
            property->antecedent, start, predicate_budget);
        for (const auto& match : matches) {
            auto hit = match.match_literal;
            const auto& antecedent_guard =
                lowering::antecedent_history_guard(*property);
            if (!antecedent_guard.empty()) {
                hit = make_and(hit, frames_[start].at(
                    antecedent_guard).front());
            }
            query.hit_literals.push_back(hit);
            query.hit_frames.push_back(match.end_frame);
        }
    }
    return query;
}

void TransitionCnfEncoder::encode(
    std::uint64_t transition_count, bool initialize_history_validity) {
    if (transition_count > kMaximumTransitions) {
        throw std::invalid_argument("transition count exceeds safety limit 10000");
    }
    const auto frame_count = static_cast<std::size_t>(transition_count + 1);
    bitblasters_.clear();
    frames_.clear();
    bitblasters_.reserve(frame_count);
    frames_.reserve(frame_count);

    for (std::size_t frame = 0; frame < frame_count; ++frame) {
        auto bitblaster = std::make_unique<TirBitBlaster>(solver_);
        std::map<std::string, std::vector<Literal>> signals;
        for (const auto& signal : module_.signals) {
            signals.emplace(signal.name, bitblaster->encode_signal(
                signal.name, signal.width, signal.is_signed, signal.location));
        }
        bitblasters_.push_back(std::move(bitblaster));
        frames_.push_back(std::move(signals));
    }

    // The base query starts from the T-IR initial state. An induction step is
    // intentionally unconstrained at frame zero, including generated history
    // validity state, so it covers every state satisfying the hypothesis.
    if (initialize_history_validity) {
        for (const auto& guard : module_.history_guards) {
            for (const auto& name : guard.state_chain) {
                solver_.add_clause({static_cast<Literal>(-frames_.front().at(name).front())});
            }
        }
    }

    // Continuous equations hold within each sample frame.
    for (std::size_t frame = 0; frame < frame_count; ++frame) {
        for (const auto& equation : module_.combinational_equations) {
            const auto rhs = bitblasters_[frame]->encode_bits(equation.expression);
            equate(frames_[frame].at(equation.target), rhs, equation);
        }
    }

    // A synchronous edge maps every state RHS from frame t to frame t+1.
    for (std::size_t frame = 0; frame < static_cast<std::size_t>(transition_count); ++frame) {
        for (const auto& equation : module_.next_state_equations) {
            const auto rhs = bitblasters_[frame]->encode_bits(equation.expression);
            equate(frames_[frame + 1].at(equation.target), rhs, equation);
        }
    }
}

} // namespace q3a::sat
