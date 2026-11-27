#include "../source/replay/property_replay.hpp"

#include <array>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace {

q3a::lowering::TypedExpression signal(const std::string& name) {
    q3a::lowering::TypedExpression expression;
    expression.kind = "signal";
    expression.value = name;
    expression.width = 1;
    return expression;
}

q3a::lowering::TIRProperty property(
    const std::string& name,
    const std::string& kind,
    const std::string& signal_name) {
    q3a::lowering::TIRSequenceTransition transition;
    transition.source_state = 0;
    transition.target_state = 1;
    transition.predicate = signal(signal_name);

    q3a::lowering::TIRProperty result;
    result.name = name;
    result.kind = kind;
    result.clock = "clk";
    result.implication = "sequence";
    result.antecedent.automaton.state_count = 2;
    result.antecedent.automaton.start_state = 0;
    result.antecedent.automaton.accepting_state = 1;
    q3a::lowering::TIRSequenceTerm term;
    term.predicate = transition.predicate;
    result.antecedent.terms.push_back(term);
    result.antecedent.automaton.transitions.push_back(transition);
    return result;
}

q3a::lowering::TIREquation make_equation(
    const std::string& target,
    const q3a::lowering::TypedExpression& expression) {
    q3a::lowering::TIREquation result;
    result.target = target;
    result.target_width = expression.width;
    result.expression = expression;
    return result;
}

void require(bool condition, const std::string& message) {
    if (!condition) throw std::runtime_error(message);
}

void check_bounded_temporal_tail() {
    using q3a::lowering::TIRModule;
    using q3a::replay::Frame;
    TIRModule module;
    auto assertion = property("p_delayed", "assert", "a");
    assertion.antecedent.terms.front().delay_from_previous = 1;
    assertion.antecedent.automaton.transitions.front().delay_cycles = 1;
    module.properties.push_back(assertion);
    const std::vector<Frame> trace{{{"a", 1}}, {{"a", 0}}};
    require(q3a::replay::validate_bounded_counterexample(module, trace, "p_delayed", 0).validated,
        "replay rejected a complete delayed assertion failure");
    require(!q3a::replay::validate_bounded_counterexample(module, trace, "p_delayed", 1).validated,
        "replay accepted an unfinished delayed assertion as a failure");

    auto assumption = property("env_far_future", "assume", "a");
    assumption.implication = "nonoverlapped";
    assumption.consequent = property("future", "assert", "a").antecedent;
    const auto max_delay = std::numeric_limits<std::uint64_t>::max();
    assumption.consequent->terms.front().delay_from_previous = max_delay;
    assumption.consequent->automaton.transitions.front().delay_cycles = max_delay;
    module.properties.push_back(assumption);
    const auto result = q3a::replay::validate_bounded_counterexample(module, trace, "p_delayed", 0);
    require(result.validated && result.boundary_incomplete,
        "replay rejected a completed failure under a far-future assumption: " + result.message);
    auto& consequent = *module.properties.back().consequent;
    consequent.terms.front().repeat_max = 2;
    consequent.automaton.transitions.front().repeat_max = 2;
    const auto overflow = q3a::replay::validate_bounded_counterexample(module, trace, "p_delayed", 0);
    require(!overflow.validated && overflow.message.find("offset overflows") != std::string::npos,
        "replay accepted a delay and repetition sum wider than 64 bits");
}

void check_repetition_prefix_replay() {
    using q3a::lowering::TIRModule;
    using q3a::replay::Frame;
    TIRModule module;
    auto cover = property("c_repeat", "cover", "a");
    constexpr std::uint64_t samples = 256;
    auto& term = cover.antecedent.terms.front();
    auto& transition = cover.antecedent.automaton.transitions.front();
    term.repeat_min = transition.repeat_min = samples;
    term.repeat_max = transition.repeat_max = samples + 1;
    module.properties.push_back(std::move(cover));
    std::vector<Frame> trace(samples, Frame{{"a", 1}});
    const auto completed = q3a::replay::validate_bounded_cover(module, trace, "c_repeat", samples - 1);
    require(completed.validated && completed.boundary_incomplete,
        "the 256-sample prefix did not cover while the longer length was pending");
    trace[samples / 2]["a"] = 0;
    require(!q3a::replay::validate_bounded_cover(module, trace, "c_repeat", samples - 1).validated,
        "replay accepted a prefix containing a false sample");
}

q3a::lowering::TypedExpression typed_signal(
    const std::string& name, std::uint64_t width, bool is_signed = false) {
    q3a::lowering::TypedExpression expression;
    expression.kind = "signal";
    expression.value = name;
    expression.width = width;
    expression.is_signed = is_signed;
    return expression;
}

void add_signal(q3a::lowering::TIRModule& module,
                const std::string& name,
                std::uint64_t width,
                bool is_signed,
                const std::string& role) {
    q3a::lowering::TIRSignal signal;
    signal.name = name;
    signal.width = width;
    signal.is_signed = is_signed;
    signal.role = role;
    module.signals.push_back(signal);
}

std::uint64_t sign_extend_for_test(std::uint64_t value,
                                   std::uint64_t source_width,
                                   std::uint64_t result_width,
                                   bool sign_extend) {
    const auto source_mask = (std::uint64_t{1} << source_width) - 1;
    const auto result_mask = (std::uint64_t{1} << result_width) - 1;
    value &= source_mask;
    if (sign_extend && source_width < result_width &&
        ((value >> (source_width - 1)) & 1U) != 0) {
        value |= ~source_mask;
    }
    return value & result_mask;
}

