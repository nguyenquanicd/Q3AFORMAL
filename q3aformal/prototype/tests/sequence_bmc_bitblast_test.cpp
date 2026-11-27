#include "transition_encoder.hpp"

#include <algorithm>
#include <iostream>
#include <map>
#include <string>
#include <utility>
#include <vector>

namespace {

using q3a::frontend::SourceLocation;
using q3a::lowering::TIRModule;
using q3a::lowering::TIRProperty;
using q3a::lowering::TIRSequence;
using q3a::lowering::TIRSequenceTerm;
using q3a::lowering::TIRSequenceTransition;
using q3a::lowering::TIRSignal;
using q3a::lowering::TypedExpression;
using q3a::sat::Literal;
using q3a::sat::Solver;

struct TermSpec {
    std::string signal;
    std::uint64_t delay = 0;
    std::uint64_t repeat_min = 1;
    std::uint64_t repeat_max = 1;
};

using Sample = std::map<std::string, bool>;

TypedExpression signal(const std::string& name) {
    return TypedExpression{"signal", name, 1, false, SourceLocation{}, {}};
}

TIRSequence sequence(const std::vector<TermSpec>& terms) {
    TIRSequence result;
    result.automaton.state_count = terms.size() + 1;
    result.automaton.start_state = 0;
    result.automaton.accepting_state = terms.size();
    for (std::size_t index = 0; index < terms.size(); ++index) {
        const auto& term = terms[index];
        const auto predicate = signal(term.signal);
        result.terms.push_back(TIRSequenceTerm{
            term.delay, term.repeat_min, term.repeat_max, predicate, SourceLocation{}});
        result.automaton.transitions.push_back(TIRSequenceTransition{
            index, index + 1, term.delay, term.repeat_min, term.repeat_max,
            predicate, SourceLocation{}});
    }
    return result;
}

TIRSequence alternative_sequences(const TIRSequence& first, const TIRSequence& second) {
    TIRSequence result;
    result.terms = first.terms;
    result.terms.insert(result.terms.end(), second.terms.begin(), second.terms.end());
    result.automaton.state_count = result.terms.size();
    const auto accept = result.automaton.state_count - 1;
    result.automaton.accepting_state = accept;
    result.automaton.transitions = first.automaton.transitions;
    result.automaton.transitions.back().target_state = accept;
    const auto shift = first.terms.size() - 1;
    for (auto edge : second.automaton.transitions) {
        if (edge.source_state != 0) edge.source_state += shift;
        edge.target_state = edge.target_state == second.automaton.accepting_state
            ? accept : edge.target_state + shift;
        result.automaton.transitions.push_back(std::move(edge));
    }
    return result;
}

std::uint64_t maximum_offset(const TIRSequence& seq) {
    std::uint64_t result = 0;
    for (const auto& term : seq.terms) {
        result += term.delay_from_previous + term.repeat_max - 1;
    }
    return result;
}

std::vector<std::size_t> sequence_ends(
    const TIRSequence& seq, std::size_t start, const std::vector<Sample>& trace) {
    std::vector<std::size_t> frontier{start};
    for (const auto& term : seq.terms) {
        std::vector<std::size_t> next;
        for (const auto previous_end : frontier) {
            const auto term_start = previous_end +
                static_cast<std::size_t>(term.delay_from_previous);
            for (std::uint64_t repeat = term.repeat_min;; ++repeat) {
                const auto term_end = term_start + static_cast<std::size_t>(repeat - 1);
                if (term_end < trace.size()) {
                    bool matches = true;
                    for (auto sample = term_start; sample <= term_end; ++sample) {
                        if (!trace[sample].at(term.predicate.value)) {
                            matches = false;
                            break;
                        }
                    }
                    if (matches) next.push_back(term_end);
                }
                if (repeat == term.repeat_max) break;
            }
        }
        frontier = std::move(next);
        if (frontier.empty()) break;
    }
    return frontier;
}

bool reference_failure(
    const TIRProperty& property, const std::vector<Sample>& trace) {
    const auto max_frame = trace.size() - 1;
    const auto consequent_offset = maximum_offset(*property.consequent);
    for (std::size_t start = 0; start < trace.size(); ++start) {
        for (const auto antecedent_end : sequence_ends(
                 property.antecedent, start, trace)) {
            const auto delta = property.implication == "nonoverlapped" ? 1U : 0U;
            if (delta > max_frame || antecedent_end > max_frame - delta) continue;
            const auto consequent_start = antecedent_end + delta;
            if (consequent_offset > max_frame - consequent_start) continue;
            if (sequence_ends(*property.consequent, consequent_start, trace).empty()) {
                return true;
            }
        }
    }
    return false;
}

bool reference_cover(
    const TIRProperty& property, const std::vector<Sample>& trace) {
    if (property.consequent.has_value() &&
        (property.implication == "overlapped" ||
         property.implication == "nonoverlapped")) {
        const auto last_frame = trace.size() - 1;
        const auto delta = property.implication == "nonoverlapped" ? 1U : 0U;
        for (std::size_t start = 0; start < trace.size(); ++start) {
            for (const auto antecedent_end : sequence_ends(
                     property.antecedent, start, trace)) {
                if (delta > last_frame ||
                    antecedent_end > last_frame - delta) continue;
                const auto consequent_start = antecedent_end + delta;
                if (!sequence_ends(*property.consequent,
                                   consequent_start, trace).empty()) {
                    return true;
                }
            }
        }
        return false;
    }
    for (std::size_t start = 0; start < trace.size(); ++start) {
        if (!sequence_ends(property.antecedent, start, trace).empty()) return true;
    }
    return false;
}

TIRModule make_module(
    const std::vector<std::string>& data_signals,
    const std::string& implication,
    const std::vector<TermSpec>& antecedent,
    const std::vector<TermSpec>& consequent) {
    TIRModule module;
    module.name = "sequence_bmc_oracle";
    module.clocks.push_back("clk");
    module.signals.push_back(TIRSignal{"clk", 1, false, "input", SourceLocation{}});
    for (const auto& name : data_signals) {
        module.signals.push_back(TIRSignal{name, 1, false, "input", SourceLocation{}});
    }
    TIRProperty property;
    property.name = "p_sequence";
    property.kind = "assert";
    property.clock = "clk";
    property.implication = implication;
    property.antecedent = sequence(antecedent);
    property.consequent = sequence(consequent);
    module.properties.push_back(std::move(property));
    return module;
}

TIRModule make_cover_module(
    const std::vector<std::string>& data_signals,
    const std::vector<TermSpec>& cover_terms) {
    TIRModule module;
    module.name = "sequence_cover_oracle";
    module.clocks.push_back("clk");
    module.signals.push_back(TIRSignal{"clk", 1, false, "input", SourceLocation{}});
    for (const auto& name : data_signals) {
        module.signals.push_back(TIRSignal{name, 1, false, "input", SourceLocation{}});
    }
    TIRProperty property;
    property.name = "c_sequence";
    property.kind = "cover";
    property.clock = "clk";
    property.implication = "sequence";
    property.antecedent = sequence(cover_terms);
    module.properties.push_back(std::move(property));
    return module;
}

TIRModule make_implication_cover_module(
    const std::vector<std::string>& data_signals,
    const std::string& implication,
    const std::vector<TermSpec>& antecedent,
    const std::vector<TermSpec>& consequent) {
    TIRModule module;
    module.name = "implication_cover_oracle";
    module.clocks.push_back("clk");
    module.signals.push_back(TIRSignal{"clk", 1, false, "input", SourceLocation{}});
    for (const auto& name : data_signals) {
        module.signals.push_back(TIRSignal{name, 1, false, "input", SourceLocation{}});
    }
    TIRProperty property;
    property.name = "c_sequence";
    property.kind = "cover";
    property.clock = "clk";
    property.implication = implication;
    property.antecedent = sequence(antecedent);
    property.consequent = sequence(consequent);
    module.properties.push_back(std::move(property));
    return module;
}

bool exhaustively_compare(const TIRModule& module, std::uint64_t transition_count,
                          const std::vector<TIRProperty>& expanded = {},
                          bool constrain_as_assumption = false) {
    Solver solver;
    q3a::sat::TransitionCnfEncoder encoder(solver, module);
    encoder.encode(transition_count);
    if (constrain_as_assumption) {
        encoder.constrain_assumptions();
    } else {
        const auto query = encoder.add_assertion_violation("p_sequence");
        solver.add_clause(query.violation_literals);
    }

    std::vector<std::string> data_signals;
    for (const auto& signal_decl : module.signals) {
        if (signal_decl.name != "clk") data_signals.push_back(signal_decl.name);
    }
    const auto frame_count = static_cast<std::size_t>(transition_count + 1);
    const auto bit_count = frame_count * data_signals.size();
    const auto trace_count = std::uint64_t{1} << bit_count;
    for (std::uint64_t encoded = 0; encoded < trace_count; ++encoded) {
        std::vector<Sample> trace(frame_count);
        std::vector<Literal> assumptions;
        assumptions.reserve(bit_count);
        std::size_t position = 0;
        for (std::size_t frame = 0; frame < frame_count; ++frame) {
            for (const auto& name : data_signals) {
                const bool value = ((encoded >> position) & 1U) != 0;
                ++position;
                trace[frame][name] = value;
                const auto variable = encoder.frames()[frame].at(name).front();
                assumptions.push_back(value ? variable : static_cast<Literal>(-variable));
            }
        }
        const auto expected_failure = expanded.empty()
            ? reference_failure(module.properties.front(), trace)
            : std::any_of(expanded.begin(), expanded.end(), [&](const auto& alternative) {
                return reference_failure(alternative, trace);
            });
        const auto actual = solver.solve({}, assumptions);
        const bool actual_failure = constrain_as_assumption
            ? actual.status == q3a::sat::Status::Unsatisfiable
            : actual.status == q3a::sat::Status::Satisfiable;
        if (actual.status == q3a::sat::Status::Unknown ||
            actual_failure != expected_failure) {
            std::cerr << "Mismatch for " << module.properties.front().implication
                      << " trace=" << encoded << " expected_failure="
                      << expected_failure << " got="
                      << q3a::sat::status_name(actual.status) << '\n';
            return false;
        }
    }
    return true;
}

bool exhaustively_compare_cover(
    const TIRModule& module, std::uint64_t transition_count,
    const std::vector<TIRProperty>& expanded = {}) {
    Solver solver;
    q3a::sat::TransitionCnfEncoder encoder(solver, module);
    encoder.encode(transition_count);
    const auto query = encoder.add_cover_hit("c_sequence");
    solver.add_clause(query.hit_literals);

    std::vector<std::string> data_signals;
    for (const auto& signal_decl : module.signals) {
        if (signal_decl.name != "clk") data_signals.push_back(signal_decl.name);
    }
    const auto frame_count = static_cast<std::size_t>(transition_count + 1);
    const auto bit_count = frame_count * data_signals.size();
    const auto trace_count = std::uint64_t{1} << bit_count;
    for (std::uint64_t encoded = 0; encoded < trace_count; ++encoded) {
        std::vector<Sample> trace(frame_count);
        std::vector<Literal> assumptions;
        assumptions.reserve(bit_count);
        std::size_t position = 0;
        for (std::size_t frame = 0; frame < frame_count; ++frame) {
            for (const auto& name : data_signals) {
                const bool value = ((encoded >> position) & 1U) != 0;
                ++position;
                trace[frame][name] = value;
                const auto variable = encoder.frames()[frame].at(name).front();
                assumptions.push_back(value ? variable : static_cast<Literal>(-variable));
            }
        }
        const auto expected_cover = expanded.empty()
            ? reference_cover(module.properties.front(), trace)
            : std::any_of(expanded.begin(), expanded.end(), [&](const auto& alternative) {
                return reference_cover(alternative, trace);
            });
        const auto actual = solver.solve({}, assumptions);
        const bool actual_cover = actual.status == q3a::sat::Status::Satisfiable;
        if (actual.status == q3a::sat::Status::Unknown ||
            actual_cover != expected_cover) {
            std::cerr << "Cover mismatch for trace=" << encoded
                      << " expected=" << expected_cover << " got="
                      << q3a::sat::status_name(actual.status) << '\n';
            return false;
        }
    }
    return true;
}

bool check_activation_witness_reuse() {
    using q3a::sat::Status;
    const auto module = make_module(
        {"a"}, "overlapped", {{"a", 0, 1, 1}}, {{"a", 0, 1, 1}});
    std::size_t memory_checks = 0;
    Solver solver([&](std::uint64_t) { ++memory_checks; });
    q3a::sat::TransitionCnfEncoder encoder(solver, module);
    encoder.encode(0);
    const auto query = encoder.add_assertion_violation(module.properties.front().name);
    const auto a = encoder.frames()[0].at("a").front();
    const auto active = solver.solve({}, {a});
    const auto inactive = solver.solve({}, {-a});
    const auto before_activity = memory_checks;
    if (active.status != Status::Satisfiable || inactive.status != Status::Satisfiable ||
        encoder.assertion_activity(query, active.assignment) != Status::Satisfiable ||
        memory_checks != before_activity) {
        std::cerr << "An active feasibility model should avoid an additional SAT solve.\n";
        return false;
    }
    if (encoder.assertion_activity(query, inactive.assignment) != Status::Satisfiable ||
        memory_checks == before_activity) {
        std::cerr << "An inactive witness needs a separate activation query.\n";
        return false;
    }
    solver.add_clause({-a});
    if (encoder.assertion_activity(query, inactive.assignment) != Status::Unsatisfiable) {
        std::cerr << "A model that forbids the antecedent must be vacuous.\n";
        return false;
    }
    return true;
}

bool check_incomplete_antecedent_horizon() {
    const auto long_antecedent = make_module(
        {"a", "b"}, "overlapped", {{"a", 0}, {"b", 2}}, {{"b", 0}});
    Solver solver;
    q3a::sat::TransitionCnfEncoder encoder(solver, long_antecedent);
    encoder.encode(0);
    const auto long_query = encoder.add_assertion_violation(
        long_antecedent.properties.front().name);
    if (!encoder.boundary_incomplete(long_query) ||
        !long_query.violation_literals.empty()) {
        std::cerr << "An unfinished antecedent must flag the query boundary.\n";
        return false;
    }

    auto short_assertion = make_module(
        {"a", "b"}, "overlapped", {{"a", 0}}, {{"a", 0}});
    auto assumption = long_antecedent.properties.front();
    assumption.name = "long_assumption";
    assumption.kind = "assume";
    short_assertion.properties.push_back(std::move(assumption));
    Solver assumed_solver;
    q3a::sat::TransitionCnfEncoder assumed_encoder(assumed_solver, short_assertion);
    assumed_encoder.encode(0);
    assumed_encoder.constrain_assumptions();
    const auto short_query = assumed_encoder.add_assertion_violation(
        short_assertion.properties.front().name);
    if (short_query.boundary_incomplete || !assumed_encoder.boundary_incomplete(short_query)) {
        std::cerr << "An unfinished assumption must flag a complete assertion's run boundary.\n";
        return false;
    }
    return true;
}

bool induction_step_keeps_history_state_unconstrained() {
    TIRModule module;
    module.clocks.push_back("clk");
    module.signals.push_back(TIRSignal{"clk", 1, false, "input", {}});
    module.signals.push_back(TIRSignal{"history_valid", 1, false, "history_valid", {}});
    module.history_guards.push_back(
        {"clk", 1, "history_valid", {"history_valid"}});
    q3a::lowering::TIREquation transition;
    transition.target = "history_valid";
    transition.target_width = 1;
    transition.expression = signal("history_valid");
    module.next_state_equations.push_back(transition);

    Solver step_solver;
    q3a::sat::TransitionCnfEncoder step_encoder(step_solver, module);
    step_encoder.encode(1, false);
    step_solver.add_clause({step_encoder.frames()[0].at("history_valid").front()});
    if (step_solver.solve().status != q3a::sat::Status::Satisfiable) {
        std::cerr << "Induction step incorrectly constrained initial history-valid state to false.\n";
        return false;
    }

    Solver base_solver;
    q3a::sat::TransitionCnfEncoder base_encoder(base_solver, module);
    base_encoder.encode(1);
    base_solver.add_clause({base_encoder.frames()[0].at("history_valid").front()});
    if (base_solver.solve().status != q3a::sat::Status::Unsatisfiable) {
        std::cerr << "Base encoding did not enforce the initial history-valid reset.\n";
        return false;
    }
    return true;
}

} // namespace

