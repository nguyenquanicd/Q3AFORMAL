#include "property_replay.hpp"
#include "../source_manager/source_manager.hpp"

#include <algorithm>
#include <charconv>
#include <limits>
#include <stdexcept>
#include <system_error>

namespace q3a::replay {
namespace {

std::uint64_t width_mask(std::uint64_t width) {
    if (width == 0 || width > 64) {
        throw std::invalid_argument("replay encountered a width outside 1..64");
    }
    return width == 64 ? std::numeric_limits<std::uint64_t>::max()
                       : (std::uint64_t{1} << width) - 1;
}

std::uint64_t parse_number(const std::string& text, int base) {
    std::uint64_t value = 0;
    const auto parsed = std::from_chars(
        text.data(), text.data() + text.size(), value, base);
    if (text.empty() || parsed.ec != std::errc{} ||
        parsed.ptr != text.data() + text.size()) {
        throw std::invalid_argument("malformed or out-of-range RTL literal '" + text + "'");
    }
    return value;
}

std::uint64_t literal_value(const lowering::TypedExpression& expression) {
    const auto mask = width_mask(expression.width);
    if (expression.kind == "constant") {
        if (!expression.is_signed && !expression.value.empty() &&
            expression.value.front() != '-') {
            return parse_number(expression.value, 10) & mask;
        }
        std::int64_t value = 0;
        const auto parsed = std::from_chars(
            expression.value.data(),
            expression.value.data() + expression.value.size(), value);
        if (parsed.ec != std::errc{} ||
            parsed.ptr != expression.value.data() + expression.value.size()) {
            throw std::invalid_argument("malformed signed T-IR constant '" +
                expression.value + "'");
        }
        return static_cast<std::uint64_t>(value) & mask;
    }

    const auto& text = expression.value;
    if (text == "'0") return 0;
    if (text == "'1") return mask;
    const auto quote = text.find('\'');
    if (quote == std::string::npos) {
        std::int64_t signed_value = 0;
        const auto parsed = std::from_chars(
            text.data(), text.data() + text.size(), signed_value);
        if (parsed.ec != std::errc{} ||
            parsed.ptr != text.data() + text.size()) {
            throw std::invalid_argument("malformed unsized decimal literal '" + text + "'");
        }
        return static_cast<std::uint64_t>(signed_value) & mask;
    }

    auto radix_index = quote + 1;
    if (radix_index < text.size() &&
        (text[radix_index] == 's' || text[radix_index] == 'S')) {
        ++radix_index;
    }
    if (radix_index >= text.size()) {
        throw std::invalid_argument("based literal has no radix: '" + text + "'");
    }
    const char radix = text[radix_index];
    const int base = radix == 'b' || radix == 'B' ? 2 :
        radix == 'o' || radix == 'O' ? 8 :
        radix == 'd' || radix == 'D' ? 10 :
        radix == 'h' || radix == 'H' ? 16 : 0;
    if (base == 0) throw std::invalid_argument("unsupported literal radix in '" + text + "'");
    std::string digits = text.substr(radix_index + 1);
    digits.erase(std::remove(digits.begin(), digits.end(), '_'), digits.end());
    return parse_number(digits, base) & mask;
}

bool truth(std::uint64_t value) { return value != 0; }

bool signed_less(std::uint64_t left, std::uint64_t right, std::uint64_t width) {
    const auto sign_bit = std::uint64_t{1} << (width - 1);
    const bool left_negative = (left & sign_bit) != 0;
    const bool right_negative = (right & sign_bit) != 0;
    if (left_negative != right_negative) return left_negative;
    return left < right;
}

std::uint64_t extend_value(std::uint64_t value,
                           std::uint64_t source_width,
                           std::uint64_t result_width,
                           bool sign_extend) {
    const auto source_mask = width_mask(source_width);
    value &= source_mask;
    if (sign_extend && source_width < result_width &&
        ((value >> (source_width - 1)) & 1U) != 0) {
        value |= ~source_mask;
    }
    return value & width_mask(result_width);
}

bool is_constant_shift_distance(
    const lowering::TypedExpression& expression) {
    if (expression.kind == "literal" || expression.kind == "constant") return true;
    if (expression.kind == "assignment_resize" || expression.kind == "bit_vector_function") {
        return expression.operands.size() == 1 &&
            is_constant_shift_distance(expression.operands.front());
    }
    if (expression.kind == "concatenation" ||
        (expression.kind == "conditional" && expression.operands.size() == 3)) {
        return std::all_of(expression.operands.begin(), expression.operands.end(),
            is_constant_shift_distance);
    }
    if (expression.kind == "unary") {
        return expression.operands.size() == 1 &&
            (expression.value == "+" || expression.value == "-" ||
             expression.value == "!" || expression.value == "~") &&
            is_constant_shift_distance(expression.operands.front());
    }
    if (expression.kind == "binary") {
        return expression.operands.size() == 2 &&
            (expression.value == "+" || expression.value == "-" ||
             expression.value == "&" || expression.value == "|" ||
             expression.value == "^" || expression.value == "~^" ||
             expression.value == "^~" || expression.value == "&&" ||
             expression.value == "||" || expression.value == "==" ||
             expression.value == "!=" || expression.value == "<" ||
             expression.value == "<=" || expression.value == ">" ||
             expression.value == ">=" || expression.value == "<<" ||
             expression.value == ">>") &&
            is_constant_shift_distance(expression.operands[0]) &&
            is_constant_shift_distance(expression.operands[1]);
    }
    return false;
}

std::uint64_t evaluate(
    const lowering::TypedExpression& expression, const Frame& frame) {
    const auto mask = width_mask(expression.width);
    if (expression.kind == "signal" || expression.kind == "history_ref") {
        const auto found = frame.find(expression.value);
        if (found == frame.end()) {
            throw std::invalid_argument("trace lacks signal '" + expression.value + "'");
        }
        return found->second & mask;
    }
    if (expression.kind == "literal" || expression.kind == "constant") {
        return literal_value(expression);
    }
    if (expression.kind == "assignment_resize") {
        if (expression.operands.size() != 1) {
            throw std::invalid_argument(
                "assignment-resize T-IR expression has invalid arity during replay");
        }
        const auto& source = expression.operands.front();
        return extend_value(evaluate(source, frame), source.width,
                            expression.width, source.is_signed) & mask;
    }
    if (expression.kind == "bit_vector_function") {
        const bool count = expression.value == "$countones";
        if (!frontend::is_bit_vector_assertion_function(expression.value) ||
            expression.operands.size() != 1 || expression.width != (count ? 32U : 1U) ||
            expression.is_signed != count) {
            throw std::invalid_argument("malformed bit-vector function during replay");
        }
        auto bits = evaluate(expression.operands.front(), frame);
        unsigned set_bits = 0;
        while (bits != 0) {
            bits &= bits - 1;
            ++set_bits;
        }
        if (count) return set_bits;
        return expression.value == "$onehot" ? set_bits == 1 : set_bits <= 1;
    }
    if (expression.kind == "unary") {
        if (expression.operands.size() != 1) {
            throw std::invalid_argument("unary T-IR expression has invalid arity");
        }
        const auto value = evaluate(expression.operands.front(), frame);
        if (expression.value == "!") return truth(value) ? 0 : 1;
        if (expression.value == "~") return (~value) & mask;
        if (expression.value == "+") return value & mask;
        if (expression.value == "-") return (std::uint64_t{0} - value) & mask;
        throw std::invalid_argument("unsupported replay unary operator '" +
            expression.value + "'");
    }
    if (expression.kind == "conditional") {
        if (expression.operands.size() != 3) {
            throw std::invalid_argument("conditional T-IR expression has invalid arity");
        }
        const auto condition = evaluate(expression.operands[0], frame);
        const auto& when_true_expression = expression.operands[1];
        const auto& when_false_expression = expression.operands[2];
        const auto result_width = std::max(when_true_expression.width,
                                           when_false_expression.width);
        if (expression.width != result_width) {
            throw std::invalid_argument("conditional T-IR result width mismatch during replay");
        }
        const bool sign_extend = when_true_expression.is_signed &&
                                 when_false_expression.is_signed;
        const auto& selected_expression = truth(condition)
            ? when_true_expression : when_false_expression;
        const auto selected = evaluate(selected_expression, frame);
        return extend_value(selected, selected_expression.width,
                            result_width, sign_extend) & mask;
    }
    if (expression.kind == "concatenation") {
        std::uint64_t value = 0;
        std::uint64_t accumulated_width = 0;
        for (const auto& operand : expression.operands) {
            if (operand.width == 0 || operand.width > 64 ||
                accumulated_width > 64 - operand.width) {
                throw std::invalid_argument("concatenation operand width exceeds 64 bits");
            }
            const auto part = evaluate(operand, frame);
            if (operand.width == 64) value = part;
            else value = (value << operand.width) | part;
            accumulated_width += operand.width;
        }
        return value & mask;
    }
    if (expression.kind == "select") {
        if (expression.operands.size() != 2) {
            throw std::invalid_argument("normalized select T-IR expression has invalid arity");
        }
        const auto& offset_expression = expression.operands[1];
        if (offset_expression.kind != "constant" &&
            offset_expression.kind != "literal") {
            throw std::invalid_argument("select source bit offset is not a compile-time constant");
        }
        const auto offset = literal_value(offset_expression);
        const auto source = evaluate(expression.operands[0], frame);
        if (expression.value == "bit") {
            if (expression.width != 1 || offset >= expression.operands[0].width) {
                throw std::invalid_argument("bit-select offset or result width is invalid during replay");
            }
            return (source >> offset) & 1U;
        }
        if (expression.value == "part") {
            if (offset > expression.operands[0].width ||
                expression.width > expression.operands[0].width - offset) {
                throw std::invalid_argument("part-select offset/width exceeds its vector during replay");
            }
            return (source >> offset) & mask;
        }
        throw std::invalid_argument("unsupported normalized select kind during replay");
    }
    if (expression.kind == "casez_match") {
        if (expression.operands.size() != 3) {
            throw std::invalid_argument("casez_match T-IR expression has invalid arity");
        }
        const auto selector = evaluate(expression.operands[0], frame);
        const auto pattern = evaluate(expression.operands[1], frame);
        const auto constrained_mask = evaluate(expression.operands[2], frame);
        return (selector & constrained_mask) == (pattern & constrained_mask) ? 1 : 0;
    }
    if (expression.kind != "binary" || expression.operands.size() != 2) {
        throw std::invalid_argument("unsupported T-IR expression kind '" +
            expression.kind + "' during witness replay");
    }

    const auto& left_expression = expression.operands[0];
    const auto& right_expression = expression.operands[1];
    const auto left = evaluate(left_expression, frame);
    const auto right = evaluate(right_expression, frame);
    const auto& op = expression.value;
    if (op == "<<" || op == ">>" || op == ">>>") {
        if (!is_constant_shift_distance(right_expression)) {
            throw std::invalid_argument(
                "Phase 0 replay requires a compile-time constant shift distance");
        }
        if (right_expression.is_signed && right_expression.width != 0 &&
            ((right >> (right_expression.width - 1)) & 1U) != 0) {
            throw std::invalid_argument("negative constant shift distance during replay");
        }
        const bool sign_fill = op == ">>>" && left_expression.is_signed &&
            left_expression.width != 0 &&
            ((left >> (left_expression.width - 1)) & 1U) != 0;
        if (right >= left_expression.width) return sign_fill ? mask : 0;
        const auto shift = static_cast<unsigned>(right);
        if (op == "<<") return (left << shift) & mask;
        auto shifted = left >> shift;
        if (sign_fill && shift != 0) {
            shifted |= mask & ~width_mask(left_expression.width - shift);
        }
        return shifted & mask;
    }
    if (op == "+" || op == "-") {
        const auto result_width = std::max(left_expression.width,
                                           right_expression.width);
        if (expression.width != result_width) {
            throw std::invalid_argument("arithmetic T-IR result width mismatch during replay");
        }
        const bool sign_extend =
            left_expression.is_signed && right_expression.is_signed;
        const auto extended_left = extend_value(left, left_expression.width,
                                                 result_width, sign_extend);
        const auto extended_right = extend_value(right, right_expression.width,
                                                  result_width, sign_extend);
        const auto result = op == "+"
            ? extended_left + extended_right
            : extended_left - extended_right;
        return result & mask;
    }
    if (op == "&&") return truth(left) && truth(right) ? 1 : 0;
    if (op == "||") return truth(left) || truth(right) ? 1 : 0;
    const bool signed_operands =
        left_expression.is_signed && right_expression.is_signed;
    const auto operand_width = std::max(left_expression.width,
                                        right_expression.width);
    const auto extended_left = extend_value(left, left_expression.width,
                                            operand_width, signed_operands);
    const auto extended_right = extend_value(right, right_expression.width,
                                             operand_width, signed_operands);
    if (op == "==") return extended_left == extended_right ? 1 : 0;
    if (op == "!=") return extended_left != extended_right ? 1 : 0;
    if (op == "<" || op == "<=" || op == ">" || op == ">=") {
        const bool less = signed_operands
            ? signed_less(extended_left, extended_right, operand_width)
            : extended_left < extended_right;
        const bool greater = signed_operands
            ? signed_less(extended_right, extended_left, operand_width)
            : extended_left > extended_right;
        if (op == "<") return less ? 1 : 0;
        if (op == "<=") return less || extended_left == extended_right ? 1 : 0;
        if (op == ">") return greater ? 1 : 0;
        return greater || extended_left == extended_right ? 1 : 0;
    }
    if (op == "&") return (extended_left & extended_right) & mask;
    if (op == "|") return (extended_left | extended_right) & mask;
    if (op == "^") return (extended_left ^ extended_right) & mask;
    if (op == "~^" || op == "^~") return (~(extended_left ^ extended_right)) & mask;
    throw std::invalid_argument("unsupported replay binary operator '" + op + "'");
}

std::uint64_t sequence_max_offset(const lowering::TIRSequence& sequence) {
    return lowering::sequence_maximum_offset(sequence);
}

bool requires_future_sample(const lowering::TIRProperty& property) {
    return sequence_max_offset(property.antecedent) != 0 ||
        property.implication == "nonoverlapped" ||
        (property.consequent.has_value() && sequence_max_offset(*property.consequent) != 0);
}

bool has_open_boundary(const lowering::TIRModule& module,
                       const lowering::TIRProperty& target) {
    // Bounded queries allow a start at every frame. An obligation requiring a
    // later sample cannot be completed for a start at the final frame.
    return requires_future_sample(target) ||
        std::any_of(module.properties.begin(), module.properties.end(),
            [](const lowering::TIRProperty& property) {
                return property.kind == "assume" && requires_future_sample(property);
            });
}

bool sequence_term_agrees_with_automaton(
    const lowering::TIRSequence& sequence, const Frame& frame) {
    if (!lowering::bounded_scalar_sequence_horizon(sequence).has_value()) {
        return false;
    }
    for (std::size_t index = 0; index < sequence.terms.size(); ++index) {
        if (truth(evaluate(sequence.terms[index].predicate, frame)) !=
            truth(evaluate(sequence.automaton.transitions[index].predicate, frame))) {
            return false;
        }
    }
    return true;
}

std::vector<std::size_t> sequence_ends(
    const lowering::TIRSequence& sequence,
    std::size_t start,
    const FrameView& trace,
    std::size_t last_sample) {
    std::vector<std::size_t> ends;
    const auto paths = lowering::sequence_paths(sequence);
    for (const auto& path : paths) {
        std::vector<std::size_t> frontier{start};
        for (auto index = path.begin; index < path.end; ++index) {
            const auto& transition = sequence.automaton.transitions[index];
            std::vector<std::size_t> next;
            for (const auto previous_end : frontier) {
                if (transition.delay_cycles > last_sample - previous_end) continue;
                const auto term_start = previous_end +
                    static_cast<std::size_t>(transition.delay_cycles);
                const auto fitting = std::min<std::uint64_t>(
                    transition.repeat_max, last_sample - term_start + 1);
                if (fitting < transition.repeat_min) continue;
                for (std::uint64_t repeat = 1; repeat <= fitting; ++repeat) {
                    const auto sample = term_start + static_cast<std::size_t>(repeat - 1);
                    // A false sample invalidates this length and all longer lengths.
                    if (!truth(evaluate(transition.predicate, trace[sample]))) break;
                    if (repeat >= transition.repeat_min) next.push_back(sample);
                }
            }
            if (frontier.size() > 1 && transition.repeat_min != transition.repeat_max) {
                std::sort(next.begin(), next.end());
                next.erase(std::unique(next.begin(), next.end()), next.end());
            }
            frontier = std::move(next);
            if (frontier.empty()) break;
        }
        if (paths.size() == 1) return frontier;
        ends.insert(ends.end(), frontier.begin(), frontier.end());
    }
    std::sort(ends.begin(), ends.end());
    ends.erase(std::unique(ends.begin(), ends.end()), ends.end());
    return ends;
}

std::vector<std::size_t> sequence_ends(
    const lowering::TIRSequence& sequence,
    std::size_t start,
    const FrameView& trace) {
    return sequence_ends(sequence, start, trace, trace.size() - 1);
}

bool guard_active(const std::string& guard_name, const Frame& frame) {
    if (guard_name.empty()) return true;
    const auto found = frame.find(guard_name);
    if (found == frame.end()) {
        throw std::invalid_argument("trace lacks property history guard '" +
            guard_name + "'");
    }
    return truth(found->second);
}

bool guard_active(const lowering::TIRProperty& property, const Frame& frame) {
    return guard_active(property.history_guard_signal, frame);
}

bool guarded_sequence_reaches(
    const lowering::TIRSequence& sequence, const std::string& guard,
    const FrameView& trace, std::size_t end) {
    const auto maximum_offset = sequence_max_offset(sequence);
    const auto first_start = end - static_cast<std::size_t>(
        std::min<std::uint64_t>(maximum_offset, end));
    for (auto start = first_start; start <= end; ++start) {
        if (!guard_active(guard, trace[start])) continue;
        const auto ends = sequence_ends(sequence, start, trace, end);
        if (std::find(ends.begin(), ends.end(), end) != ends.end()) return true;
    }
    return false;
}

void validate_assumptions(
    const lowering::TIRModule& module,
    const FrameView& trace,
    bool truncate_open_temporal_tail) {
    const auto last_frame = trace.size() - 1;
    for (const auto& property : module.properties) {
        if (property.kind != "assume") continue;
        if (property.implication.empty() || property.implication == "sequence") {
            const auto sequence_horizon =
                lowering::bounded_scalar_sequence_horizon(property.antecedent);
            if (property.consequent.has_value() ||
                !sequence_horizon.has_value()) {
                throw std::invalid_argument(
                    "unsupported bounded sequence assumption during replay");
            }
            for (std::size_t frame = 0; frame < trace.size(); ++frame) {
                if (*sequence_horizon > last_frame - frame) continue;
                if (guard_active(lowering::antecedent_history_guard(property),
                                 trace[frame]) &&
                    sequence_ends(property.antecedent, frame, trace).empty()) {
                    throw std::invalid_argument(
                        "decoded trace violates bounded sequence assumption '" +
                        property.name + "'");
                }
            }
            continue;
        }
        if ((property.implication != "overlapped" &&
             property.implication != "nonoverlapped") ||
            !property.consequent.has_value()) {
            throw std::invalid_argument("unsupported implication assumption during replay");
        }
        const auto assumption_horizon = truncate_open_temporal_tail
            ? lowering::bounded_induction_property_horizon(property)
            : std::optional<std::uint64_t>{0};
        if (!assumption_horizon) {
            throw std::invalid_argument(
                "unsupported delayed implication assumption during replay");
        }
        sequence_max_offset(property.antecedent);
        const auto consequent_offset = sequence_max_offset(*property.consequent);
        for (std::size_t start = 0; start < trace.size(); ++start) {
            if (truncate_open_temporal_tail &&
                *assumption_horizon > last_frame - start) continue;
            if (!guard_active(lowering::antecedent_history_guard(property),
                              trace[start])) continue;
            for (const auto antecedent_end : sequence_ends(
                     property.antecedent, start, trace)) {
                const auto delta = property.implication == "nonoverlapped" ? 1U : 0U;
                if (delta > last_frame || antecedent_end > last_frame - delta) continue;
                const auto consequent_start = antecedent_end + delta;
                if (consequent_offset > last_frame - consequent_start) continue;
                if (!guard_active(
                        lowering::consequent_history_guard(property),
                        trace[consequent_start])) continue;
                if (sequence_ends(*property.consequent, consequent_start, trace).empty()) {
                    throw std::invalid_argument("decoded trace violates implication assumption '" +
                        property.name + "'");
                }
            }
        }
    }
}

bool assertion_eligible_at(const lowering::TIRProperty& property, const FrameView& trace,
                           std::size_t candidate_frame) {
    if (candidate_frame >= trace.size()) return false;
    if (property.implication.empty() || property.implication == "sequence") {
        const auto sequence_offset = lowering::bounded_scalar_sequence_horizon(property.antecedent);
        if (!sequence_offset.has_value() || property.consequent.has_value()) {
            throw std::invalid_argument("unsupported fixed-delay scalar sequence assertion during replay");
        }
        return *sequence_offset <= trace.size() - 1 - candidate_frame &&
            guard_active(lowering::antecedent_history_guard(property), trace[candidate_frame]);
    }
    if ((property.implication != "overlapped" && property.implication != "nonoverlapped") ||
        !property.consequent.has_value()) {
        throw std::invalid_argument("unsupported implication assertion during replay");
    }
    const auto consequent_offset = sequence_max_offset(*property.consequent);
    const auto delta = property.implication == "nonoverlapped" ? 1U : 0U;
    if (candidate_frame < delta || consequent_offset > trace.size() - 1 - candidate_frame ||
        !guard_active(lowering::consequent_history_guard(property), trace[candidate_frame])) {
        return false;
    }
    return guarded_sequence_reaches(property.antecedent, lowering::antecedent_history_guard(property),
                                    trace, candidate_frame - delta);
}

bool assertion_fails_at(const lowering::TIRProperty& property, const FrameView& trace,
                        std::size_t candidate_frame) {
    if (!assertion_eligible_at(property, trace, candidate_frame)) return false;
    const auto& sequence = property.consequent ? *property.consequent : property.antecedent;
    return sequence_ends(sequence, candidate_frame, trace).empty();
}

bool induction_assertion_fails_at(
    const lowering::TIRProperty& property,
    const FrameView& trace,
    std::size_t property_start_frame) {
    if (property_start_frame >= trace.size()) return false;
    if (!property.consequent.has_value()) {
        return assertion_fails_at(property, trace, property_start_frame);
    }
    if ((property.implication != "overlapped" &&
         property.implication != "nonoverlapped") ||
        !lowering::bounded_induction_property_horizon(property).has_value()) {
        throw std::invalid_argument(
            "unsupported implication form during induction replay");
    }
    if (!property.split_history_guards &&
        !guard_active(property, trace[property_start_frame])) return false;
    if (!guard_active(lowering::antecedent_history_guard(property),
                      trace[property_start_frame])) return false;
    const auto last_frame = trace.size() - 1;
    const auto delta = property.implication == "nonoverlapped" ? 1U : 0U;
    for (const auto antecedent_end : sequence_ends(
             property.antecedent, property_start_frame, trace)) {
        if (delta > last_frame || antecedent_end > last_frame - delta) {
            throw std::invalid_argument(
                "induction trace ends before the consequent sample");
        }
        const auto consequent_start = antecedent_end + delta;
        const auto consequent_offset = sequence_max_offset(*property.consequent);
        if (consequent_offset > last_frame - consequent_start) {
            throw std::invalid_argument(
                "induction trace ends before the complete consequent sequence");
        }
        if (!guard_active(lowering::consequent_history_guard(property),
                          trace[consequent_start])) continue;
        if (sequence_ends(*property.consequent, consequent_start, trace).empty()) {
            return true;
        }
    }
    return false;
}

bool cover_matches_at(
    const lowering::TIRProperty& property,
    const FrameView& trace,
    std::size_t candidate_frame) {
    if (candidate_frame >= trace.size()) return false;
    const bool implication_cover = property.implication == "overlapped" ||
        property.implication == "nonoverlapped";
    if (implication_cover != property.consequent.has_value() ||
        (!implication_cover && !property.implication.empty() &&
         property.implication != "sequence")) {
        throw std::invalid_argument("unsupported cover form during witness replay");
    }
    if (implication_cover) {
        const auto delta = property.implication == "nonoverlapped" ? 1U : 0U;
        const auto maximum_offset = sequence_max_offset(*property.consequent);
        const auto first_start = candidate_frame - static_cast<std::size_t>(
            std::min<std::uint64_t>(maximum_offset, candidate_frame));
        for (auto start = std::max<std::size_t>(first_start, delta);
             start <= candidate_frame; ++start) {
            if (!guard_active(lowering::consequent_history_guard(property), trace[start])) continue;
            const auto ends = sequence_ends(*property.consequent, start, trace, candidate_frame);
            if (std::find(ends.begin(), ends.end(), candidate_frame) != ends.end() &&
                guarded_sequence_reaches(property.antecedent,
                    lowering::antecedent_history_guard(property), trace, start - delta)) {
                return true;
            }
        }
        return false;
    }
    sequence_max_offset(property.antecedent);
    const auto& automaton = property.antecedent.automaton;
    if (automaton.transitions.size() == 1) {
        const auto& transition = automaton.transitions.front();
        if (transition.delay_cycles == 0 && transition.repeat_min == 1 &&
            transition.repeat_max == 1) {
            return guard_active(lowering::antecedent_history_guard(property),
                trace[candidate_frame]) &&
                truth(evaluate(transition.predicate, trace[candidate_frame]));
        }
    }
    return guarded_sequence_reaches(property.antecedent,
        lowering::antecedent_history_guard(property), trace, candidate_frame);
}

Result validate_decoded_trace(
    const lowering::TIRModule& module,
    const FrameView& trace,
    bool require_initial_history_validity = true,
    bool truncate_open_temporal_tail = false) {
    if (trace.empty()) return {false, "decoded trace has no frames"};
    for (std::size_t frame = 0; frame < trace.size(); ++frame) {
        for (const auto& signal : module.signals) {
            const auto value = trace[frame].find(signal.name);
            if (value == trace[frame].end()) {
                return {false, "decoded frame is missing signal '" + signal.name + "'"};
            }
            if ((value->second & ~width_mask(signal.width)) != 0) {
                return {false, "decoded signal value exceeds its declared width: '" +
                    signal.name + "'"};
            }
        }
        if (!module.signals.empty() && trace[frame].size() != module.signals.size()) {
            return {false, "decoded frame contains signals outside the transition model at frame " +
                std::to_string(frame)};
        }
    }
    if (require_initial_history_validity) {
        for (const auto& guard : module.history_guards) {
            for (const auto& state : guard.state_chain) {
                if (trace.front().at(state) != 0) {
                    return {false, "generated history-valid state is not initially false: '" +
                        state + "'"};
                }
            }
        }
    }
    for (std::size_t frame = 0; frame < trace.size(); ++frame) {
        for (const auto& equation : module.combinational_equations) {
            if (evaluate(equation.expression, trace[frame]) !=
                trace[frame].at(equation.target)) {
                return {false, "combinational equation replay mismatch for '" +
                    equation.target + "' at frame " + std::to_string(frame)};
            }
        }
        if (frame + 1 == trace.size()) continue;
        for (const auto& equation : module.next_state_equations) {
            if (evaluate(equation.expression, trace[frame]) !=
                trace[frame + 1].at(equation.target)) {
                return {false, "next-state equation replay mismatch for '" +
                    equation.target + "' at frame " + std::to_string(frame)};
            }
        }
    }
    validate_assumptions(module, trace, truncate_open_temporal_tail);
    return {true, "transition equations and assumptions replayed"};
}

} // namespace

std::uint64_t evaluate_word(const lowering::TypedExpression& expression, const Frame& frame) {
    return evaluate(expression, frame);
}

ActivationReplay validate_bounded_activation(const lowering::TIRModule& module, const FrameView& trace,
                                              const std::string& property_name) {
    try {
        const auto checked = validate_decoded_trace(module, trace);
        if (!checked.validated) return {checked, std::nullopt};
        const auto property = std::find_if(module.properties.begin(), module.properties.end(),
            [&](const auto& candidate) { return candidate.name == property_name && candidate.kind == "assert"; });
        if (property == module.properties.end()) return {{false, "assertion is missing"}, std::nullopt};
        for (std::size_t frame = 0; frame < trace.size(); ++frame) {
            if (!assertion_eligible_at(*property, trace, frame)) continue;
            const bool pending = std::any_of(module.properties.begin(), module.properties.end(),
                [](const auto& check) { return check.kind == "assume" && requires_future_sample(check); });
            return {{true, "assertion activation independently replayed", pending}, frame};
        }
        return {{false, "no active assertion in the candidate trace"}, std::nullopt};
    } catch (const MemoryBudgetExceeded&) {
        throw;
    } catch (const std::bad_alloc&) {
        throw;
    } catch (const std::exception& error) {
        return {{false, error.what()}, std::nullopt};
    }
}

Result validate_bounded_counterexample(
    const lowering::TIRModule& module,
    const std::vector<Frame>& trace,
    const std::string& property_name,
    std::size_t candidate_frame) {
    return validate_bounded_counterexample_view(module, FrameView(trace), property_name, candidate_frame);
}

Result validate_bounded_cover(
    const lowering::TIRModule& module,
    const std::vector<Frame>& trace,
    const std::string& property_name,
    std::size_t candidate_frame) {
    return validate_bounded_cover_view(module, FrameView(trace), property_name, candidate_frame);
}

Result validate_bounded_counterexample_view(
    const lowering::TIRModule& module,
    const FrameView& trace,
    const std::string& property_name,
    std::size_t candidate_frame) {
    try {
        const auto trace_result = validate_decoded_trace(module, trace);
        if (!trace_result.validated) return trace_result;
        if (candidate_frame >= trace.size()) {
            return {false, "candidate frame is outside the decoded trace"};
        }
        const auto property = std::find_if(
            module.properties.begin(), module.properties.end(),
            [&](const lowering::TIRProperty& candidate) {
                return candidate.name == property_name && candidate.kind == "assert";
            });
        if (property == module.properties.end()) {
            return {false, "assertion property disappeared before replay"};
        }
        if (!assertion_fails_at(*property, trace, candidate_frame)) {
            return {false, "decoded trace does not violate the selected assertion at its candidate frame"};
        }
        return {true, "transition equations, assumptions, and assertion failure replayed",
                has_open_boundary(module, *property)};
    } catch (const MemoryBudgetExceeded&) {
        throw;
    } catch (const std::bad_alloc&) {
        throw;
    } catch (const std::exception& error) {
        return {false, error.what()};
    }
}

Result validate_bounded_cover_view(
    const lowering::TIRModule& module,
    const FrameView& trace,
    const std::string& property_name,
    std::size_t candidate_frame) {
    try {
        const auto trace_result = validate_decoded_trace(module, trace);
        if (!trace_result.validated) return trace_result;
        if (candidate_frame >= trace.size()) {
            return {false, "candidate frame is outside the decoded trace"};
        }
        const auto property = std::find_if(
            module.properties.begin(), module.properties.end(),
            [&](const lowering::TIRProperty& candidate) {
                return candidate.name == property_name && candidate.kind == "cover";
            });
        if (property == module.properties.end()) {
            return {false, "cover property disappeared before replay"};
        }
        if (!cover_matches_at(*property, trace, candidate_frame)) {
            return {false, "decoded trace does not reach the selected cover goal at its candidate frame"};
        }
        return {true, "transition equations, assumptions, and cover goal replayed",
                has_open_boundary(module, *property)};
    } catch (const MemoryBudgetExceeded&) {
        throw;
    } catch (const std::bad_alloc&) {
        throw;
    } catch (const std::exception& error) {
        return {false, error.what()};
    }
}

InductionReplayResult validate_induction_countermodel(
    const lowering::TIRModule& module,
    const std::vector<Frame>& decoded_trace,
    const std::string& property_name,
    std::size_t depth,
    InductionObligation obligation) {
    return validate_induction_countermodel_view(module, FrameView(decoded_trace),
                                               property_name, depth, obligation);
}

InductionReplayResult validate_induction_countermodel_view(
    const lowering::TIRModule& module, const FrameView& trace,
    const std::string& property_name, std::size_t depth, InductionObligation obligation) {
    try {
        if (depth == 0) {
            return {false, static_cast<std::size_t>(-1),
                "induction replay depth must be positive"};
        }
        if (obligation == InductionObligation::Step &&
            depth == std::numeric_limits<std::size_t>::max()) {
            return {false, static_cast<std::size_t>(-1),
                "induction step depth exceeds the frame-count range"};
        }
        const auto property = std::find_if(
            module.properties.begin(), module.properties.end(),
            [&](const lowering::TIRProperty& candidate) {
                return candidate.name == property_name && candidate.kind == "assert";
            });
        if (property == module.properties.end()) {
            return {false, static_cast<std::size_t>(-1),
                "assertion property disappeared before induction replay"};
        }
        const auto target_horizon =
            lowering::bounded_induction_property_horizon(*property);
        if (!target_horizon.has_value()) {
            return {false, static_cast<std::size_t>(-1),
                "induction replay found an unsupported assertion or implication form"};
        }
        const auto target_lookahead = *target_horizon;
        if (target_lookahead > 10000 ||
            depth > 10000 - static_cast<std::size_t>(target_lookahead)) {
            return {false, static_cast<std::size_t>(-1),
                "induction target horizon exceeds the 10000-transition limit"};
        }
        const auto step_extra =
            obligation == InductionObligation::Step ? std::size_t{1} : std::size_t{0};
        if (target_lookahead >
            std::numeric_limits<std::size_t>::max() - step_extra) {
            return {false, static_cast<std::size_t>(-1),
                "induction target horizon exceeds the frame-count range"};
        }
        const auto extra_frames = step_extra +
            static_cast<std::size_t>(target_lookahead);
        if (depth > std::numeric_limits<std::size_t>::max() - extra_frames) {
            return {false, static_cast<std::size_t>(-1),
                "induction depth exceeds the frame-count range"};
        }
        const auto expected_frames = depth + extra_frames;
        if (trace.size() != expected_frames) {
            return {false, static_cast<std::size_t>(-1),
                "induction witness has " + std::to_string(trace.size()) +
                " frames; expected " + std::to_string(expected_frames)};
        }
        const auto trace_result = validate_decoded_trace(
            module, trace, obligation == InductionObligation::Base, true);
        if (!trace_result.validated) {
            return {false, static_cast<std::size_t>(-1), trace_result.message};
        }
        const bool implication_property = property->consequent.has_value();
        for (const auto& assumption : module.properties) {
            if (assumption.kind != "assume") continue;
            const bool supported_assumption = lowering::
                bounded_induction_property_horizon(assumption).has_value();
            if (!supported_assumption) {
                return {false, static_cast<std::size_t>(-1),
                    "induction replay found an unsupported assumption property"};
            }
            for (std::size_t frame = 0; frame < trace.size(); ++frame) {
                if (!sequence_term_agrees_with_automaton(
                        assumption.antecedent, trace[frame]) ||
                    (assumption.consequent.has_value() &&
                     !sequence_term_agrees_with_automaton(
                        *assumption.consequent, trace[frame]))) {
                    return {false, static_cast<std::size_t>(-1),
                        "T-IR assumption sequence term and automaton predicate disagree at frame " +
                        std::to_string(frame)};
                }
            }
        }
        for (std::size_t frame = 0; frame < trace.size(); ++frame) {
            if (!sequence_term_agrees_with_automaton(
                    property->antecedent, trace[frame]) ||
                (implication_property &&
                 !sequence_term_agrees_with_automaton(
                    *property->consequent, trace[frame]))) {
                return {false, static_cast<std::size_t>(-1),
                    "T-IR sequence term and automaton predicate disagree at frame " +
                    std::to_string(frame)};
            }
        }

        if (obligation == InductionObligation::Base) {
            for (std::size_t frame = 0; frame < depth; ++frame) {
                if (induction_assertion_fails_at(*property, trace, frame)) {
                    return {true, frame,
                        "initial-state trace, assumptions, and base assertion failure replayed"};
                }
            }
            return {false, static_cast<std::size_t>(-1),
                "base model does not violate the assertion in the required prefix"};
        }

        for (std::size_t frame = 0; frame < depth; ++frame) {
            if (induction_assertion_fails_at(*property, trace, frame)) {
                return {false, static_cast<std::size_t>(-1),
                    "step witness violates the induction hypothesis at frame " +
                    std::to_string(frame)};
            }
        }
        if (!induction_assertion_fails_at(*property, trace, depth)) {
            return {false, static_cast<std::size_t>(-1),
                "step model does not falsify the assertion at the terminal frame"};
        }
        return {true, depth,
            "transition equations, assumptions, induction hypothesis, and step failure replayed"};
    } catch (const MemoryBudgetExceeded&) {
        throw;
    } catch (const std::bad_alloc&) {
        throw;
    } catch (const std::exception& error) {
        return {false, static_cast<std::size_t>(-1), error.what()};
    }
}

} // namespace q3a::replay