int signed_value_for_test(std::uint64_t value, std::uint64_t width) {
    const auto sign_bit = std::uint64_t{1} << (width - 1);
    return (value & sign_bit) != 0
        ? static_cast<int>(value) - static_cast<int>(std::uint64_t{1} << width)
        : static_cast<int>(value);
}

void check_arithmetic_replay() {
    using q3a::lowering::TIRModule;
    using q3a::lowering::TypedExpression;
    using q3a::replay::Frame;
    for (const bool lhs_signed : {false, true}) {
        for (const bool rhs_signed : {false, true}) {
            for (const auto* op : {"+", "-"}) {
                TIRModule module;
                module.clocks.push_back("clk");
                add_signal(module, "clk", 1, false, "input");
                add_signal(module, "lhs", 3, lhs_signed, "input");
                add_signal(module, "rhs", 2, rhs_signed, "input");
                add_signal(module, "result", 3, false, "output");
                add_signal(module, "fail", 1, false, "input");
                const auto lhs = typed_signal("lhs", 3, lhs_signed);
                const auto rhs = typed_signal("rhs", 2, rhs_signed);
                const bool sign_extend = lhs_signed && rhs_signed;
                const TypedExpression expression{"binary", op, 3,
                    sign_extend, {}, {lhs, rhs}};
                module.combinational_equations.push_back(
                    make_equation("result", expression));
                module.properties.push_back(property("p_fail", "assert", "fail"));

                for (std::uint64_t a = 0; a < 8; ++a) {
                    for (std::uint64_t b = 0; b < 4; ++b) {
                        const auto left = sign_extend_for_test(a, 3, 3, sign_extend);
                        const auto right = sign_extend_for_test(b, 2, 3, sign_extend);
                        const auto expected = (op[0] == '+' ? left + right
                                                            : left - right) & 7U;
                        const std::vector<Frame> trace{{
                            {"clk", 0}, {"lhs", a}, {"rhs", b},
                            {"result", expected}, {"fail", 0}}};
                        const auto replay = q3a::replay::validate_bounded_counterexample(
                            module, trace, "p_fail", 0);
                        require(replay.validated,
                            "arithmetic expression failed independent witness replay: " +
                            std::string(op) + ": " + replay.message);

                        auto mutated = trace;
                        mutated.front()["result"] ^= 1U;
                        const auto mutated_replay =
                            q3a::replay::validate_bounded_counterexample(
                                module, mutated, "p_fail", 0);
                        require(!mutated_replay.validated,
                            "replay accepted a one-bit arithmetic-result mutation: " +
                            std::string(op));
                    }
                }
            }
        }
    }
}

void check_unary_and_shift_replay() {
    using q3a::lowering::TIRModule;
    using q3a::lowering::TypedExpression;
    using q3a::replay::Frame;
    const auto location = q3a::frontend::SourceLocation{"replay_vectors.sv", 1, 1, 0};
    std::vector<std::pair<std::string, std::uint64_t>> cases;
    for (std::uint64_t amount = 0; amount <= 7; ++amount) {
        cases.emplace_back("<<", amount);
        cases.emplace_back(">>", amount);
    }

    for (const auto& [op, amount] : cases) {
        TIRModule module;
        module.clocks.push_back("clk");
        add_signal(module, "clk", 1, false, "input");
        add_signal(module, "value", 4, false, "input");
        add_signal(module, "result", 4, false, "output");
        add_signal(module, "fail", 1, false, "input");
        const auto value = typed_signal("value", 4);
        const TypedExpression rhs{"literal", "4'd" + std::to_string(amount),
            4, false, location, {}};
        const TypedExpression expression{"binary", op, 4, false,
            location, {value, rhs}};
        module.combinational_equations.push_back(make_equation("result", expression));
        module.properties.push_back(property("p_fail", "assert", "fail"));

        for (std::uint64_t input = 0; input < 16; ++input) {
            const auto expected = amount >= 4 ? 0
                : (op == "<<" ? ((input << amount) & 15U) : (input >> amount));
            const std::vector<Frame> trace{{
                {"clk", 0}, {"value", input}, {"result", expected}, {"fail", 0}}};
            const auto replay = q3a::replay::validate_bounded_counterexample(
                module, trace, "p_fail", 0);
            require(replay.validated,
                "unary/shift expression failed independent witness replay: " +
                op + ": " + replay.message);
        }
    }

    TIRModule unary_module;
    unary_module.clocks.push_back("clk");
    add_signal(unary_module, "clk", 1, false, "input");
    add_signal(unary_module, "value", 4, true, "input");
    add_signal(unary_module, "result", 4, true, "output");
    add_signal(unary_module, "fail", 1, false, "input");
    const TypedExpression unary{"unary", "-", 4, true, location,
        {typed_signal("value", 4, true)}};
    unary_module.combinational_equations.push_back(make_equation("result", unary));
    unary_module.properties.push_back(property("p_fail", "assert", "fail"));
    for (std::uint64_t input = 0; input < 16; ++input) {
        const std::vector<Frame> trace{{
            {"clk", 0}, {"value", input}, {"result", (0U - input) & 15U},
            {"fail", 0}}};
        const auto replay = q3a::replay::validate_bounded_counterexample(
            unary_module, trace, "p_fail", 0);
        require(replay.validated,
            "unary minus failed independent witness replay: " + replay.message);
    }

    for (const bool operand_signed : {false, true}) {
        for (const auto* op : {">>", ">>>"}) {
            for (std::uint64_t amount = 0; amount <= 7; ++amount) {
                TIRModule shift_module;
                shift_module.clocks.push_back("clk");
                add_signal(shift_module, "clk", 1, false, "input");
                add_signal(shift_module, "value", 4, operand_signed, "input");
                add_signal(shift_module, "result", 4, operand_signed, "output");
                add_signal(shift_module, "fail", 1, false, "input");
                const auto lhs = typed_signal("value", 4, operand_signed);
                const TypedExpression rhs{"literal", "3'd" + std::to_string(amount),
                    3, false, location, {}};
                shift_module.combinational_equations.push_back(make_equation(
                    "result", TypedExpression{"binary", op, 4, operand_signed,
                        location, {lhs, rhs}}));
                shift_module.properties.push_back(property("p_fail", "assert", "fail"));

                for (std::uint64_t input = 0; input < 16; ++input) {
                    const bool sign_fill = std::string(op) == ">>>" &&
                        operand_signed && ((input >> 3U) & 1U) != 0;
                    std::uint64_t expected = 0;
                    if (amount >= 4) {
                        expected = sign_fill ? 15U : 0U;
                    } else {
                        expected = input >> amount;
                        if (sign_fill && amount != 0) {
                            expected |= 15U & ~((std::uint64_t{1} << (4 - amount)) - 1U);
                        }
                    }
                    std::vector<Frame> trace{{{"clk", 0}, {"value", input},
                        {"result", expected}, {"fail", 0}}};
                    const auto replay = q3a::replay::validate_bounded_counterexample(
                        shift_module, trace, "p_fail", 0);
                    require(replay.validated,
                        "arithmetic-right-shift replay rejected oracle trace: " +
                        std::string(op) + ": " + replay.message);
                    trace.front()["result"] ^= 1U;
                    require(!q3a::replay::validate_bounded_counterexample(
                                shift_module, trace, "p_fail", 0).validated,
                        "replay accepted a corrupted arithmetic-right-shift result");
                }
            }
        }
    }
}

