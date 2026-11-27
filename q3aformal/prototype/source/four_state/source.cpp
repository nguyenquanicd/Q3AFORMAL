#include "source.hpp"

#include <algorithm>
#include <charconv>
#include <cctype>
#include <set>
#include <stdexcept>
#include <utility>

namespace q3a::four_state {
namespace {

using lowering::TypedExpression;

Word scalar(Logic value) {
    const auto code = static_cast<unsigned>(value);
    return Word(1, code >> 1, code & 1);
}

Logic invert(Logic value) {
    if (value == Logic::Zero) return Logic::One;
    if (value == Logic::One) return Logic::Zero;
    return Logic::X;
}

[[noreturn]] void unsupported(const TypedExpression& expression) {
    throw lowering::LoweringError(expression.location,
        "operator outside the four-state combinational profile: " + expression.kind + " " + expression.value,
        frontend::InputDiagnosticKind::Unsupported);
}

bool ready(const TypedExpression& expression, const std::set<std::string>& available) {
    if (expression.kind == "signal" || expression.kind == "history_ref") return available.count(expression.value) != 0;
    for (const auto& operand : expression.operands) {
        if (!ready(operand, available)) return false;
    }
    return true;
}

Word evaluate(const TypedExpression& expression, const Frame& frame) {
    const auto& operands = expression.operands;
    const auto width = static_cast<unsigned>(expression.width);
    const auto& kind = expression.kind;
    const auto& op = expression.value;
    const auto operand = [&](std::size_t index) { return evaluate(operands.at(index), frame); };
    if (kind == "signal" || kind == "history_ref") return frame.at(op);
    if (kind == "literal" || kind == "constant") return decode_literal(expression);
    if (kind == "assignment_resize") return operand(0).resized(width, operands.at(0).is_signed);
    if (kind == "indexed_bit" || kind == "indexed_part") {
        const auto value = operand(0);
        const auto base = operand(1);
        const frontend::PackedBounds bounds{std::stoll(operands.at(2).value), std::stoll(operands.at(3).value)};
        std::uint64_t meta = Word(width, 0, 0).mask();
        std::uint64_t data = 0;
        for (unsigned bit = 0; bit < width; ++bit) {
            const auto delta = indexed_result_delta(bounds.first >= bounds.second, op != "-:", width, bit);
            const auto index = offset_packed_index(base, operands.at(1).is_signed, delta);
            if (!index) continue;
            const auto lower = std::min(bounds.first, bounds.second);
            const auto upper = std::max(bounds.first, bounds.second);
            if (*index < lower || *index > upper) continue;
            const auto offset = frontend::resolve_packed_select(bounds, value.width(), *index, std::nullopt).offset;
            const auto selected = value.slice(static_cast<unsigned>(offset), 1);
            const auto mask = std::uint64_t{1} << bit;
            if (selected.meta() == 0) meta &= ~mask;
            if (selected.data() != 0) data |= mask;
        }
        return Word(width, meta, data);
    }
    if (kind == "select") {
        const auto offset = operand(1);
        if (offset.meta() != 0 || offset.data() >= 64) unsupported(expression);
        return operand(0).slice(static_cast<unsigned>(offset.data()), width);
    }
    if (kind == "casez_match" && op == "four-state-z-wildcard") {
        return Word(1, 0, case_match(operand(0), operand(1), CaseMode::ZWildcard));
    }
    if (kind == "casex_match" && op == "four-state-xz-wildcard") {
        return Word(1, 0, case_match(operand(0), operand(1), CaseMode::XZWildcard));
    }
    if (kind == "concatenation") {
        auto word = operand(0);
        for (std::size_t index = 1; index < operands.size(); ++index) word = concatenate(word, operand(index));
        return word;
    }
    if (kind == "conditional") {
        if (op == "if") return operand(truth(operand(0)) == Logic::One ? 1 : 2);
        const auto signed_branches = operands.at(1).is_signed && operands.at(2).is_signed;
        return conditional(operand(0), operand(1).resized(width, signed_branches),
                           operand(2).resized(width, signed_branches));
    }
    if (kind == "unary") {
        if (op == "~") return bit_not(operand(0).resized(width, operands.at(0).is_signed));
        if (op == "!") return scalar(logical_not(operand(0)));
        if (op == "-") {
            return add_subtract(Word(width, 0, 0), operand(0).resized(width, operands.at(0).is_signed), true);
        }
        if (frontend::is_reduction_operator(op)) {
            const auto value = operand(0);
            const auto result = op == "&" || op == "~&" ? reduce_and(value) :
                op == "|" || op == "~|" ? reduce_or(value) : reduce_xor(value);
            return scalar(op.size() == 1 ? result : invert(result));
        }
        unsupported(expression);
    }
    if (kind == "binary") {
        const auto a = operand(0);
        const auto b = operand(1);
        if (op == "&&") return scalar(logical_and(a, b));
        if (op == "||") return scalar(logical_or(a, b));
        if (frontend::is_shift_operator(op)) {
            const auto direction = op.front() == '<' ? Shift::Left :
                op == ">>>" && expression.is_signed ? Shift::ArithmeticRight : Shift::Right;
            return shift(a.resized(width, expression.is_signed), b, direction);
        }
        const bool bitwise = op == "&" || op == "|" || op == "^" || op == "~^" || op == "^~";
        const bool arithmetic = op == "+" || op == "-" || op == "*" || op == "/" || op == "%";
        const auto common = bitwise || arithmetic ? width : std::max(a.width(), b.width());
        const bool sign_extend = operands.at(0).is_signed && operands.at(1).is_signed;
        const auto left = a.resized(common, sign_extend);
        const auto right = b.resized(common, sign_extend);
        if (op == "*") return multiply(left, right);
        if (op == "/" || op == "%") return divide(left, right, sign_extend, op == "%");
        if (arithmetic) return add_subtract(left, right, op == "-");
        if (op == "<") return scalar(less_than(left, right, sign_extend));
        if (op == ">") return scalar(less_than(right, left, sign_extend));
        if (op == "<=") return scalar(invert(less_than(right, left, sign_extend)));
        if (op == ">=") return scalar(invert(less_than(left, right, sign_extend)));
        if (op == "&") return bit_and(left, right);
        if (op == "|") return bit_or(left, right);
        if (op == "^") return bit_xor(left, right);
        if (op == "~^" || op == "^~") return bit_not(bit_xor(left, right));
        if (op == "==?") return scalar(wildcard_equal(left, right));
        if (op == "!=?") return scalar(invert(wildcard_equal(left, right)));
        if (op == "==") return scalar(equal(left, right));
        if (op == "!=") return scalar(invert(equal(left, right)));
        if (op == "===") return Word(1, 0, case_match(left, right));
        if (op == "!==") return Word(1, 0, !case_match(left, right));
    }
    unsupported(expression);
}

std::uint64_t decimal(std::string_view text) {
    const auto end = text.data() + text.size();
    if (!text.empty() && text.front() == '-') {
        std::int64_t value = 0;
        const auto result = std::from_chars(text.data(), end, value);
        if (result.ec == std::errc{} && result.ptr == end) return static_cast<std::uint64_t>(value);
    } else {
        std::uint64_t value = 0;
        const auto result = std::from_chars(text.data(), end, value);
        if (result.ec == std::errc{} && result.ptr == end) return value;
    }
    throw std::invalid_argument("invalid decimal value in four-state literal");
}

} // namespace

void require_combinational_project(const std::vector<frontend::SyntaxUnit>& units, std::string_view top, bool sampled, bool assertions) {
    std::map<std::string, const frontend::ParsedModule*> modules;
    for (const auto& unit : units) {
        if (!unit.binds.empty() || !unit.standalone_checks.empty() || !unit.standalone_declarations.empty()) {
            throw std::invalid_argument("standalone assertions and binds are outside the four-state evaluator");
        }
        for (const auto& candidate : unit.modules) {
            auto [entry, inserted] = modules.emplace(candidate.name, &candidate);
            if (!inserted) entry->second = nullptr;
        }
    }
    const auto supported = [](const auto& self, const frontend::StatementSyntax& statement, bool sequential) -> bool {
        using frontend::StatementKind;
        if (statement.kind == StatementKind::Assignment) return statement.nonblocking == sequential;
        const auto nested = [&](const auto& child) { return self(self, child, sequential); };
        if (statement.kind == StatementKind::Case || statement.kind == StatementKind::CaseZ ||
            statement.kind == StatementKind::CaseX) {
            return std::all_of(statement.case_items.begin(), statement.case_items.end(), [&](const auto& arm) {
                return std::all_of(arm.statements.begin(), arm.statements.end(), nested);
            });
        }
        if (statement.kind != StatementKind::If && statement.kind != StatementKind::Block) return false;
        return std::all_of(statement.body.begin(), statement.body.end(), nested) &&
            std::all_of(statement.else_body.begin(), statement.else_body.end(), nested);
    };
    const auto logic = [](const auto& signal) { return signal.type == frontend::ScalarType::Logic; };
    std::vector<std::string> pending{std::string(top)};
    std::set<std::string> validated;
    bool has_clocked_process = false;
    while (!pending.empty()) {
        auto name = std::move(pending.back());
        pending.pop_back();
        if (!validated.insert(name).second) continue;
        const auto found = modules.find(name);
        if (found == modules.end() || !found->second) {
            throw std::invalid_argument("four-state module must resolve uniquely: " + name);
        }
        const auto& module = *found->second;
        if (!module.memories.empty() || !module.generate_items.empty() ||
            (!assertions && (!module.property_checks.empty() || !module.property_declarations.empty() ||
                             !module.sequence_declarations.empty()))) {
            throw std::invalid_argument("unsupported four-state memory, generate, or property in module: " + name);
        }
        if (!std::all_of(module.ports.begin(), module.ports.end(), logic) ||
            !std::all_of(module.signals.begin(), module.signals.end(), logic)) {
            throw std::invalid_argument("four-state ports and internal signals must use logic: " + name);
        }
        for (const auto& process : module.processes) {
            const bool clocked = process.kind == frontend::ProcessKind::AlwaysFF;
            if ((clocked ? !sampled : process.kind != frontend::ProcessKind::AlwaysComb) ||
                !supported(supported, process.body, clocked)) {
                throw std::invalid_argument("four-state processes require supported always_comb or sampled always_ff statements: " + name);
            }
            has_clocked_process |= clocked;
        }
        for (const auto& instance : module.instances) pending.push_back(instance.module_type);
    }
    if (sampled && !assertions && !has_clocked_process) {
        throw std::invalid_argument("sampled four-state output checking requires an always_ff process");
    }
}

Word decode_literal(const TypedExpression& expression) {
    const auto width = static_cast<unsigned>(expression.width);
    std::string text;
    for (unsigned char ch : expression.value) {
        if (ch != '_') text += static_cast<char>(std::tolower(ch));
    }
    const auto quote = text.find('\'');
    if (quote == text.npos) return Word(width, 0, decimal(text));
    if (quote == 0 && text.size() == 2) return Word::parse(text.substr(1)).resized(width, true);
    auto base = quote + 1;
    if (text.at(base) == 's') ++base;
    const auto radix = text.at(base);
    if (radix == 'd') return Word(width, 0, decimal(text.substr(base + 1)));
    const unsigned digit_width = radix == 'b' ? 1 : radix == 'o' ? 3 : radix == 'h' ? 4 : 0;
    if (digit_width == 0 || base + 1 == text.size()) throw std::invalid_argument("invalid four-state radix");
    std::string bits;
    for (auto index = base + 1; index < text.size(); ++index) {
        const auto digit = text[index];
        if (digit == 'x' || digit == 'z' || digit == '?') {
            bits.append(digit_width, digit == '?' ? 'z' : digit);
            continue;
        }
        const auto data = std::string_view("0123456789abcdef").find(digit);
        if (data == std::string_view::npos || data >= (1U << digit_width)) {
            throw std::invalid_argument("digit outside the four-state radix");
        }
        for (auto bit = digit_width; bit > 0; --bit) bits += ((data >> (bit - 1)) & 1) != 0 ? '1' : '0';
    }
    if (bits.size() < width) {
        const auto pad = bits.front() == 'x' || bits.front() == 'z' ? bits.front() : '0';
        bits.insert(0, width - bits.size(), pad);
    }
    return Word::parse(std::string_view(bits).substr(bits.size() - width));
}

std::vector<const lowering::TIREquation*> schedule_combinational(const lowering::TIRModule& model) {
    if (model.semantic_profile != frontend::kFourStateProfile || model.clocks.size() > 1 ||
        (!model.next_state_equations.empty() && model.clocks.empty()) ||
        !model.history_guards.empty()) {
        throw std::invalid_argument("expected a supported single-clock or combinational four-state model");
    }
    if (!model.clocks.empty()) {
        const auto references_clock = [&](const auto& self, const TypedExpression& expression) -> bool {
            if (expression.kind == "signal" && expression.value == model.clocks.front()) return true;
            return std::any_of(expression.operands.begin(), expression.operands.end(),
                [&](const auto& item) { return self(self, item); });
        };
        const auto uses_clock = [&](const auto& equations) {
            return std::any_of(equations.begin(), equations.end(),
                [&](const auto& equation) { return references_clock(references_clock, equation.expression); });
        };
        const auto sequence_uses_clock = [&](const auto& sequence) {
            return std::any_of(sequence.terms.begin(), sequence.terms.end(),
                [&](const auto& term) { return references_clock(references_clock, term.predicate); });
        };
        const bool property_uses_clock = std::any_of(model.properties.begin(), model.properties.end(),
            [&](const auto& property) {
                return sequence_uses_clock(property.antecedent) ||
                    (property.consequent && sequence_uses_clock(*property.consequent));
            });
        if (uses_clock(model.combinational_equations) || uses_clock(model.next_state_equations) || property_uses_clock) {
            throw std::invalid_argument("four-state sampling clock cannot also be used as data");
        }
    }
    std::set<std::string> available;
    for (const auto& signal : model.signals) {
        if (signal.role == "input" || signal.role == "state" || signal.role == "history_data") available.insert(signal.name);
    }
    std::vector<const lowering::TIREquation*> pending, ordered;
    for (const auto& equation : model.combinational_equations) pending.push_back(&equation);
    while (!pending.empty()) {
        auto next = std::remove_if(pending.begin(), pending.end(), [&](const auto* equation) {
            if (!ready(equation->expression, available)) return false;
            if (!available.insert(equation->target).second) {
                throw std::invalid_argument("duplicate four-state equation target");
            }
            ordered.push_back(equation);
            return true;
        });
        if (next == pending.end()) throw std::invalid_argument("unresolved four-state signal dependency");
        pending.erase(next, pending.end());
    }
    for (const auto& signal : model.signals) {
        if (!available.count(signal.name)) throw std::invalid_argument("undriven four-state signal: " + signal.name);
    }
    return ordered;
}

Frame initialized_state(const lowering::TIRModule& model) {
    Frame state;
    for (const auto& signal : model.signals) {
        if (signal.role == "state" || signal.role == "history_data") {
            state.emplace(signal.name, Word(static_cast<unsigned>(signal.width), ~std::uint64_t{0}, 0));
        }
    }
    return state;
}

Frame evaluate_sample(const lowering::TIRModule& model,
                      const std::vector<const lowering::TIREquation*>& ordered,
                      Frame inputs, const Frame& state) {
    std::size_t expected = 0;
    for (const auto& signal : model.signals) {
        if (signal.role != "input") continue;
        ++expected;
        const auto provided = inputs.find(signal.name);
        if (provided == inputs.end() || provided->second.width() != signal.width) {
            throw std::invalid_argument("missing or width-mismatched four-state input: " + signal.name);
        }
    }
    if (inputs.size() != expected) throw std::invalid_argument("unknown or non-input four-state signal supplied");
    auto frame = std::move(inputs);
    frame.insert(state.begin(), state.end());
    for (const auto* equation : ordered) {
        auto value = evaluate(equation->expression, frame);
        if (value.width() != equation->target_width) {
            throw std::invalid_argument("invalid four-state equation width");
        }
        frame.emplace(equation->target, std::move(value));
    }
    return frame;
}

bool predicate_true(const lowering::TypedExpression& predicate, const Frame& frame) {
    return truth(evaluate(predicate, frame)) == Logic::One;
}

Frame advance_state(const lowering::TIRModule& model, const Frame& sample) {
    Frame next;
    for (const auto& equation : model.next_state_equations) {
        auto value = evaluate(equation.expression, sample);
        if (value.width() != equation.target_width || !next.emplace(equation.target, std::move(value)).second) {
            throw std::invalid_argument("invalid four-state next-state equation");
        }
    }
    return next;
}

Frame evaluate_combinational(const lowering::TIRModule& model, Frame inputs) {
    if (!model.clocks.empty()) throw std::invalid_argument("concrete combinational evaluation has no sampling clock");
    return evaluate_sample(model, schedule_combinational(model), std::move(inputs), {});
}

} // namespace q3a::four_state