int main() {
    if (!check_activation_witness_reuse()) return 1;
    if (!check_incomplete_antecedent_horizon()) return 1;
    if (!induction_step_keeps_history_state_unconstrained()) return 1;

    const auto overlapped = make_module(
        {"a", "b", "c"}, "overlapped",
        {{"a", 0, 1, 1}, {"b", 1, 1, 1}},
        {{"c", 0, 1, 1}});
    if (!exhaustively_compare(overlapped, 2)) return 1;

    const auto nonoverlapped = make_module(
        {"a", "b"}, "nonoverlapped",
        {{"a", 0, 1, 1}}, {{"b", 0, 1, 1}});
    if (!exhaustively_compare(nonoverlapped, 2)) return 1;

    const auto bounded_repeat = make_module(
        {"a", "b"}, "nonoverlapped",
        {{"a", 0, 1, 2}}, {{"b", 0, 1, 1}});
    if (!exhaustively_compare(bounded_repeat, 3)) return 1;

    const auto scalar_cover = make_cover_module({"a"}, {{"a", 0, 1, 1}});
    if (!exhaustively_compare_cover(scalar_cover, 1)) return 1;

    const auto sequence_cover = make_cover_module(
        {"a", "b"}, {{"a", 0, 1, 1}, {"b", 1, 1, 1}});
    if (!exhaustively_compare_cover(sequence_cover, 2)) return 1;

    const auto repeated_cover = make_cover_module(
        {"a", "b"}, {{"a", 0, 1, 2}, {"b", 1, 1, 1}});
    if (!exhaustively_compare_cover(repeated_cover, 3)) return 1;

    const auto overlapped_implication_cover = make_implication_cover_module(
        {"a", "b"}, "overlapped", {{"a", 0, 1, 2}}, {{"b", 0, 1, 1}});
    if (!exhaustively_compare_cover(overlapped_implication_cover, 2)) return 1;

    const auto nonoverlapped_implication_cover = make_implication_cover_module(
        {"a", "b", "c"}, "nonoverlapped",
        {{"a", 0, 1, 1}, {"b", 1, 1, 1}}, {{"c", 0, 1, 1}});
    if (!exhaustively_compare_cover(nonoverlapped_implication_cover, 2)) return 1;

    const auto same_sample_partial_consequent = make_implication_cover_module(
        {"a", "b"}, "overlapped", {{"a", 0, 1, 1}}, {{"b", 0, 1, 2}});
    if (!exhaustively_compare_cover(same_sample_partial_consequent, 0)) return 1;
    const auto next_sample_partial_consequent = make_implication_cover_module(
        {"a", "b"}, "nonoverlapped", {{"a", 0, 1, 1}}, {{"b", 0, 1, 2}});
    if (!exhaustively_compare_cover(next_sample_partial_consequent, 1)) return 1;
    const auto no_completed_consequent = make_implication_cover_module(
        {"a", "b"}, "nonoverlapped", {{"a", 0, 1, 1}}, {{"b", 0, 2, 3}});
    if (!exhaustively_compare_cover(no_completed_consequent, 1)) return 1;

    const std::vector<TermSpec> converging{{"a", 0, 1, 2}, {"b", 1, 1, 2}};
    auto chained = converging;
    chained.push_back({"a", 1, 1, 1});
    if (!exhaustively_compare_cover(make_cover_module({"a", "b"}, chained), 3)) return 1;
    const auto converging_assertion = make_module(
        {"a", "b"}, "nonoverlapped", converging, {{"a", 0, 1, 1}});
    if (!exhaustively_compare(converging_assertion, 3)) return 1;

    auto compound = make_module({"a", "b", "c"}, "nonoverlapped",
        {{"a", 0}, {"b", 0}}, {{"c", 0}});
    auto first = compound.properties.front();
    auto second = first;
    second.antecedent = sequence({{"a", 0}, {"b", 0}, {"a", 1}, {"b", 0}});
    compound.properties.front().antecedent =
        alternative_sequences(first.antecedent, second.antecedent);
    if (!exhaustively_compare(compound, 2, {first, second})) return 1;
    compound.properties.front().kind = "assume";
    if (!exhaustively_compare(compound, 2, {first, second}, true)) return 1;
    compound.properties.front().kind = "cover";
    compound.properties.front().name = "c_sequence";
    if (!exhaustively_compare_cover(compound, 2, {first, second})) return 1;

    std::cout << "PASS: 1536 branched assertion, assumption and cover CNF queries match independently expanded linear semantics.\n";
    std::cout << "PASS: CNF implication queries and scalar/sequence/implication cover goals match independent trace evaluators for all tested finite valuations.\n";
    return 0;
}