void check_width_extension_replay() {
    using q3a::lowering::TIRModule;
    using q3a::lowering::TypedExpression;
    using q3a::replay::Frame;
    for (const bool lhs_signed : {false, true}) {
        for (const bool rhs_signed : {false, true}) {
            const bool sign_extend = lhs_signed && rhs_signed;
            for (const auto* op : {"<", "<=", ">", ">=", "==", "!=",
                                   "&", "|", "^", "~^", "^~"}) {
                const bool predicate = std::string(op) == "<" ||
                    std::string(op) == "<=" || std::string(op) == ">" ||
                    std::string(op) == ">=" || std::string(op) == "==" ||
                    std::string(op) == "!=";
                TIRModule module;
                module.clocks.push_back("clk");
                add_signal(module, "clk", 1, false, "input");
                add_signal(module, "lhs", 3, lhs_signed, "input");
                add_signal(module, "rhs", 2, rhs_signed, "input");
                add_signal(module, "result", predicate ? 1 : 3, false, "output");
                add_signal(module, "fail", 1, false, "input");
                const TypedExpression left = typed_signal("lhs", 3, lhs_signed);
                const TypedExpression right = typed_signal("rhs", 2, rhs_signed);
                const TypedExpression expression{"binary", op,
                    predicate ? 1U : 3U, false, {}, {left, right}};
                module.combinational_equations.push_back(
                    make_equation("result", expression));
                module.properties.push_back(property("p_fail", "assert", "fail"));

                for (std::uint64_t lhs = 0; lhs < 8; ++lhs) {
                    for (std::uint64_t rhs = 0; rhs < 4; ++rhs) {
                        const auto extended_left = sign_extend_for_test(
                            lhs, 3, 3, sign_extend);
                        const auto extended_right = sign_extend_for_test(
                            rhs, 2, 3, sign_extend);
                        std::uint64_t expected = 0;
                        if (std::string(op) == "<") {
                            expected = sign_extend
                                ? signed_value_for_test(extended_left, 3) <
                                      signed_value_for_test(extended_right, 3)
                                : extended_left < extended_right;
                        } else if (std::string(op) == "<=") {
                            expected = sign_extend
                                ? signed_value_for_test(extended_left, 3) <=
                                      signed_value_for_test(extended_right, 3)
                                : extended_left <= extended_right;
                        } else if (std::string(op) == ">") {
                            expected = sign_extend
                                ? signed_value_for_test(extended_left, 3) >
                                      signed_value_for_test(extended_right, 3)
                                : extended_left > extended_right;
                        } else if (std::string(op) == ">=") {
                            expected = sign_extend
                                ? signed_value_for_test(extended_left, 3) >=
                                      signed_value_for_test(extended_right, 3)
                                : extended_left >= extended_right;
                        } else if (std::string(op) == "==") {
                            expected = extended_left == extended_right;
                        } else if (std::string(op) == "!=") {
                            expected = extended_left != extended_right;
                        } else if (std::string(op) == "&") {
                            expected = (extended_left & extended_right) & 7U;
                        } else if (std::string(op) == "|") {
                            expected = (extended_left | extended_right) & 7U;
                        } else if (std::string(op) == "^") {
                            expected = (extended_left ^ extended_right) & 7U;
                        } else {
                            expected = (~(extended_left ^ extended_right)) & 7U;
                        }
                        const std::vector<Frame> trace{{
                            {"clk", 0}, {"lhs", lhs}, {"rhs", rhs},
                            {"result", expected}, {"fail", 0}}};
                        const auto replay = q3a::replay::validate_bounded_counterexample(
                            module, trace, "p_fail", 0);
                        require(replay.validated,
                            "mixed-width expression failed replay: " + std::string(op) +
                            ": " + replay.message);
                    }
                }
            }
        }
    }
}

void check_conditional_extension_replay() {
    using q3a::lowering::TIRModule;
    using q3a::lowering::TypedExpression;
    using q3a::replay::Frame;
    for (const bool true_signed : {false, true}) {
        for (const bool false_signed : {false, true}) {
            const bool sign_extend = true_signed && false_signed;
            TIRModule module;
            module.clocks.push_back("clk");
            add_signal(module, "clk", 1, false, "input");
            add_signal(module, "condition", 1, false, "input");
            add_signal(module, "when_true", 3, true_signed, "input");
            add_signal(module, "when_false", 2, false_signed, "input");
            add_signal(module, "result", 3, false, "output");
            add_signal(module, "fail", 1, false, "input");
            const TypedExpression expression{"conditional", "?:", 3,
                sign_extend, {}, {typed_signal("condition", 1),
                    typed_signal("when_true", 3, true_signed),
                    typed_signal("when_false", 2, false_signed)}};
            module.combinational_equations.push_back(
                make_equation("result", expression));
            module.properties.push_back(property("p_fail", "assert", "fail"));

            for (std::uint64_t condition = 0; condition < 2; ++condition) {
                for (std::uint64_t when_true = 0; when_true < 8; ++when_true) {
                    for (std::uint64_t when_false = 0; when_false < 4; ++when_false) {
                        const auto selected = condition != 0
                            ? sign_extend_for_test(when_true, 3, 3, sign_extend)
                            : sign_extend_for_test(when_false, 2, 3, sign_extend);
                        const std::vector<Frame> trace{{
                            {"clk", 0}, {"condition", condition},
                            {"when_true", when_true}, {"when_false", when_false},
                            {"result", selected}, {"fail", 0}}};
                        const auto replay = q3a::replay::validate_bounded_counterexample(
                            module, trace, "p_fail", 0);
                        require(replay.validated,
                            "mixed-width conditional failed replay: " + replay.message);
                    }
                }
            }
        }
    }
}

void check_implication_cover_replay() {
    using q3a::lowering::TIRModule;
    using q3a::lowering::TIRSequence;
    using q3a::lowering::TIRSequenceTransition;
    using q3a::replay::Frame;

    TIRModule module;
    module.clocks.push_back("clk");
    add_signal(module, "clk", 1, false, "input");
    add_signal(module, "req", 1, false, "input");
    add_signal(module, "ack", 1, false, "input");
    add_signal(module, "done", 1, false, "input");

    const auto single_term = [](const std::string& signal_name) {
        TIRSequence sequence;
        sequence.automaton.state_count = 2;
        sequence.automaton.start_state = 0;
        sequence.automaton.accepting_state = 1;
        const auto predicate = signal(signal_name);
        sequence.terms.push_back({0, 1, 1, predicate, {}});
        sequence.automaton.transitions.push_back(TIRSequenceTransition{
            0, 1, 0, 1, 1, predicate, {}});
        return sequence;
    };
    auto overlapped = property("c_overlap", "cover", "req");
    overlapped.implication = "overlapped";
    overlapped.consequent = single_term("ack");
    module.properties.push_back(overlapped);

    const std::vector<Frame> matching_overlap{
        {{"clk", 0}, {"req", 1}, {"ack", 1}, {"done", 0}}};
    const auto same_sample = q3a::replay::validate_bounded_cover(
        module, matching_overlap, "c_overlap", 0);
    require(same_sample.validated && !same_sample.boundary_incomplete,
        "same-sample cover should replay with a complete boundary");
    for (const auto* name : {"req", "ack"}) {
        auto mutated = matching_overlap;
        mutated.front()[name] ^= 1U;
        require(!q3a::replay::validate_bounded_cover(
                    module, mutated, "c_overlap", 0).validated,
            "replay accepted an overlapped-cover witness mutation of " +
            std::string(name));
    }
    const std::vector<Frame> antecedent_without_consequent{
        {{"clk", 0}, {"req", 1}, {"ack", 0}, {"done", 0}}};
    require(!q3a::replay::validate_bounded_cover(
        module, antecedent_without_consequent, "c_overlap", 0).validated,
        "replay accepted an antecedent-only implication cover trace");
    const std::vector<Frame> vacuous_trace{
        {{"clk", 0}, {"req", 0}, {"ack", 1}, {"done", 0}}};
    require(!q3a::replay::validate_bounded_cover(
        module, vacuous_trace, "c_overlap", 0).validated,
        "replay accepted a vacuous implication as a nonvacuous cover witness");

    auto nonoverlapped = overlapped;
    nonoverlapped.name = "c_nonoverlap";
    nonoverlapped.implication = "nonoverlapped";
    module.properties.push_back(nonoverlapped);
    const std::vector<Frame> matching_nonoverlap{
        {{"clk", 0}, {"req", 1}, {"ack", 0}, {"done", 0}},
        {{"clk", 0}, {"req", 0}, {"ack", 1}, {"done", 0}}};
    const auto next_sample = q3a::replay::validate_bounded_cover(
        module, matching_nonoverlap, "c_nonoverlap", 1);
    require(next_sample.validated && next_sample.boundary_incomplete,
        "next-sample cover should replay with an unfinished final-frame start");

    auto pending_long_match = nonoverlapped;
    pending_long_match.name = "c_partial_consequent";
    pending_long_match.consequent->terms.front().repeat_max = 2;
    pending_long_match.consequent->automaton.transitions.front().repeat_max = 2;
    module.properties.push_back(pending_long_match);
    const auto short_match = q3a::replay::validate_bounded_cover(
        module, matching_nonoverlap, pending_long_match.name, 1);
    require(short_match.validated && short_match.boundary_incomplete,
        "a completed short match must replay while the longer match remains pending");
    require(!q3a::replay::validate_bounded_cover(
        module, matching_nonoverlap, pending_long_match.name, 0).validated,
        "replay accepted the antecedent frame as the consequent match");
    auto& only_longer_matches = *module.properties.back().consequent;
    only_longer_matches.terms.front().repeat_min = 2;
    only_longer_matches.automaton.transitions.front().repeat_min = 2;
    require(!q3a::replay::validate_bounded_cover(
        module, matching_nonoverlap, pending_long_match.name, 1).validated,
        "replay accepted a partial consequent that did not reach the minimum count");

    auto with_later_assumption = module;
    auto later_assumption = nonoverlapped;
    later_assumption.name = "env_later";
    later_assumption.kind = "assume";
    with_later_assumption.properties.push_back(std::move(later_assumption));
    const auto assumed_boundary = q3a::replay::validate_bounded_cover(
        with_later_assumption, matching_overlap, "c_overlap", 0);
    require(assumed_boundary.validated && assumed_boundary.boundary_incomplete,
        "a next-cycle assumption should mark the boundary of a same-sample cover");
    for (const auto& mutation : {
             std::pair<std::size_t, const char*>{0, "req"},
             {1, "ack"}}) {
        auto mutated = matching_nonoverlap;
        mutated[mutation.first][mutation.second] ^= 1U;
        require(!q3a::replay::validate_bounded_cover(
                    module, mutated, "c_nonoverlap", 1).validated,
            "replay accepted a non-overlapped-cover witness mutation of " +
            std::string(mutation.second) + " at frame " +
            std::to_string(mutation.first));
    }

    auto delayed_antecedent = property("c_delayed_antecedent", "cover", "req");
    delayed_antecedent.implication = "overlapped";
    delayed_antecedent.antecedent.automaton.state_count = 3;
    delayed_antecedent.antecedent.automaton.accepting_state = 2;
    const auto ack_predicate = signal("ack");
    delayed_antecedent.antecedent.terms.push_back(
        q3a::lowering::TIRSequenceTerm{1, 1, 1, ack_predicate, {}});
    delayed_antecedent.antecedent.automaton.transitions.push_back(
        TIRSequenceTransition{1, 2, 1, 1, 1, ack_predicate, {}});
    delayed_antecedent.consequent = single_term("done");
    module.properties.push_back(delayed_antecedent);
    const std::vector<Frame> matching_delayed_antecedent{
        {{"clk", 0}, {"req", 1}, {"ack", 0}, {"done", 0}},
        {{"clk", 0}, {"req", 0}, {"ack", 1}, {"done", 1}}};
    require(q3a::replay::validate_bounded_cover(
        module, matching_delayed_antecedent, "c_delayed_antecedent", 1).validated,
        "replay rejected a delayed antecedent implication-cover witness");
    const std::vector<Frame> consequent_one_cycle_late{
        matching_delayed_antecedent[0],
        {{"clk", 0}, {"req", 0}, {"ack", 1}, {"done", 0}},
        {{"clk", 0}, {"req", 0}, {"ack", 0}, {"done", 1}}};
    require(!q3a::replay::validate_bounded_cover(
        module, consequent_one_cycle_late, "c_delayed_antecedent", 2).validated,
        "replay treated a next-frame consequent as an overlapped cover match");
    for (const auto& mutation : {
             std::pair<std::size_t, const char*>{0, "req"},
             {1, "ack"},
             {1, "done"}}) {
        auto mutated = matching_delayed_antecedent;
        mutated[mutation.first][mutation.second] ^= 1U;
        require(!q3a::replay::validate_bounded_cover(
                    module, mutated, "c_delayed_antecedent", 1).validated,
            "replay accepted a delayed-sequence cover mutation of " +
            std::string(mutation.second) + " at frame " +
            std::to_string(mutation.first));
    }

    auto delayed_nonoverlapped = delayed_antecedent;
    delayed_nonoverlapped.name = "c_delayed_nonoverlapped";
    delayed_nonoverlapped.implication = "nonoverlapped";
    module.properties.push_back(delayed_nonoverlapped);
    const std::vector<Frame> matching_delayed_nonoverlap{
        {{"clk", 0}, {"req", 1}, {"ack", 0}, {"done", 0}},
        {{"clk", 0}, {"req", 0}, {"ack", 1}, {"done", 0}},
        {{"clk", 0}, {"req", 0}, {"ack", 0}, {"done", 1}}};
    require(q3a::replay::validate_bounded_cover(
        module, matching_delayed_nonoverlap,
        "c_delayed_nonoverlapped", 2).validated,
        "replay rejected a delayed |=> implication-cover witness");
    auto consequent_on_antecedent_end = matching_delayed_nonoverlap;
    consequent_on_antecedent_end[1]["done"] = 1;
    consequent_on_antecedent_end[2]["done"] = 0;
    require(!q3a::replay::validate_bounded_cover(
        module, consequent_on_antecedent_end,
        "c_delayed_nonoverlapped", 2).validated,
        "replay treated the antecedent-end sample as a non-overlapped consequent match");
    for (const auto& mutation : {
             std::pair<std::size_t, const char*>{0, "req"},
             {1, "ack"},
             {2, "done"}}) {
        auto mutated = matching_delayed_nonoverlap;
        mutated[mutation.first][mutation.second] ^= 1U;
        require(!q3a::replay::validate_bounded_cover(
                    module, mutated, "c_delayed_nonoverlapped", 2).validated,
            "replay accepted a delayed |=> cover mutation of " +
            std::string(mutation.second) + " at frame " +
            std::to_string(mutation.first));
    }

    // Drive independent guard bits to exhaust their alignment with sequence
    // starts. Source-level tests separately check actual history equations.
    add_signal(module, "antecedent_valid", 1, false, "input");
    add_signal(module, "consequent_valid", 1, false, "input");
    module.properties.clear();
    auto ranged = nonoverlapped;
    ranged.split_history_guards = true;
    ranged.antecedent_history_guard_signal = "antecedent_valid";
    ranged.consequent_history_guard_signal = "consequent_valid";
    ranged.antecedent.terms[0].repeat_max = 2;
    ranged.antecedent.automaton.transitions[0].repeat_max = 2;
    ranged.consequent->terms[0].repeat_max = 2;
    ranged.consequent->automaton.transitions[0].repeat_max = 2;
    constexpr std::size_t samples = 3;
    for (std::size_t delta = 0; delta <= 1; ++delta) {
        ranged.implication = delta ? "nonoverlapped" : "overlapped";
        ranged.kind = "cover";
        ranged.name = "ranged_cover";
        auto assertion = ranged;
        assertion.kind = "assert";
        assertion.name = "ranged_assertion";
        module.properties = {ranged, assertion};
        for (unsigned bits = 0; bits < (1U << (4 * samples)); ++bits) {
            std::vector<Frame> trace(samples);
            for (std::size_t sample = 0; sample < samples; ++sample) {
                const auto values = bits >> (4 * sample);
                trace[sample] = {{"clk", 0}, {"done", 0}, {"req", values & 1U},
                    {"ack", (values >> 1) & 1U}, {"antecedent_valid", (values >> 2) & 1U},
                    {"consequent_valid", (values >> 3) & 1U}};
            }
            std::array<bool, samples> expected_hits{};
            std::array<bool, samples> expected_failures{};
            for (std::size_t start = 0; start < samples; ++start) {
                if (!trace[start].at("antecedent_valid") || !trace[start].at("req")) continue;
                for (std::size_t extra = 0; extra <= 1 && start + extra < samples; ++extra) {
                    if (!trace[start + extra].at("req")) break;
                    const auto target = start + extra + delta;
                    if (target >= samples || !trace[target].at("consequent_valid")) continue;
                    if (trace[target].at("ack")) {
                        expected_hits[target] = true;
                        if (target + 1 < samples && trace[target + 1].at("ack")) {
                            expected_hits[target + 1] = true;
                        }
                    } else if (target + 1 < samples) {
                        expected_failures[target] = true;
                    }
                }
            }
            for (std::size_t candidate = 0; candidate < samples; ++candidate) {
                require(q3a::replay::validate_bounded_cover(
                            module, trace, ranged.name, candidate).validated ==
                            expected_hits[candidate],
                        "bounded cover replay disagrees with the ranged guarded oracle");
                require(q3a::replay::validate_bounded_counterexample(
                            module, trace, assertion.name, candidate).validated ==
                            expected_failures[candidate],
                        "bounded assertion replay disagrees with the ranged guarded oracle");
            }
        }
    }
}

void check_branched_repeat_replay() {
    using q3a::lowering::TIRModule;
    using q3a::lowering::TIRSequence;
    using q3a::replay::Frame;
    TIRModule module;
    module.clocks = {"clk"};
    for (const auto* name : {"clk", "start", "a", "b", "ok"}) {
        add_signal(module, name, 1, false, "input");
    }

    // start ##0 (a ##0 b)[*1:2]. Both paths share only their start and end.
    TIRSequence sequence;
    sequence.automaton = {8, 0, 7, {}};
    const auto edge = [&](std::uint64_t from, std::uint64_t to,
                          std::uint64_t delay, const char* name) {
        auto predicate = signal(name);
        sequence.terms.push_back({delay, 1, 1, predicate, {}});
        sequence.automaton.transitions.push_back({from, to, delay, 1, 1, predicate, {}});
    };
    edge(0, 1, 0, "start");
    edge(1, 2, 0, "a");
    edge(2, 7, 0, "b");
    edge(0, 3, 0, "start");
    edge(3, 4, 0, "a");
    edge(4, 5, 0, "b");
    edge(5, 6, 1, "a");
    edge(6, 7, 0, "b");

    auto cover = property("c_branch", "cover", "a");
    cover.antecedent = sequence;
    auto target = property("p_branch", "assert", "a");
    target.implication = "overlapped";
    target.antecedent = sequence;
    target.consequent = property("rhs", "assert", "ok").antecedent;
    module.properties = {cover, target};
    auto assumed = module;
    target.kind = "assume";
    assumed.properties.back() = target;

    for (unsigned bits = 0; bits < 64; ++bits) {
        const std::vector<Frame> trace{
            {{"clk", 0}, {"start", 1}, {"a", bits & 1U}, {"b", (bits >> 1) & 1U},
             {"ok", (bits >> 2) & 1U}},
            {{"clk", 0}, {"start", 0}, {"a", (bits >> 3) & 1U},
             {"b", (bits >> 4) & 1U}, {"ok", (bits >> 5) & 1U}}
        };
        const bool short_match = (bits & 3U) == 3U;
        const bool long_match = short_match && (bits & 24U) == 24U;
        const std::array<bool, 2> matches{short_match, long_match};
        const bool assumptions_hold =
            (!short_match || (bits & 4U) != 0) && (!long_match || (bits & 32U) != 0);
        for (std::size_t frame = 0; frame < trace.size(); ++frame) {
            require(q3a::replay::validate_bounded_cover(
                        module, trace, cover.name, frame).validated == matches[frame],
                "ranged compound cover replay disagrees with the direct truth table");
            require(q3a::replay::validate_bounded_counterexample(
                        module, trace, target.name, frame).validated ==
                        (matches[frame] && trace[frame].at("ok") == 0),
                "compound assertion failed to check a matching alternative");
            require(q3a::replay::validate_bounded_cover(
                        assumed, trace, cover.name, frame).validated ==
                        (matches[frame] && assumptions_hold),
                "compound assumption did not constrain every matching alternative");
        }
    }

    const std::vector<Frame> trace{
        {{"clk", 0}, {"start", 1}, {"a", 1}, {"b", 1}, {"ok", 1}},
        {{"clk", 0}, {"start", 0}, {"a", 1}, {"b", 1}, {"ok", 0}}
    };
    auto extra = trace;
    extra.back()["unknown"] = 1;
    require(!q3a::replay::validate_bounded_cover(module, extra, cover.name, 1).validated,
        "replay accepted a frame with data outside the transition model");
    module.properties.front().antecedent.automaton.transitions.back().target_state = 5;
    require(!q3a::replay::validate_bounded_cover(module, trace, cover.name, 0).validated,
        "replay accepted a malformed alternative beside a valid short path");
    std::cout << "PASS: 384 independent branched cover, assertion and assumption replay verdicts.\n";
}

void check_frame_by_frame_mutation_replay() {
    using q3a::lowering::TIRModule;
    using q3a::lowering::TypedExpression;
    using q3a::replay::Frame;

    TIRModule module;
    module.clocks.push_back("clk");
    add_signal(module, "clk", 1, false, "input");
    add_signal(module, "a", 1, false, "input");
    add_signal(module, "q", 1, false, "state");
    add_signal(module, "y", 1, false, "output");
    const auto relation = TypedExpression{"binary", "^", 1, false, {},
        {signal("a"), signal("q")}};
    module.combinational_equations.push_back(make_equation("y", relation));
    module.next_state_equations.push_back(make_equation("q", signal("y")));
    module.properties.push_back(property("a_is_high", "assume", "a"));

    auto assertion = property("p_not_y", "assert", "y");
    const auto inverted_y = TypedExpression{"unary", "!", 1, false, {},
        {signal("y")}};
    assertion.antecedent.terms.front().predicate = inverted_y;
    assertion.antecedent.automaton.transitions.front().predicate = inverted_y;
    module.properties.push_back(assertion);

    const std::vector<Frame> trace{
        {{"clk", 0}, {"a", 1}, {"q", 0}, {"y", 1}},
        {{"clk", 0}, {"a", 1}, {"q", 1}, {"y", 0}}
    };
    const auto valid = q3a::replay::validate_bounded_counterexample(
        module, trace, "p_not_y", 0);
    require(valid.validated,
        "replay rejected the baseline two-frame counterexample: " + valid.message);

    for (std::size_t frame = 0; frame < trace.size(); ++frame) {
        for (const auto* signal_name : {"a", "q", "y"}) {
            auto mutated = trace;
            mutated[frame][signal_name] ^= 1U;
            const auto replay = q3a::replay::validate_bounded_counterexample(
                module, mutated, "p_not_y", 0);
            require(!replay.validated,
                "replay accepted a one-bit mutation of signal '" +
                std::string(signal_name) + "' at frame " +
                std::to_string(frame));
        }
    }
}

} // namespace

int main() {
    q3a::lowering::TIRModule module;
    module.clocks.push_back("clk");
    for (const auto& name : {"clk", "a", "b"}) {
        q3a::lowering::TIRSignal input;
        input.name = name;
        input.width = 1;
        input.role = "input";
        module.signals.push_back(input);
    }
    q3a::lowering::TIRSignal output;
    output.name = "y";
    output.width = 1;
    output.role = "output";
    module.signals.push_back(output);

    q3a::lowering::TIREquation equation;
    equation.target = "y";
    equation.target_width = 1;
    equation.expression = signal("a");
    module.combinational_equations.push_back(equation);

    module.properties.push_back(property("p_env", "assume", "a"));
    module.properties.push_back(property("p_fail", "assert", "b"));
    module.properties.push_back(property("c_hit", "cover", "b"));

    using q3a::replay::Frame;
    std::vector<Frame> valid_trace{
        {{"clk", 0}, {"a", 1}, {"b", 0}, {"y", 1}},
        {{"clk", 0}, {"a", 1}, {"b", 0}, {"y", 1}}
    };
    require(q3a::replay::validate_bounded_counterexample(
        module, valid_trace, "p_fail", 0).validated,
        "valid bounded counterexample was rejected");

    auto equation_mismatch = valid_trace;
    equation_mismatch[0]["y"] = 0;
    const auto equation_result = q3a::replay::validate_bounded_counterexample(
        module, equation_mismatch, "p_fail", 0);
    require(!equation_result.validated &&
        equation_result.message.find("combinational equation replay mismatch") != std::string::npos,
        "replay accepted a trace that violates a combinational equation");

    auto wrong_candidate = valid_trace;
    wrong_candidate[1]["b"] = 1;
    const auto candidate_result = q3a::replay::validate_bounded_counterexample(
        module, wrong_candidate, "p_fail", 1);
    require(!candidate_result.validated,
        "replay accepted a candidate frame where the assertion holds");

    auto assumption_mismatch = valid_trace;
    assumption_mismatch[0]["a"] = 0;
    assumption_mismatch[0]["y"] = 0;
    const auto assumption_result = q3a::replay::validate_bounded_counterexample(
        module, assumption_mismatch, "p_fail", 0);
    require(!assumption_result.validated &&
        assumption_result.message.find("violates bounded sequence assumption") != std::string::npos,
        "replay accepted a trace that violates an environment assumption");

    auto cover_trace = valid_trace;
    cover_trace[0]["b"] = 1;
    require(q3a::replay::validate_bounded_cover(
        module, cover_trace, "c_hit", 0).validated,
        "valid bounded cover witness was rejected");
    const auto missed_cover = q3a::replay::validate_bounded_cover(
        module, valid_trace, "c_hit", 0);
    require(!missed_cover.validated,
        "replay accepted a trace that does not reach the cover goal");

    q3a::lowering::TIRModule past_module;
    past_module.clocks.push_back("clk");
    for (const auto& name : {"clk", "a"}) {
        q3a::lowering::TIRSignal input;
        input.name = name;
        input.width = 1;
        input.role = "input";
        past_module.signals.push_back(input);
    }
    for (const auto& entry : {
             std::pair<const char*, const char*>{"history_valid", "history_valid"},
             {"past_a", "history_data"}}) {
        q3a::lowering::TIRSignal state;
        state.name = entry.first;
        state.width = 1;
        state.role = entry.second;
        past_module.signals.push_back(state);
    }
    q3a::lowering::TypedExpression one;
    one.kind = "literal";
    one.value = "'1";
    one.width = 1;
    past_module.next_state_equations.push_back(make_equation("history_valid", one));
    past_module.next_state_equations.push_back(make_equation("past_a", signal("a")));
    past_module.history_guards.push_back({"clk", 1, "history_valid", {"history_valid"}});
    auto past_property = property("p_past_a", "assert", "past_a");
    past_property.history_guard_signal = "history_valid";
    past_module.properties.push_back(past_property);

    const std::vector<Frame> base_countermodel{
        {{"clk", 0}, {"a", 0}, {"history_valid", 0}, {"past_a", 0}},
        {{"clk", 0}, {"a", 1}, {"history_valid", 1}, {"past_a", 0}}
    };
    const auto base_replay = q3a::replay::validate_induction_countermodel(
        past_module, base_countermodel, "p_past_a", 2,
        q3a::replay::InductionObligation::Base);
    require(base_replay.validated && base_replay.failure_frame == 1,
        "base countermodel replay did not validate the first reachable guarded-past failure");

    const std::vector<Frame> step_countermodel{
        {{"clk", 0}, {"a", 0}, {"history_valid", 1}, {"past_a", 1}},
        {{"clk", 0}, {"a", 0}, {"history_valid", 1}, {"past_a", 0}}
    };
    const auto step_replay = q3a::replay::validate_induction_countermodel(
        past_module, step_countermodel, "p_past_a", 1,
        q3a::replay::InductionObligation::Step);
    require(step_replay.validated && step_replay.failure_frame == 1,
        "step replay must accept arbitrary valid history state when the k-step property fails");

    const auto initial_history_in_base = q3a::replay::validate_induction_countermodel(
        past_module, step_countermodel, "p_past_a", 2,
        q3a::replay::InductionObligation::Base);
    require(!initial_history_in_base.validated &&
        initial_history_in_base.message.find("initially false") != std::string::npos,
        "base replay must continue enforcing the initial history-valid guard state");

    auto bad_step_hypothesis = step_countermodel;
    bad_step_hypothesis[0]["past_a"] = 0;
    const auto bad_hypothesis_replay = q3a::replay::validate_induction_countermodel(
        past_module, bad_step_hypothesis, "p_past_a", 1,
        q3a::replay::InductionObligation::Step);
    require(!bad_hypothesis_replay.validated &&
        bad_hypothesis_replay.message.find("induction hypothesis") != std::string::npos,
        "step replay must reject a trace that does not satisfy the induction hypothesis");

    auto mismatched_tir = past_module;
    mismatched_tir.properties.front().antecedent.terms.front().predicate = signal("a");
    const auto mismatched_property_replay = q3a::replay::validate_induction_countermodel(
        mismatched_tir, step_countermodel, "p_past_a", 1,
        q3a::replay::InductionObligation::Step);
    require(!mismatched_property_replay.validated &&
        (mismatched_property_replay.message.find("term and automaton predicate disagree") !=
             std::string::npos ||
         mismatched_property_replay.message.find("unsupported assertion or implication form") !=
             std::string::npos),
        "step replay must reject inconsistent scalar T-IR term/automaton predicates");

    const auto overflowing_depth = q3a::replay::validate_induction_countermodel(
        past_module, {}, "p_past_a", std::numeric_limits<std::size_t>::max(),
        q3a::replay::InductionObligation::Step);
    require(!overflowing_depth.validated &&
        overflowing_depth.message.find("frame-count range") != std::string::npos,
        "step replay must reject a frame-count overflow before comparing trace length");

    check_arithmetic_replay();
    check_unary_and_shift_replay();
    check_width_extension_replay();
    check_conditional_extension_replay();
    check_implication_cover_replay();
    check_branched_repeat_replay();
    check_bounded_temporal_tail();
    check_repetition_prefix_replay();
    std::cout << "PASS: bounded replay distinguishes completed failures, unfinished tails, and overflowing offsets.\n";
    check_frame_by_frame_mutation_replay();
    std::cout << "PASS: replay rejected every one-bit mutation of input, state, and combinational signal values in a two-frame counterexample.\n";
    return 0;
}
