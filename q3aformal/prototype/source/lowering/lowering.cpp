#include "state_transition.hpp"
#include "event_mask_source.hpp"
#include "../frontend/decimal_literal.hpp"

#include <algorithm>
#include <charconv>
#include <cctype>
#include <iterator>
#include <limits>
#include <map>
#include <set>
#include <string_view>
#include <utility>

namespace q3a::lowering {
namespace {

std::string json_string(const std::string& value) {
    std::string result = "\"";
    for (const unsigned char ch : value) {
        switch (ch) {
        case '"': result += "\\\""; break;
        case '\\': result += "\\\\"; break;
        case '\b': result += "\\b"; break;
        case '\f': result += "\\f"; break;
        case '\n': result += "\\n"; break;
        case '\r': result += "\\r"; break;
        case '\t': result += "\\t"; break;
        default:
            if (ch < 0x20) {
                static constexpr char hex[] = "0123456789abcdef";
                result += "\\u00";
                result.push_back(hex[ch >> 4]);
                result.push_back(hex[ch & 0x0f]);
            } else {
                result.push_back(static_cast<char>(ch));
            }
        }
    }
    result.push_back('"');
    return result;
}

std::string serialize_expression(const TypedExpression& expression) {
    std::string output = "{\"kind\":" + json_string(expression.kind) +
        ",\"value\":" + json_string(expression.value) +
        ",\"width\":" + std::to_string(expression.width) +
        ",\"signed\":" + (expression.is_signed ? "true" : "false") +
        ",\"source\":{" +
        "\"file\":" + json_string(expression.location.file) +
        ",\"line\":" + std::to_string(expression.location.line) +
        ",\"column\":" + std::to_string(expression.location.column) + "}" +
        ",\"operands\":[";
    for (std::size_t i = 0; i < expression.operands.size(); ++i) {
        if (i != 0) output.push_back(',');
        output += serialize_expression(expression.operands[i]);
    }
    output += "]}";
    return output;
}

bool is_fill_literal(std::string_view text) {
    return text == "'0" || text == "'1" || text == "'x" || text == "'X" ||
        text == "'z" || text == "'Z";
}

std::uint64_t literal_width(const frontend::Token& token) {
    if (is_fill_literal(token.text)) return 1;
    const auto quote = token.text.find('\'');
    if (quote == 0) return 32;
    auto digits = token.text.substr(0, quote);
    digits.erase(std::remove(digits.begin(), digits.end(), '_'), digits.end());
    std::uint64_t width = 0;
    const auto result = std::from_chars(digits.data(),
        digits.data() + digits.size(), width);
    if (result.ec != std::errc{} || result.ptr != digits.data() + digits.size() ||
        width == 0 || width > 64) {
        return 0;
    }
    return width;
}

bool is_unsized_decimal_literal(const TypedExpression& expression) {
    return expression.kind == "literal" &&
        expression.value.find('\'') == std::string::npos;
}

bool is_context_operator(const TypedExpression& expression) {
    const auto& op = expression.value;
    if (expression.kind == "unary" && expression.operands.size() == 1) {
        return op == "+" || op == "-" || op == "~";
    }
    return expression.kind == "binary" && expression.operands.size() == 2 &&
        (op == "+" || op == "-" || op == "*" || op == "/" || op == "%" || op == "&" || op == "|" ||
         op == "^" || op == "~^" || op == "^~");
}

void apply_decimal_evaluation_width(TypedExpression& expression,
                                    std::uint64_t width) {
    if (is_unsized_decimal_literal(expression)) {
        expression.width = std::max(expression.width, width);
    } else if (is_context_operator(expression)) {
        for (auto& operand : expression.operands) {
            apply_decimal_evaluation_width(operand, width);
            expression.width = std::max(expression.width, operand.width);
        }
    }
}

bool is_shift(const TypedExpression& expression) {
    return expression.kind == "binary" && expression.operands.size() == 2 &&
        frontend::is_shift_operator(expression.value);
}

bool is_conditional(const TypedExpression& expression) {
    return expression.kind == "conditional" && expression.operands.size() == 3;
}

bool is_comparison(const TypedExpression& expression) {
    const auto& op = expression.value;
    return expression.kind == "binary" && expression.operands.size() == 2 &&
        (op == "==" || op == "!=" || op == "===" || op == "!==" ||
         op == "==?" || op == "!=?" ||
         op == "<" || op == "<=" || op == ">" || op == ">=");
}

bool has_context_operands(const TypedExpression& expression) {
    return is_context_operator(expression) || is_shift(expression) ||
        is_conditional(expression);
}

void resolve_fill_width(TypedExpression& expression, std::uint64_t width) {
    if (expression.kind == "literal" && is_fill_literal(expression.value)) {
        expression.width = width;
    }
}

// First change the signed interpretation at the original width. Extending
// afterward uses the enclosing expression's sign rules, including zero
// extension of a signed source inside an unsigned expression.
void convert_context_operand(TypedExpression& operand, std::uint64_t width,
                             bool is_signed) {
    const auto location = operand.location;
    if (operand.is_signed != is_signed) {
        const auto source_width = operand.width;
        operand = TypedExpression{"assignment_resize", "expression_type", source_width,
            is_signed, location, {std::move(operand)}};
    }
    if (operand.width != width) {
        operand = TypedExpression{"assignment_resize", "expression_width", width,
            is_signed, location, {std::move(operand)}};
    }
}

void normalize_expression_context(TypedExpression& expression);

void propagate_context_type(TypedExpression& expression, std::uint64_t width,
                            bool is_signed) {
    // The shift count and the conditional predicate have their own type.
    const std::size_t first = is_conditional(expression) ? 1 : 0;
    const auto end = is_shift(expression)
        ? std::size_t{1} : expression.operands.size();
    std::uint64_t operand_width = 0;
    bool operands_signed = true;
    for (std::size_t index = 0; index < expression.operands.size(); ++index) {
        auto& operand = expression.operands[index];
        const bool shares_context = index >= first && index < end;
        if (shares_context && has_context_operands(operand)) {
            propagate_context_type(operand, width, is_signed);
        } else {
            normalize_expression_context(operand);
        }
        if (shares_context) {
            resolve_fill_width(operand, width);
            operand_width = std::max(operand_width, operand.width);
            operands_signed = operands_signed && operand.is_signed;
        }
    }
    if (operand_width != width || operands_signed != is_signed) {
        for (std::size_t index = first; index < end; ++index) {
            convert_context_operand(expression.operands[index], width, is_signed);
        }
    }
    expression.width = width;
    expression.is_signed = is_signed;
}

void normalize_expression_context(TypedExpression& expression) {
    if (has_context_operands(expression)) {
        propagate_context_type(expression, expression.width, expression.is_signed);
        return;
    }
    if (is_comparison(expression)) {
        auto& left = expression.operands[0];
        auto& right = expression.operands[1];
        const auto width = std::max(left.width, right.width);
        const bool is_signed = left.is_signed && right.is_signed;
        for (auto& operand : expression.operands) {
            if (has_context_operands(operand)) {
                propagate_context_type(operand, width, is_signed);
            } else {
                normalize_expression_context(operand);
                resolve_fill_width(operand, width);
            }
        }
        return;
    }
    for (auto& operand : expression.operands) normalize_expression_context(operand);
}

TypedExpression resize_assignment(TypedExpression expression, std::uint64_t width,
                                  bool is_signed) {
    if (expression.width == width) return expression;
    return TypedExpression{"assignment_resize", "assignment", width,
        is_signed, expression.location,
        {std::move(expression)}};
}

TypedExpression select_normalized_bit(TypedExpression value, std::uint64_t offset,
                                      const frontend::SourceLocation& location) {
    TypedExpression position{"constant", std::to_string(offset), 32, false, location, {}};
    return TypedExpression{"select", "bit", 1, false, location, {std::move(value), std::move(position)}};
}

TypedExpression lower_bit_vector_assertion(const frontend::Token& function, TypedExpression value) {
    const auto& location = function.location;
    const auto width = value.width;
    if (width == 0 || width > 64) {
        throw LoweringError(location, "bit-vector assertion operand width must be in 1..64",
                            frontend::InputDiagnosticKind::Unsupported);
    }
    const bool count = function.text == "$countones";
    return TypedExpression{"bit_vector_function", function.text, count ? 32U : 1U,
                           count, location, {std::move(value)}};
}

TypedExpression lower_boolean_condition(TypedExpression expression) {
    if (expression.width == 1) return expression;
    const auto location = expression.location;
    TypedExpression zero{"literal", "0", expression.width, expression.is_signed, location, {}};
    return TypedExpression{"binary", "!=", 1, false, location,
        {std::move(expression), std::move(zero)}};
}

int operator_precedence(const std::string& op) {
    if (op == "||") return 1;
    if (op == "&&") return 2;
    if (op == "|") return 3;
    if (op == "^" || op == "~^" || op == "^~") return 4;
    if (op == "&") return 5;
    if (op == "==" || op == "!=" || op == "===" || op == "!==" ||
        op == "==?" || op == "!=?") return 6;
    if (op == "<" || op == "<=" || op == ">" || op == ">=") return 7;
    if (frontend::is_shift_operator(op)) return 8;
    if (op == "+" || op == "-") return 9;
    if (op == "*" || op == "/" || op == "%") return 10;
    return -1;
}

class ExpressionParser {
public:
    ExpressionParser(
        const std::vector<frontend::Token>& tokens,
        frontend::ExpressionSpan span,
        const std::map<std::string, TIRSignal>& signals,
        const std::map<std::string, TIRConstant>& constants,
        std::uint64_t context_width, bool four_state = false)
        : tokens_(tokens), index_(span.first_token), end_(span.after_last_token),
          signals_(signals), constants_(constants), context_width_(context_width), four_state_(four_state) {}

    TypedExpression parse_raw() {
        if (index_ >= end_) fail("empty right-hand-side expression");
        auto expression = parse_expression();
        if (index_ != end_) {
            fail("unexpected token in expression: '" + tokens_[index_].text + "'");
        }
        apply_decimal_evaluation_width(expression, context_width_);
        return expression;
    }

    TypedExpression parse(bool assignment = false) {
        auto expression = parse_raw();
        if (assignment) resolve_fill_width(expression, context_width_);
        if (assignment && has_context_operands(expression)) {
            propagate_context_type(expression, std::max(expression.width, context_width_),
                                   expression.is_signed);
        } else {
            normalize_expression_context(expression);
        }
        return expression;
    }

    std::int64_t evaluate_constant_integer(
        const TypedExpression& expression) const {
        return constant_integer(expression);
    }

    std::uint64_t evaluate_nonnegative_constant(const TypedExpression& expression,
                                                const std::string& description) const {
        const auto bits = evaluate_bound_bits(expression);
        if (expression.is_signed && ((bits >> (expression.width - 1)) & 1U) != 0) {
            throw LoweringError(expression.location, description + " must be nonnegative");
        }
        return bits;
    }

private:
    const frontend::Token& current() const { return tokens_[index_]; }
    bool at(const std::string& text) const {
        return index_ < end_ && current().text == text;
    }
    bool accept(const std::string& text) {
        if (!at(text)) return false;
        ++index_;
        return true;
    }
    const frontend::Token& advance() {
        const auto& token = current();
        if (index_ < end_) ++index_;
        return token;
    }
    [[noreturn]] void fail(const std::string& message) const {
        const auto safe_index = std::min(index_, tokens_.size() - 1);
        throw LoweringError(tokens_[safe_index].location, message);
    }

    TypedExpression parse_expression(int minimum_precedence = 0) {
        auto left = parse_unary();
        for (;;) {
            const auto op = index_ < end_ ? current().text : std::string{};
            const auto precedence = operator_precedence(op);
            if (precedence < minimum_precedence) break;
            const auto op_token = advance();
            auto right = parse_expression(precedence + 1);
            const bool predicate = op == "&&" || op == "||" || op == "==" ||
                op == "!=" || op == "===" || op == "!==" ||
                op == "==?" || op == "!=?" ||
                op == "<" || op == "<=" || op == ">" || op == ">=";
            const bool shift = frontend::is_shift_operator(op);
            const auto width = predicate ? std::uint64_t{1}
                : (shift ? left.width : std::max(left.width, right.width));
            const auto is_signed = shift ? left.is_signed
                : (!predicate && left.is_signed && right.is_signed);
            left = TypedExpression{"binary", op, width, is_signed,
                op_token.location, {std::move(left), std::move(right)}};
        }
        if (minimum_precedence == 0 && accept("?")) {
            auto when_true = parse_expression();
            if (!accept(":")) fail("expected ':' in conditional expression");
            auto when_false = parse_expression();
            const auto width = std::max(when_true.width, when_false.width);
            const bool is_signed = when_true.is_signed && when_false.is_signed;
            left = TypedExpression{"conditional", "?:", width, is_signed,
                left.location, {std::move(left), std::move(when_true),
                                std::move(when_false)}};
        }
        return left;
    }

    TypedExpression parse_unary() {
        if (at("+") || at("-") || at("!") || at("~") ||
            (index_ < end_ && frontend::is_reduction_operator(current().text))) {
            const auto op = advance();
            auto operand = parse_unary();
            const bool logical = op.text == "!" || frontend::is_reduction_operator(op.text);
            return TypedExpression{"unary", op.text,
                logical ? 1 : operand.width,
                !logical && operand.is_signed, op.location,
                {std::move(operand)}};
        }
        return parse_primary();
    }

    TypedExpression parse_primary() {
        if (index_ >= end_) fail("expected expression operand");
        const auto token = current();
        if (token.kind == frontend::TokenKind::Number) {
            advance();
            if (token.text.find('\'') == std::string::npos) {
                const auto decimal = frontend::decode_unsized_decimal(token.text);
                if (!decimal) {
                    throw LoweringError(token.location,
                        "unsized decimal literal exceeds the supported signed 64-bit range");
                }
                return TypedExpression{"literal", std::to_string(decimal->value),
                    decimal->width, true, token.location, {}};
            }
            const auto width = literal_width(token);
            if (width == 0) {
                throw LoweringError(token.location,
                    "literal width is outside the Phase 0 lowering limit");
            }
            const auto quote = token.text.find('\'');
            bool is_signed = quote == std::string::npos;
            if (quote != std::string::npos && quote + 1 < token.text.size() &&
                (token.text[quote + 1] == 's' || token.text[quote + 1] == 'S')) {
                is_signed = true;
            }
            return TypedExpression{"literal", token.text, width, is_signed,
                                   token.location, {}};
        }
        if (token.kind == frontend::TokenKind::Identifier) {
            advance();
            if (token.text == "$past") {
                if (!accept("(")) {
                    throw LoweringError(token.location,
                        "expected '(' after $past");
                }
                auto operand = parse_expression();
                std::int64_t delay = 1;
                if (accept(",")) {
                    auto delay_expression = parse_expression();
                    delay = constant_integer(delay_expression);
                }
                if (!accept(")")) {
                    throw LoweringError(token.location,
                        "expected ')' after $past arguments");
                }
                if (delay <= 0) {
                    throw LoweringError(token.location,
                        "$past delay must be a positive compile-time constant");
                }
                return TypedExpression{"past", std::to_string(delay),
                    operand.width, operand.is_signed, token.location,
                    {std::move(operand)}};
            }
            const bool bit_vector_function = frontend::is_bit_vector_assertion_function(token.text);
            if (bit_vector_function || frontend::is_sampled_value_function(token.text)) {
                if (!accept("(")) fail("expected '(' after assertion function");
                auto value = parse_expression();
                if (!accept(")")) fail("expected ')' after assertion function operand");
                if (bit_vector_function) return lower_bit_vector_assertion(token, std::move(value));
                const bool edge = token.text == "$rose" || token.text == "$fell";
                if (edge && value.width > 1) {
                    value = select_normalized_bit(std::move(value), 0, token.location);
                }
                TypedExpression previous{"past", "1", value.width, value.is_signed, token.location, {value}};
                if (four_state_) {
                    if (!edge) {
                        return TypedExpression{"binary", token.text == "$stable" ? "===" : "!==",
                            1, false, token.location, {std::move(value), std::move(previous)}};
                    }
                    const auto desired = token.text == "$rose" ? "1'b1" : "1'b0";
                    TypedExpression bit{"literal", desired, 1, false, token.location, {}};
                    TypedExpression now{"binary", "===", 1, false, token.location, {std::move(value), bit}};
                    TypedExpression changed{"binary", "!==", 1, false, token.location,
                        {std::move(previous), std::move(bit)}};
                    return TypedExpression{"binary", "&&", 1, false, token.location,
                        {std::move(now), std::move(changed)}};
                }
                if (!edge) {
                    return TypedExpression{"binary", token.text == "$stable" ? "==" : "!=",
                        1, false, token.location, {std::move(value), std::move(previous)}};
                }
                const bool rising = token.text == "$rose";
                auto high = rising ? std::move(value) : std::move(previous);
                auto low = rising ? std::move(previous) : std::move(value);
                TypedExpression inverted{"unary", "!", 1, false, token.location, {std::move(low)}};
                return TypedExpression{"binary", "&&", 1, false, token.location,
                                       {std::move(high), std::move(inverted)}};
            }
            const auto signal = signals_.find(token.text);
            const auto constant = constants_.find(token.text);
            TypedExpression expression;
            if (signal != signals_.end()) {
                expression = TypedExpression{"signal", token.text,
                    signal->second.width, signal->second.is_signed,
                    token.location, {}};
            } else if (constant != constants_.end()) {
                expression = TypedExpression{"constant",
                    elaboration::integral_value_text(constant->second.value, constant->second.is_signed),
                    constant->second.width,
                    constant->second.is_signed, token.location, {}};
            } else {
                throw LoweringError(token.location,
                    "unresolved expression name '" + token.text + "'");
            }
            while (accept("[")) {
                const auto select_location = tokens_[index_ - 1].location;
                const bool constant_vector = expression.kind == "constant" && constant != constants_.end();
                if (expression.kind != "signal" && !constant_vector) {
                    throw LoweringError(select_location,
                        "nested or constant-expression selects are outside the Phase 0 subset");
                }
                std::optional<frontend::PackedBounds> bounds;
                if (constant_vector) {
                    bounds = constant->second.packed_bounds;
                } else if (signal->second.packed_left_index && signal->second.packed_right_index) {
                    bounds.emplace(*signal->second.packed_left_index, *signal->second.packed_right_index);
                }
                if (!bounds) {
                    throw LoweringError(select_location,
                        "bit/part select requires a declared packed vector with known bounds");
                }
                auto index = parse_expression();
                std::optional<std::int64_t> last;
                if (accept(":")) last = constant_integer(parse_expression());
                std::string indexed_direction;
                std::int64_t indexed_width = 1;
                if (four_state_ && (at("+:") || at("-:"))) {
                    indexed_direction = advance().text;
                    indexed_width = constant_integer(parse_expression());
                    if (indexed_width <= 0 || indexed_width > 64) {
                        throw LoweringError(select_location, "indexed part-select width must be 1..64");
                    }
                }
                if (!accept("]")) {
                    throw LoweringError(select_location,
                        "expected ']' after select expression");
                }
                const auto indexed_read = [&] {
                    normalize_expression_context(index);
                    const auto bound = [&](std::int64_t value) {
                        return TypedExpression{"constant", std::to_string(value), 64, true,
                            select_location, {}};
                    };
                    if (index_ < end_ && current().text == "[") {
                        throw LoweringError(select_location, "nested variable selects are outside the four-state subset");
                    }
                    const bool part = !indexed_direction.empty();
                    return TypedExpression{part ? "indexed_part" : "indexed_bit", part ? indexed_direction : "packed",
                        static_cast<std::uint64_t>(indexed_width), false, select_location,
                        {std::move(expression), std::move(index), bound(bounds->first), bound(bounds->second)}};
                };
                if (!indexed_direction.empty()) return indexed_read();
                frontend::PackedSelection selected{};
                try {
                    const auto first = constant_integer(index);
                    selected = frontend::resolve_packed_select(*bounds, expression.width, first, last);
                } catch (const LoweringError&) {
                    if (!four_state_ || last) throw;
                    return indexed_read();
                } catch (const std::invalid_argument& error) {
                    if (four_state_ && !last) return indexed_read();
                    throw LoweringError(select_location, error.what());
                }
                if (constant_vector) {
                    const auto bits = static_cast<std::uint64_t>(constant->second.value) >> selected.offset;
                    expression = TypedExpression{"constant", std::to_string(bits & bound_mask(selected.width)),
                        selected.width, false, select_location, {}};
                    if (index_ < end_ && current().text == "[") {
                        throw LoweringError(current().location, "nested selects are outside the Phase 0 subset");
                    }
                    continue;
                }
                TypedExpression source_position{"constant",
                    std::to_string(selected.offset), 32, false,
                    select_location, {}};
                std::vector<TypedExpression> operands;
                operands.push_back(std::move(expression));
                operands.push_back(std::move(source_position));
                expression = TypedExpression{"select", last ? "part" : "bit", selected.width, false,
                    select_location, std::move(operands)};
            }
            return expression;
        }
        if (accept("(")) {
            auto expression = parse_expression();
            if (!accept(")")) fail("expected ')' after expression");
            return expression;
        }
        if (accept("{")) {
            const auto location = tokens_[index_ - 1].location;
            std::vector<TypedExpression> operands;
            std::uint64_t width = 0;
            do {
                auto item = parse_expression();
                if (is_unsized_decimal_literal(item)) {
                    throw LoweringError(item.location,
                        "unsized decimal concatenation member requires an explicit width");
                }
                if (width > std::numeric_limits<std::uint64_t>::max() - item.width) {
                    throw LoweringError(location,
                        "concatenation width overflows the lowering limit");
                }
                width += item.width;
                operands.push_back(std::move(item));
            } while (accept(","));
            if (!accept("}")) fail("expected '}' after concatenation");
            return TypedExpression{"concatenation", "{}", width, false,
                                   location, std::move(operands)};
        }
        throw LoweringError(token.location,
            "unsupported expression operand '" + token.text + "'");
    }

    static std::uint64_t bound_mask(std::uint64_t width) {
        return width == 64 ? std::numeric_limits<std::uint64_t>::max() :
            (std::uint64_t{1} << width) - 1;
    }

    static std::uint64_t extend_bound(std::uint64_t bits, std::uint64_t width,
                                      bool sign_extend) {
        if (sign_extend && ((bits >> (width - 1)) & 1U) != 0) {
            bits |= ~bound_mask(width);
        }
        return bits;
    }

    static std::uint64_t evaluate_bound_bits(const TypedExpression& expression) {
        if (expression.width == 0 || expression.width > 64) {
            throw LoweringError(expression.location, "constant bound width must be 1 through 64");
        }
        const auto mask = bound_mask(expression.width);
        if (expression.kind == "concatenation") {
            std::uint64_t packed = 0;
            for (const auto& operand : expression.operands) {
                if (is_unsized_decimal_literal(operand)) {
                    throw LoweringError(operand.location,
                        "unsized decimal concatenation member requires an explicit width");
                }
                const auto bits = evaluate_bound_bits(operand);
                packed = operand.width == 64 ? bits : (packed << operand.width) | bits;
            }
            return packed & mask;
        }
        if (expression.kind == "assignment_resize" && expression.operands.size() == 1) {
            const auto& operand = expression.operands.front();
            return extend_bound(evaluate_bound_bits(operand), operand.width, operand.is_signed) & mask;
        }
        const auto& op = expression.value;
        if (expression.kind == "bit_vector_function") {
            auto bits = evaluate_bound_bits(expression.operands.front());
            unsigned count = 0;
            while (bits != 0) {
                count += bits & 1U;
                bits >>= 1;
            }
            if (op == "$countones") return count;
            return op == "$onehot" ? count == 1 : count <= 1;
        }
        const auto operand_bits = [&](const TypedExpression& operand) {
            return extend_bound(evaluate_bound_bits(operand), operand.width, expression.is_signed);
        };
        if (is_conditional(expression)) {
            const auto condition = evaluate_bound_bits(expression.operands[0]);
            const auto when_true = operand_bits(expression.operands[1]);
            const auto when_false = operand_bits(expression.operands[2]);
            return (condition != 0 ? when_true : when_false) & mask;
        }
        if (expression.kind == "unary" && expression.operands.size() == 1) {
            if (op == "!") return evaluate_bound_bits(expression.operands.front()) == 0;
            const auto value = operand_bits(expression.operands.front());
            if (op == "+") return value & mask;
            if (op == "-") return (std::uint64_t{0} - value) & mask;
            if (op == "~") return ~value & mask;
        }
        if (expression.kind == "binary" && expression.operands.size() == 2) {
            const auto& left = expression.operands[0];
            const auto& right = expression.operands[1];
            if (op == "&&" || op == "||") {
                const bool a = evaluate_bound_bits(left) != 0;
                const bool b = evaluate_bound_bits(right) != 0;
                return op == "&&" ? a && b : a || b;
            }
            if (is_comparison(expression)) {
                const auto left_bits = evaluate_bound_bits(left);
                const auto right_bits = evaluate_bound_bits(right);
                const auto width = std::max(left.width, right.width);
                const bool is_signed = left.is_signed && right.is_signed;
                // Flipping the sign bit puts signed values in unsigned order.
                const auto sign_bit = is_signed ? (std::uint64_t{1} << (width - 1)) : 0;
                const auto ordered = [&](const TypedExpression& operand, std::uint64_t raw) {
                    const auto bits = extend_bound(raw, operand.width, is_signed);
                    return (bits & bound_mask(width)) ^ sign_bit;
                };
                const auto a = ordered(left, left_bits);
                const auto b = ordered(right, right_bits);
                if (op == "==" || op == "===" || op == "==?") return a == b;
                if (op == "!=" || op == "!==" || op == "!=?") return a != b;
                if (op == "<") return a < b;
                if (op == "<=") return a <= b;
                if (op == ">") return a > b;
                return a >= b;
            }
            const auto a = operand_bits(left) & mask;
            if (is_shift(expression)) {
                const auto distance = evaluate_bound_bits(right);
                if (right.is_signed && ((distance >> (right.width - 1)) & 1U) != 0) {
                    throw LoweringError(right.location, "negative constant shift distances are unsupported");
                }
                const bool sign_fill = op == ">>>" && expression.is_signed &&
                    ((a >> (expression.width - 1)) & 1U) != 0;
                if (distance >= expression.width) return sign_fill ? mask : 0;
                if (op.front() == '<') return (a << distance) & mask;
                const auto vacated = sign_fill ? mask ^ (mask >> distance) : 0;
                return (a >> distance) | vacated;
            }
            const auto b = operand_bits(right) & mask;
            if (op == "+") return (a + b) & mask;
            if (op == "-") return (a - b) & mask;
            if (op == "*") return (a * b) & mask;
            if (op == "/" || op == "%") {
                if (b == 0) throw LoweringError(expression.location, "division by zero in constant bound");
                const auto sign = expression.is_signed ? std::uint64_t{1} << (expression.width - 1) : 0;
                const bool negative_a = (a & sign) != 0;
                const bool negative_b = (b & sign) != 0;
                const auto magnitude_a = negative_a ? (-a & mask) : a;
                const auto magnitude_b = negative_b ? (-b & mask) : b;
                if (op == "%") {
                    const auto result = magnitude_a % magnitude_b;
                    return negative_a ? (-result & mask) : result;
                }
                const auto result = magnitude_a / magnitude_b;
                return negative_a != negative_b ? (-result & mask) : result;
            }
            if (op == "&") return a & b;
            if (op == "|") return a | b;
            if (op == "^") return a ^ b;
            if (op == "~^" || op == "^~") return ~(a ^ b) & mask;
        }
        if (expression.kind == "literal" || expression.kind == "constant") {
            if (expression.value == "'0") return 0;
            if (expression.value == "'1") return mask;
            auto text = expression.value;
            int base = 10;
            const auto quote = text.find('\'');
            if (quote != std::string::npos) {
                auto radix = quote + 1;
                if (radix < text.size() && (text[radix] == 's' || text[radix] == 'S')) ++radix;
                if (radix < text.size()) {
                    const auto marker = static_cast<char>(std::tolower(
                        static_cast<unsigned char>(text[radix])));
                    base = marker == 'b' ? 2 : marker == 'o' ? 8 :
                           marker == 'd' ? 10 : marker == 'h' ? 16 : 0;
                    text.erase(0, radix + 1);
                } else {
                    base = 0;
                }
            }
            text.erase(std::remove(text.begin(), text.end(), '_'), text.end());
            const bool negative = !text.empty() && text.front() == '-';
            if (negative) text.erase(0, 1);
            if (base != 0) {
                std::uint64_t raw = 0;
                const auto parsed = std::from_chars(text.data(), text.data() + text.size(), raw, base);
                if (parsed.ec == std::errc{} && parsed.ptr == text.data() + text.size()) {
                    return (negative ? std::uint64_t{0} - raw : raw) & mask;
                }
            }
        }
        throw LoweringError(expression.location,
            "part-select bounds must be supported constant expressions in this T016 prototype");
    }

    static std::int64_t constant_integer(TypedExpression expression) {
        // Select indices and history delays have their own expression context.
        normalize_expression_context(expression);
        const auto raw = evaluate_bound_bits(expression);
        const auto extended = extend_bound(raw, expression.width, expression.is_signed);
        constexpr auto max_signed = static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max());
        if (extended <= max_signed) return static_cast<std::int64_t>(extended);
        if (expression.is_signed) return -1 - static_cast<std::int64_t>(~extended);
        throw LoweringError(expression.location, "constant bound exceeds the signed 64-bit index range");
    }

    const std::vector<frontend::Token>& tokens_;
    std::size_t index_;
    std::size_t end_;
    const std::map<std::string, TIRSignal>& signals_;
    const std::map<std::string, TIRConstant>& constants_;
    std::uint64_t context_width_;
    bool four_state_;
};

void collect_process_targets(const frontend::StatementSyntax& statement,
                             const std::vector<frontend::Token>& tokens,
                             std::set<std::string>& targets) {
    if (statement.kind == frontend::StatementKind::Assignment) {
        if (!statement.lvalue ||
            statement.lvalue->after_last_token !=
                statement.lvalue->first_token + 1 ||
            statement.lvalue->first_token >= tokens.size() ||
            tokens[statement.lvalue->first_token].kind !=
                frontend::TokenKind::Identifier) {
            throw LoweringError(statement.location,
                "T016 prototype currently lowers only whole-signal process targets");
        }
        targets.insert(tokens[statement.lvalue->first_token].text);
    }
    for (const auto& child : statement.body) {
        collect_process_targets(child, tokens, targets);
    }
    for (const auto& child : statement.else_body) {
        collect_process_targets(child, tokens, targets);
    }
    for (const auto& item : statement.case_items) {
        for (const auto& child : item.statements) {
            collect_process_targets(child, tokens, targets);
        }
    }
}

void collect_process_target_locations(
    const frontend::StatementSyntax& statement,
    const std::vector<frontend::Token>& tokens,
    std::map<std::string, frontend::SourceLocation>& locations) {
    if (statement.kind == frontend::StatementKind::Assignment &&
        statement.lvalue &&
        statement.lvalue->after_last_token ==
            statement.lvalue->first_token + 1 &&
        statement.lvalue->first_token < tokens.size() &&
        tokens[statement.lvalue->first_token].kind ==
            frontend::TokenKind::Identifier) {
        locations.emplace(tokens[statement.lvalue->first_token].text,
                          statement.location);
    }
    for (const auto& child : statement.body) {
        collect_process_target_locations(child, tokens, locations);
    }
    for (const auto& child : statement.else_body) {
        collect_process_target_locations(child, tokens, locations);
    }
    for (const auto& item : statement.case_items) {
        for (const auto& child : item.statements) {
            collect_process_target_locations(child, tokens, locations);
        }
    }
}

std::vector<TypedExpression> lower_case_conditions(
    const frontend::StatementSyntax& statement,
    const std::vector<frontend::Token>& tokens,
    const std::map<std::string, TIRSignal>& signals,
    const std::map<std::string, TIRConstant>& constants, bool four_state);

TypedExpression lower_process_statement(
    const frontend::StatementSyntax& statement,
    const std::string& target,
    const TIRSignal& target_signal,
    const std::vector<frontend::Token>& tokens,
    const std::map<std::string, TIRSignal>& signals,
    const std::map<std::string, TIRConstant>& constants,
    TypedExpression fallback, bool four_state = false) {
    if (statement.kind == frontend::StatementKind::Assignment) {
        const auto& target_token = tokens[statement.lvalue->first_token];
        if (target_token.text != target) return fallback;
        if (!statement.nonblocking) {
            throw LoweringError(statement.location,
                "always_ff assignments must use nonblocking '<=' in this T016 slice");
        }
        if (!statement.assignment) {
            throw LoweringError(statement.location,
                                   "process assignment has no right-hand expression");
        }
        auto value = ExpressionParser(tokens, *statement.assignment, signals,
            constants, target_signal.width, four_state).parse(true);
        return resize_assignment(std::move(value), target_signal.width, target_signal.is_signed);
    }
    if (statement.kind == frontend::StatementKind::Block) {
        auto result = std::move(fallback);
        for (const auto& child : statement.body) {
            result = lower_process_statement(child, target, target_signal, tokens,
                signals, constants, std::move(result), four_state);
        }
        return result;
    }
    if (statement.kind == frontend::StatementKind::If) {
        if (!statement.expression || statement.body.size() != 1 ||
            statement.else_body.size() > 1) {
            throw LoweringError(statement.location,
                "malformed if/else statement in process tree");
        }
        auto condition = lower_boolean_condition(ExpressionParser(tokens,
            *statement.expression, signals, constants, 0, four_state).parse());
        auto then_value = lower_process_statement(statement.body.front(), target,
            target_signal, tokens, signals, constants, fallback, four_state);
        auto else_value = fallback;
        if (!statement.else_body.empty()) {
            else_value = lower_process_statement(statement.else_body.front(), target,
                target_signal, tokens, signals, constants, std::move(else_value), four_state);
        }
        return TypedExpression{"conditional", "if", target_signal.width,
            target_signal.is_signed, statement.location,
            {std::move(condition), std::move(then_value), std::move(else_value)}};
    }
    if (statement.kind == frontend::StatementKind::Case ||
        statement.kind == frontend::StatementKind::CaseZ ||
        statement.kind == frontend::StatementKind::CaseX) {
        if (!statement.expression || statement.case_items.empty()) {
            throw LoweringError(statement.location,
                "malformed case statement in always_ff tree");
        }
        auto conditions = lower_case_conditions(statement, tokens, signals, constants, four_state);
        std::optional<TypedExpression> default_value;
        std::vector<std::pair<TypedExpression, TypedExpression>> arms;
        for (std::size_t index = 0; index < statement.case_items.size(); ++index) {
            const auto& item = statement.case_items[index];
            frontend::StatementSyntax item_block;
            item_block.kind = frontend::StatementKind::Block;
            item_block.location = item.location;
            item_block.body = item.statements;
            auto item_value = lower_process_statement(item_block, target,
                target_signal, tokens, signals, constants, fallback, four_state);
            if (item.is_default) {
                if (default_value) {
                    throw LoweringError(item.location,
                        "case statement contains multiple default items");
                }
                default_value = std::move(item_value);
            } else {
                arms.emplace_back(std::move(conditions[index]), std::move(item_value));
            }
        }
        auto result = default_value ? std::move(*default_value) : fallback;
        for (auto arm = arms.rbegin(); arm != arms.rend(); ++arm) {
            result = TypedExpression{"conditional", "case",
                target_signal.width, target_signal.is_signed,
                statement.location,
                {arm->first, arm->second, std::move(result)}};
        }
        return result;
    }
    throw LoweringError(statement.location,
        "T016 sequential lowering requires a supported assignment, block, if/else, or case");
}

struct CombinationalEnvironment {
    std::map<std::string, TypedExpression> values;
    std::map<std::string, bool> assigned;
};

TypedExpression substitute_process_values(
    const TypedExpression& expression,
    const CombinationalEnvironment& environment) {
    if (expression.kind == "signal") {
        const auto value = environment.values.find(expression.value);
        if (value != environment.values.end()) {
            auto captured = value->second;
            // Reading the variable uses its declaration type and the value
            // already evaluated by the earlier blocking assignment.
            convert_context_operand(captured, expression.width, expression.is_signed);
            return captured;
        }
    }
    auto result = expression;
    for (auto& operand : result.operands) {
        operand = substitute_process_values(operand, environment);
    }
    return result;
}

TypedExpression lower_process_expression(
    const frontend::ExpressionSpan& span,
    const std::vector<frontend::Token>& tokens,
    const std::map<std::string, TIRSignal>& signals,
    const std::map<std::string, TIRConstant>& constants,
    const CombinationalEnvironment& environment,
    std::uint64_t context_width,
    bool assignment, bool four_state) {
    auto expression = ExpressionParser(tokens, span, signals, constants,
        context_width, four_state).parse(assignment);
    return substitute_process_values(expression, environment);
}

CombinationalEnvironment merge_combinational_environments(
    const TypedExpression& condition,
    const CombinationalEnvironment& when_true,
    const CombinationalEnvironment& when_false,
    const frontend::SourceLocation& location) {
    CombinationalEnvironment result;
    for (const auto& [name, false_value] : when_false.values) {
        const auto true_value = when_true.values.find(name);
        if (true_value == when_true.values.end()) {
            throw LoweringError(location,
                "inconsistent procedural symbol state while lowering always_comb");
        }
        if (serialize_expression(true_value->second) ==
            serialize_expression(false_value)) {
            result.values.emplace(name, false_value);
        } else {
            result.values.emplace(name, TypedExpression{"conditional", "if",
                true_value->second.width, true_value->second.is_signed, location,
                {condition, true_value->second, false_value}});
        }
        const auto true_assigned = when_true.assigned.find(name);
        const auto false_assigned = when_false.assigned.find(name);
        if (true_assigned == when_true.assigned.end() ||
            false_assigned == when_false.assigned.end()) {
            throw LoweringError(location,
                "inconsistent assignment state while lowering always_comb");
        }
        result.assigned.emplace(name,
            true_assigned->second && false_assigned->second);
    }
    return result;
}

bool is_constant_expression(const TypedExpression& expression) {
    if (expression.kind == "literal" || expression.kind == "constant") {
        return true;
    }
    if (expression.kind != "unary" && expression.kind != "binary" &&
        expression.kind != "conditional") {
        return false;
    }
    return std::all_of(expression.operands.begin(), expression.operands.end(),
        [](const TypedExpression& operand) {
            return is_constant_expression(operand);
        });
}

TypedExpression lower_casez_match(
    const TypedExpression& selector,
    const frontend::ExpressionSpan& label_span,
    const std::vector<frontend::Token>& tokens,
    const frontend::SourceLocation& location, bool four_state) {
    if (label_span.after_last_token != label_span.first_token + 1 ||
        label_span.first_token >= tokens.size() ||
        tokens[label_span.first_token].kind != frontend::TokenKind::Number) {
        throw LoweringError(location,
            "casez labels must be sized unsigned based literal patterns");
    }
    const auto& token = tokens[label_span.first_token];
    const auto quote = token.text.find('\'');
    if (quote == std::string::npos || quote == 0 || quote + 2 >= token.text.size()) {
        throw LoweringError(token.location,
            "casez pattern must have an explicit width and radix");
    }
    const auto radix = static_cast<char>(std::tolower(
        static_cast<unsigned char>(token.text[quote + 1])));
    const unsigned bits_per_digit = radix == 'b' ? 1 : radix == 'o' ? 3 : radix == 'h' ? 4 : 0;
    if (bits_per_digit == 0) {
        throw LoweringError(token.location,
            "casez wildcard patterns must use unsigned binary, octal, or hexadecimal literals");
    }
    const auto width = literal_width(token);
    if (width == 0 || width != selector.width || width > 64) {
        throw LoweringError(token.location,
            "casez pattern width must exactly match its selector (maximum 64 bits)");
    }
    if (four_state) {
        return TypedExpression{"casez_match", "four-state-z-wildcard", 1, false, location,
            {selector, TypedExpression{"literal", token.text, width, false, token.location, {}}}};
    }
    std::string digits = token.text.substr(quote + 2);
    digits.erase(std::remove(digits.begin(), digits.end(), '_'), digits.end());
    if (digits.empty()) {
        throw LoweringError(token.location,
            "casez pattern has no digits");
    }
    std::uint64_t pattern = 0;
    std::uint64_t mask = 0;
    const auto digit_mask = (1U << bits_per_digit) - 1;
    for (const auto raw_digit : digits) {
        const auto digit = static_cast<char>(std::tolower(static_cast<unsigned char>(raw_digit)));
        pattern <<= bits_per_digit;
        mask <<= bits_per_digit;
        if (digit == '?' || digit == 'z') continue;
        const auto value = digit >= '0' && digit <= '9' ? digit - '0' :
            digit >= 'a' && digit <= 'f' ? digit - 'a' + 10 : -1;
        if (value < 0 || static_cast<unsigned>(value) > digit_mask) {
            throw LoweringError(token.location,
                "casez pattern digit must match its radix or be Z or ?; X is unsupported");
        }
        pattern |= static_cast<unsigned>(value);
        mask |= digit_mask;
    }
    const auto width_mask = width == 64 ? std::numeric_limits<std::uint64_t>::max() :
        (std::uint64_t{1} << width) - 1;
    // Size the pattern before comparing it. A leading wildcard pads with
    // wildcards, whereas a leading known digit pads with significant zeros.
    if (digits.size() <= (width - 1) / bits_per_digit &&
        digits.front() != '?' && digits.front() != 'z' && digits.front() != 'Z') {
        const auto provided_bits = digits.size() * bits_per_digit;
        mask |= width_mask & ~((std::uint64_t{1} << provided_bits) - 1);
    }
    pattern &= width_mask;
    mask &= width_mask;
    TypedExpression pattern_value{"literal", std::to_string(pattern), width,
        false, token.location, {}};
    TypedExpression significant_mask{"literal", std::to_string(mask), width,
        false, token.location, {}};
    return TypedExpression{"casez_match", "masked-equality", 1, false,
        location, {selector, std::move(pattern_value), std::move(significant_mask)}};
}

std::vector<TypedExpression> lower_case_conditions(
    const frontend::StatementSyntax& statement,
    const std::vector<frontend::Token>& tokens,
    const std::map<std::string, TIRSignal>& signals,
    const std::map<std::string, TIRConstant>& constants, bool four_state) {
    const bool casez = statement.kind == frontend::StatementKind::CaseZ;
    const bool casex = statement.kind == frontend::StatementKind::CaseX;
    auto selector = ExpressionParser(tokens, *statement.expression,
        signals, constants, 0, four_state).parse_raw();
    auto width = selector.width;
    auto is_signed = selector.is_signed;
    std::vector<std::vector<TypedExpression>> labels(statement.case_items.size());
    if (!casez) {
        // The selector and all labels, including labels in other arms, share
        // one comparison width and signedness.
        for (std::size_t index = 0; index < statement.case_items.size(); ++index) {
            for (const auto& span : statement.case_items[index].labels) {
                auto label = ExpressionParser(tokens, span, signals, constants, 0,
                                              four_state && casex).parse_raw();
                if (!casex && !is_constant_expression(label)) {
                    throw LoweringError(label.location, "case labels must be constant expressions");
                }
                width = std::max(width, label.width);
                is_signed = is_signed && label.is_signed;
                labels[index].push_back(std::move(label));
            }
        }
    }
    const auto apply_case_context = [&](TypedExpression& expression) {
        if (has_context_operands(expression)) {
            propagate_context_type(expression, width, is_signed);
        } else {
            normalize_expression_context(expression);
            resolve_fill_width(expression, width);
            convert_context_operand(expression, width, is_signed);
        }
    };
    apply_case_context(selector);
    std::vector<TypedExpression> conditions(statement.case_items.size());
    for (std::size_t index = 0; index < statement.case_items.size(); ++index) {
        const auto& item = statement.case_items[index];
        if (item.is_default) continue;
        std::optional<TypedExpression> combined;
        for (std::size_t item_index = 0; item_index < item.labels.size(); ++item_index) {
            TypedExpression match;
            if (casez) {
                match = lower_casez_match(selector, item.labels[item_index], tokens, item.location, four_state);
            } else {
                auto& label = labels[index][item_index];
                apply_case_context(label);
                const auto kind = casex ? "casex_match" : "binary";
                const auto op = casex ? "four-state-xz-wildcard" : four_state ? "===" : "==";
                match = TypedExpression{kind, op, 1, false, item.location, {selector, std::move(label)}};
            }
            if (combined) {
                match = TypedExpression{"binary", "||", 1, false,
                    item.location, {std::move(*combined), std::move(match)}};
            }
            combined = std::move(match);
        }
        if (!combined) {
            throw LoweringError(item.location, "non-default case item has no match labels");
        }
        conditions[index] = std::move(*combined);
    }
    return conditions;
}

void lower_combinational_statement(
    const frontend::StatementSyntax& statement,
    const std::set<std::string>& targets,
    const std::vector<frontend::Token>& tokens,
    const std::map<std::string, TIRSignal>& signals,
    const std::map<std::string, TIRConstant>& constants,
    CombinationalEnvironment& environment, bool four_state = false) {
    if (statement.kind == frontend::StatementKind::Assignment) {
        if (!statement.lvalue ||
            statement.lvalue->after_last_token !=
                statement.lvalue->first_token + 1 ||
            statement.lvalue->first_token >= tokens.size() ||
            tokens[statement.lvalue->first_token].kind !=
                frontend::TokenKind::Identifier) {
            throw LoweringError(statement.location,
                "always_comb lowering supports whole-signal assignment targets only");
        }
        const auto& target = tokens[statement.lvalue->first_token].text;
        const auto signal = signals.find(target);
        if (targets.find(target) == targets.end() || signal == signals.end() ||
            signal->second.role == "input") {
            throw LoweringError(statement.location,
                "always_comb target must be a declared writable signal in this process");
        }
        if (statement.nonblocking) {
            throw LoweringError(statement.location,
                "always_comb assignments must use blocking '=' in this T016 slice");
        }
        if (!statement.assignment) {
            throw LoweringError(statement.location,
                "always_comb assignment has no right-hand expression");
        }
        auto expression = lower_process_expression(*statement.assignment, tokens,
            signals, constants, environment, signal->second.width, true, four_state);
        environment.values[target] = resize_assignment(
            std::move(expression), signal->second.width, signal->second.is_signed);
        environment.assigned[target] = true;
        return;
    }
    if (statement.kind == frontend::StatementKind::Block) {
        for (const auto& child : statement.body) {
            lower_combinational_statement(child, targets, tokens, signals,
                constants, environment, four_state);
        }
        return;
    }
    if (statement.kind == frontend::StatementKind::If) {
        if (!statement.expression || statement.body.size() != 1 ||
            statement.else_body.size() > 1) {
            throw LoweringError(statement.location,
                "malformed if/else statement in always_comb tree");
        }
        auto condition = lower_boolean_condition(lower_process_expression(
            *statement.expression, tokens, signals, constants, environment, 0, false, four_state));
        auto then_environment = environment;
        auto else_environment = environment;
        lower_combinational_statement(statement.body.front(), targets, tokens,
            signals, constants, then_environment, four_state);
        if (!statement.else_body.empty()) {
            lower_combinational_statement(statement.else_body.front(), targets,
                tokens, signals, constants, else_environment, four_state);
        }
        environment = merge_combinational_environments(condition,
            then_environment, else_environment, statement.location);
        return;
    }
    if (statement.kind == frontend::StatementKind::Case ||
        statement.kind == frontend::StatementKind::CaseZ ||
        statement.kind == frontend::StatementKind::CaseX) {
        if (!statement.expression || statement.case_items.empty()) {
            throw LoweringError(statement.location,
                "malformed case statement in always_comb tree");
        }
        const auto conditions = lower_case_conditions(statement, tokens, signals, constants, four_state);
        std::optional<CombinationalEnvironment> default_environment;
        std::vector<std::pair<TypedExpression, CombinationalEnvironment>> arms;
        for (std::size_t index = 0; index < statement.case_items.size(); ++index) {
            const auto& item = statement.case_items[index];
            auto branch_environment = environment;
            for (const auto& child : item.statements) {
                lower_combinational_statement(child, targets, tokens, signals,
                    constants, branch_environment, four_state);
            }
            if (item.is_default) {
                if (default_environment) {
                    throw LoweringError(item.location,
                        "case statement contains multiple default items");
                }
                default_environment = std::move(branch_environment);
            } else {
                auto condition = substitute_process_values(conditions[index], environment);
                arms.emplace_back(std::move(condition),
                    std::move(branch_environment));
            }
        }
        if (!default_environment) {
            throw LoweringError(statement.location,
                "always_comb case lowering requires a default item to exclude latch semantics");
        }
        environment = std::move(*default_environment);
        for (auto arm = arms.rbegin(); arm != arms.rend(); ++arm) {
            environment = merge_combinational_environments(arm->first,
                arm->second, environment, statement.location);
        }
        return;
    }
    throw LoweringError(statement.location,
        "unsupported statement kind in always_comb process");
}

void collect_signal_references(const TypedExpression& expression,
                               std::set<std::string>& references) {
    if (expression.kind == "signal") references.insert(expression.value);
    for (const auto& operand : expression.operands) {
        collect_signal_references(operand, references);
    }
}

void validate_combinational_acyclic(const TIRModule& module) {
    std::map<std::string, const TIREquation*> equations;
    for (const auto& equation : module.combinational_equations) {
        equations.emplace(equation.target, &equation);
    }
    std::map<std::string, std::vector<std::string>> dependencies;
    for (const auto& equation : module.combinational_equations) {
        std::set<std::string> references;
        collect_signal_references(equation.expression, references);
        for (const auto& reference : references) {
            if (equations.find(reference) != equations.end()) {
                dependencies[equation.target].push_back(reference);
            }
        }
    }
    std::map<std::string, unsigned char> color;
    const auto visit = [&](const auto& self, const std::string& target) -> void {
        color[target] = 1;
        for (const auto& dependency : dependencies[target]) {
            if (color[dependency] == 1) {
                const auto equation = equations.find(target);
                if (equation != equations.end()) {
                    throw LoweringError(equation->second->location,
                        "combinational dependency cycle includes signal '" +
                        dependency + "'");
                }
            }
            if (color[dependency] == 0) self(self, dependency);
        }
        color[target] = 2;
    };
    for (const auto& [target, equation] : equations) {
        (void)equation;
        if (color[target] == 0) visit(visit, target);
    }
}

frontend::ExpressionSpan strip_outer_parentheses(
    frontend::ExpressionSpan span,
    const std::vector<frontend::Token>& tokens) {
    for (;;) {
        if (span.after_last_token <= span.first_token + 1 ||
            tokens[span.first_token].text != "(" ||
            tokens[span.after_last_token - 1].text != ")") {
            return span;
        }
        int depth = 0;
        std::size_t matching_close = span.first_token;
        for (auto index = span.first_token; index < span.after_last_token; ++index) {
            if (tokens[index].text == "(") ++depth;
            else if (tokens[index].text == ")") {
                --depth;
                if (depth == 0) {
                    matching_close = index;
                    break;
                }
            }
        }
        if (matching_close != span.after_last_token - 1) return span;
        ++span.first_token;
        --span.after_last_token;
    }
}

std::optional<std::size_t> find_top_level_token(
    const frontend::ExpressionSpan& span,
    const std::vector<frontend::Token>& tokens,
    const std::set<std::string>& candidates) {
    int parentheses = 0;
    int brackets = 0;
    int braces = 0;
    int conditionals = 0;
    for (auto index = span.first_token; index < span.after_last_token; ++index) {
        const auto& text = tokens[index].text;
        if (parentheses == 0 && brackets == 0 && braces == 0) {
            if (text == "?") ++conditionals;
            else if (text == ":" && conditionals > 0) --conditionals;
            else if (candidates.find(text) != candidates.end()) return index;
        }
        if (text == "(") ++parentheses;
        else if (text == ")") --parentheses;
        else if (text == "[" || text == "[*") ++brackets;
        else if (text == "]") --brackets;
        else if (text == "{") ++braces;
        else if (text == "}") --braces;
    }
    return std::nullopt;
}

std::uint64_t parse_sva_constant_bound(
    const frontend::ExpressionSpan& span,
    const std::vector<frontend::Token>& tokens,
    const std::map<std::string, TIRConstant>& constants,
    const std::string& description) {
    if (span.first_token >= span.after_last_token || span.after_last_token > tokens.size()) {
        throw LoweringError(span.first_token < tokens.size()
            ? tokens[span.first_token].location
            : frontend::SourceLocation{"<sva>", 1, 1, 0},
            description + " is missing");
    }
    if (span.after_last_token != span.first_token + 1) {
        const std::map<std::string, TIRSignal> no_signals;
        ExpressionParser parser(tokens, span, no_signals, constants, 0);
        return parser.evaluate_nonnegative_constant(parser.parse(), description);
    }
    const auto& token = tokens[span.first_token];
    if (token.kind == frontend::TokenKind::Identifier) {
        const auto constant = constants.find(token.text);
        if (constant == constants.end() ||
            (constant->second.is_signed && constant->second.value < 0)) {
            throw LoweringError(token.location,
                description + " does not resolve to a nonnegative constant");
        }
        return static_cast<std::uint64_t>(constant->second.value);
    }
    if (token.kind != frontend::TokenKind::Number) {
        throw LoweringError(token.location,
            description + " must be an unsigned integer constant");
    }
    const auto quote = token.text.find('\'');
    if (quote == 0) {
        throw LoweringError(token.location, description + " requires an explicitly sized literal");
    }
    if (quote != std::string::npos) {
        const std::map<std::string, TIRSignal> no_signals;
        ExpressionParser parser(tokens, span, no_signals, constants, 0);
        return parser.evaluate_nonnegative_constant(parser.parse(), description);
    }

    auto digits = token.text;
    digits.erase(std::remove(digits.begin(), digits.end(), '_'), digits.end());
    if (digits.empty()) {
        throw LoweringError(token.location, description + " is empty");
    }
    std::uint64_t value = 0;
    const auto parsed = std::from_chars(digits.data(),
        digits.data() + digits.size(), value, 10);
    if (parsed.ec != std::errc{} || parsed.ptr != digits.data() + digits.size()) {
        throw LoweringError(token.location,
            description + " is not a supported nonnegative integer constant");
    }
    return value;
}

struct LoweredSvaSequence {
    TIRSequence sequence;
    std::uint64_t maximum_past_delay = 0;
    std::uint64_t required_history_warmup = 0;
    std::vector<std::uint64_t> term_past_delays;
};

constexpr std::size_t kMaximumLoweredSvaTerms = 10000;

std::vector<std::size_t> lowered_path_lengths(const TIRSequence& sequence) {
    return sequence.path_lengths.empty()
        ? std::vector<std::size_t>{sequence.terms.size()} : sequence.path_lengths;
}

void append_lowered_path(LoweredSvaSequence& output, const LoweredSvaSequence& input,
                         std::size_t first, std::size_t length,
                         const frontend::SourceLocation& location) {
    if (length > kMaximumLoweredSvaTerms - output.sequence.terms.size()) {
        throw LoweringError(location, "sequence exceeds the lowered SVA term limit of 10000");
    }
    for (auto index = first; index < first + length; ++index) {
        output.sequence.terms.push_back(input.sequence.terms[index]);
        output.term_past_delays.push_back(input.term_past_delays[index]);
    }
}

void concatenate_lowered(LoweredSvaSequence& left, LoweredSvaSequence right,
                         const frontend::SourceLocation& location) {
    left.maximum_past_delay = std::max(left.maximum_past_delay, right.maximum_past_delay);
    if (left.sequence.terms.empty()) {
        left = std::move(right);
    } else if (left.sequence.path_lengths.empty() && right.sequence.path_lengths.empty()) {
        append_lowered_path(left, right, 0, right.sequence.terms.size(), location);
    } else {
        LoweredSvaSequence joined;
        joined.maximum_past_delay = left.maximum_past_delay;
        const auto left_lengths = lowered_path_lengths(left.sequence);
        const auto right_lengths = lowered_path_lengths(right.sequence);
        std::size_t left_first = 0;
        for (const auto left_length : left_lengths) {
            std::size_t right_first = 0;
            for (const auto right_length : right_lengths) {
                append_lowered_path(joined, left, left_first, left_length, location);
                append_lowered_path(joined, right, right_first, right_length, location);
                joined.sequence.path_lengths.push_back(left_length + right_length);
                right_first += right_length;
            }
            left_first += left_length;
        }
        left = std::move(joined);
    }
}

struct SvaMatchTerm {
    std::size_t index;
    std::uint64_t sample;
};

using SvaMatchesByEnd = std::map<std::uint64_t, std::vector<std::vector<SvaMatchTerm>>>;

SvaMatchesByEnd expand_sequence_operand(const TIRSequence& sequence, const std::string& operation,
                                       const frontend::SourceLocation& location) {
    SvaMatchesByEnd matches;
    std::size_t retained = 0;
    std::size_t first = 0;
    for (const auto length : lowered_path_lengths(sequence)) {
        std::vector<std::vector<SvaMatchTerm>> paths(1);
        for (auto index = first; index < first + length; ++index) {
            const auto& term = sequence.terms[index];
            std::vector<std::vector<SvaMatchTerm>> next;
            std::size_t expanded = 0;
            for (const auto& path : paths) {
                const auto previous = path.empty() ? 0 : path.back().sample;
                if (term.delay_from_previous > 128 - previous ||
                    term.repeat_max - 1 > 128 - previous - term.delay_from_previous) {
                    throw LoweringError(location, operation + " operands must fit the finite 128-sample profile",
                                        frontend::InputDiagnosticKind::Unsupported);
                }
                auto choice = path;
                const auto start = previous + term.delay_from_previous;
                for (std::uint64_t count = 1; count <= term.repeat_max; ++count) {
                    choice.push_back({index, start + count - 1});
                    if (count < term.repeat_min) continue;
                    if (choice.size() > kMaximumLoweredSvaTerms - retained - expanded) {
                        throw LoweringError(location, operation + " exceeds the lowered SVA term limit of 10000");
                    }
                    expanded += choice.size();
                    next.push_back(choice);
                }
            }
            if (index + 1 == first + length) retained += expanded;
            paths = std::move(next);
        }
        for (auto& path : paths) {
            const auto end = path.back().sample;
            matches[end].push_back(std::move(path));
        }
        first += length;
    }
    return matches;
}

void append_merged_sva_path(LoweredSvaSequence& result, const LoweredSvaSequence& left,
                            const LoweredSvaSequence& right, const std::vector<SvaMatchTerm>& a,
                            const std::vector<SvaMatchTerm>& b, std::uint64_t delay,
                            const std::string& operation, const frontend::SourceLocation& location,
                            std::uint64_t left_shift = 0) {
    const auto length = a.size() + b.size();
    if (length > kMaximumLoweredSvaTerms - result.sequence.terms.size()) {
        throw LoweringError(location, operation + " exceeds the lowered SVA term limit of 10000");
    }
    auto first = a.begin();
    auto second = b.begin();
    std::uint64_t previous = 0;
    for (std::size_t i = 0; i < length; ++i) {
        const bool from_left = second == b.end() ||
            (first != a.end() && first->sample + left_shift <= second->sample);
        const auto& operand = from_left ? left : right;
        const auto& sampled = from_left ? *first++ : *second++;
        auto term = operand.sequence.terms[sampled.index];
        const auto sample = sampled.sample + (from_left ? left_shift : 0);
        term.delay_from_previous = sample - previous + (i == 0 ? delay : 0);
        term.repeat_min = 1;
        term.repeat_max = 1;
        previous = sample;
        result.sequence.terms.push_back(std::move(term));
        result.term_past_delays.push_back(operand.term_past_delays[sampled.index]);
    }
    result.sequence.path_lengths.push_back(length);
}

LoweredSvaSequence combine_sva_matches(const LoweredSvaSequence& left, const LoweredSvaSequence& right,
                                      std::uint64_t delay, const std::string& operation,
                                      const frontend::SourceLocation& location) {
    const bool equal_end = operation == "intersection";
    const bool contains = operation == "within";
    const auto left_matches = expand_sequence_operand(left.sequence, operation, location);
    const auto right_matches = expand_sequence_operand(right.sequence, operation, location);
    if (delay > 128) {
        throw LoweringError(location, operation + " delay exceeds the finite 128-sample profile",
                            frontend::InputDiagnosticKind::Unsupported);
    }
    LoweredSvaSequence result;
    result.maximum_past_delay = std::max(left.maximum_past_delay, right.maximum_past_delay);
    for (const auto& [end, left_paths] : left_matches) {
        const auto first = equal_end || contains ? right_matches.lower_bound(end) : right_matches.begin();
        const auto after = equal_end ? right_matches.upper_bound(end) : right_matches.end();
        for (const auto& a : left_paths) {
            for (auto endpoints = first; endpoints != after; ++endpoints) {
                for (const auto& b : endpoints->second) {
                    // Containment permits every inner start whose end fits within this outer match.
                    const auto latest_shift = contains ? endpoints->first - end : 0;
                    for (std::uint64_t shift = 0; shift <= latest_shift; ++shift) {
                        append_merged_sva_path(result, left, right, a, b, delay, operation, location, shift);
                    }
                }
            }
        }
    }
    if (result.sequence.terms.empty()) {
        const auto endpoint = contains ? right_matches.rbegin()->first :
            std::max(left_matches.rbegin()->first, right_matches.rbegin()->first);
        result.sequence.terms.push_back(TIRSequenceTerm{delay + endpoint, 1, 1,
            TypedExpression{"literal", "1'b0", 1, false, location, {}}, location});
        result.term_past_delays.push_back(0);
    }
    return result;
}

struct SvaSequenceScope {
    std::map<std::string, frontend::ExpressionSpan> declarations;
    std::set<std::string> active;
    std::size_t expansions = 0;
};

TypedExpression at_earlier_sample(TypedExpression predicate, std::uint64_t delay,
                                 const frontend::SourceLocation& location) {
    if (delay == 0) return predicate;
    return {"first_match_past", std::to_string(delay), 1, false, location, {std::move(predicate)}};
}

TypedExpression join_sva_predicates(std::vector<TypedExpression> values, std::string_view op,
                                   const frontend::SourceLocation& location) {
    while (values.size() > 1) {
        std::vector<TypedExpression> next;
        next.reserve((values.size() + 1) / 2);
        for (std::size_t i = 0; i + 1 < values.size(); i += 2) {
            next.push_back(TypedExpression{"binary", std::string(op), 1, false, location,
                {std::move(values[i]), std::move(values[i + 1])}});
        }
        if (values.size() % 2 != 0) next.push_back(std::move(values.back()));
        values = std::move(next);
    }
    return std::move(values.front());
}

LoweredSvaSequence lower_first_match(LoweredSvaSequence body, std::uint64_t delay,
                                    const frontend::SourceLocation& location) {
    const std::string operation = "first_match";
    const auto alternatives = expand_sequence_operand(body.sequence, operation, location);
    if (delay > 128) {
        throw LoweringError(location, "first_match delay exceeds the finite 128-sample profile",
                            frontend::InputDiagnosticKind::Unsupported);
    }
    const auto nodes = [](const auto& self, const TypedExpression& value) -> std::size_t {
        std::size_t count = 1;
        for (const auto& operand : value.operands) count += self(self, operand);
        return count;
    };
    LoweredSvaSequence result;
    result.maximum_past_delay = body.maximum_past_delay;
    std::optional<TypedExpression> candidate_guard;
    std::size_t guard_nodes = 0;
    for (auto group = alternatives.begin(); group != alternatives.end(); ++group) {
        const auto& [end, paths] = *group;
        const auto following = std::next(group);
        if (candidate_guard) {
            const auto cost = nodes(nodes, *candidate_guard);
            if (cost > (200000 - guard_nodes) / paths.size()) {
                throw LoweringError(location, "first_match exceeds the sampled guard limit of 200000 nodes");
            }
            guard_nodes += cost * paths.size();
        }
        std::vector<TypedExpression> current;
        for (const auto& path : paths) {
            const auto length = path.size() + (candidate_guard ? 1 : 0);
            if (length > kMaximumLoweredSvaTerms - result.sequence.terms.size()) {
                throw LoweringError(location, "first_match exceeds the lowered SVA term limit of 10000");
            }
            std::uint64_t previous = 0;
            std::vector<TypedExpression> constraints;
            for (std::size_t i = 0; i < path.size(); ++i) {
                const auto& sampled = path[i];
                auto term = body.sequence.terms[sampled.index];
                if (following != alternatives.end()) {
                    auto predicate = at_earlier_sample(term.predicate, end - sampled.sample, term.location);
                    constraints.push_back(TypedExpression{"binary", "===", 1, false, term.location,
                        {std::move(predicate), TypedExpression{"literal", "1'b1", 1, false, term.location, {}}}});
                }
                term.delay_from_previous = sampled.sample - previous + (i == 0 ? delay : 0);
                term.repeat_min = 1;
                term.repeat_max = 1;
                result.sequence.terms.push_back(std::move(term));
                result.term_past_delays.push_back(body.term_past_delays[sampled.index]);
                previous = sampled.sample;
            }
            if (!constraints.empty()) current.push_back(join_sva_predicates(std::move(constraints), "&&", location));
            if (candidate_guard) {
                result.sequence.terms.push_back({0, 1, 1, *candidate_guard, location});
                result.term_past_delays.push_back(0);
            }
            result.sequence.path_lengths.push_back(length);
        }
        if (following != alternatives.end()) {
            auto missed = TypedExpression{"unary", "!", 1, false, location,
                {join_sva_predicates(std::move(current), "||", location)}};
            if (candidate_guard) {
                missed = TypedExpression{"binary", "&&", 1, false, location,
                    {std::move(*candidate_guard), std::move(missed)}};
            }
            candidate_guard = at_earlier_sample(std::move(missed), following->first - end, location);
        }
    }
    return result;
}

LoweredSvaSequence lower_sva_sequence(
    frontend::ExpressionSpan span,
    std::uint64_t delay_from_previous,
    const std::vector<frontend::Token>& tokens,
    const std::map<std::string, TIRSignal>& signals,
    const std::map<std::string, TIRConstant>& constants, bool four_state, SvaSequenceScope* scope);

LoweredSvaSequence lower_sva_term(
    frontend::ExpressionSpan span,
    std::uint64_t delay_from_previous,
    const std::vector<frontend::Token>& tokens,
    const std::map<std::string, TIRSignal>& signals,
    const std::map<std::string, TIRConstant>& constants, bool four_state, SvaSequenceScope* scope) {
    if (span.first_token >= span.after_last_token) {
        throw LoweringError(span.first_token < tokens.size()
            ? tokens[span.first_token].location
            : frontend::SourceLocation{"<sva>", 1, 1, 0},
            "empty SVA sequence term");
    }
    std::uint64_t repeat_min = 1;
    std::uint64_t repeat_max = 1;
    auto suffix = find_top_level_token(span, tokens, {"[*"});
    if (suffix) {
        const auto suffix_index = *suffix;
        if (tokens[span.after_last_token - 1].text != "]") {
            throw LoweringError(tokens[suffix_index].location,
                "bounded repetition must end the sequence term");
        }
        const auto bounds_begin = suffix_index + 1;
        const auto close = span.after_last_token - 1;
        const auto colon = find_top_level_token(
            frontend::ExpressionSpan{bounds_begin, close}, tokens, {":"});
        const auto lower_span = frontend::ExpressionSpan{bounds_begin,
            colon.value_or(close)};
        repeat_min = parse_sva_constant_bound(lower_span, tokens, constants,
            "repetition lower bound");
        repeat_max = repeat_min;
        if (colon) {
            const frontend::ExpressionSpan upper_span{*colon + 1, close};
            repeat_max = parse_sva_constant_bound(upper_span, tokens, constants,
                "repetition upper bound");
        }
        if (repeat_min == 0 || repeat_max == 0) {
            throw LoweringError(tokens[suffix_index].location,
                "bounded repetition requires positive bounds",
                frontend::InputDiagnosticKind::Unsupported);
        }
        if (repeat_max < repeat_min) {
            throw LoweringError(tokens[suffix_index].location,
                "bounded repetition requires minimum <= maximum");
        }
        span.after_last_token = suffix_index;
    }
    const auto unwrapped = strip_outer_parentheses(span, tokens);
    std::optional<frontend::ExpressionSpan> reference;
    const auto term_length = unwrapped.after_last_token - unwrapped.first_token;
    std::optional<frontend::ExpressionSpan> first_match;
    if (four_state && term_length >= 4 &&
        tokens[unwrapped.first_token].text == "first_match" &&
        tokens[unwrapped.first_token + 1].text == "(") {
        const auto begin = unwrapped.first_token + 2;
        const auto close = find_top_level_token({begin, unwrapped.after_last_token}, tokens, {")"});
        if (close && *close + 1 == unwrapped.after_last_token) {
            first_match = frontend::ExpressionSpan{begin, *close};
        }
    }
    if (scope && (term_length == 1 || term_length == 3)) {
        const auto& name = tokens[unwrapped.first_token];
        const bool call = term_length == 3 && tokens[unwrapped.first_token + 1].text == "(" &&
            tokens[unwrapped.first_token + 2].text == ")";
        if (name.kind == frontend::TokenKind::Identifier && (term_length == 1 || call)) {
            const auto declaration = scope->declarations.find(name.text);
            if (declaration != scope->declarations.end()) {
                reference = declaration->second;
            } else if (call) {
                throw LoweringError(name.location, "unresolved named sequence '" + name.text + "'");
            }
        }
    }
    if (first_match || reference || find_top_level_token(unwrapped, tokens, {"##", "[*"}) ||
        (four_state && find_top_level_token(unwrapped, tokens, {"or", "and", "intersect", "within", "throughout"}))) {
        const auto& name = tokens[unwrapped.first_token];
        if (reference && (scope->active.size() >= 128 || !scope->active.insert(name.text).second)) {
            throw LoweringError(name.location, "recursive or excessively nested named sequence '" + name.text + "'");
        }
        if (reference && ++scope->expansions > kMaximumLoweredSvaTerms) {
            throw LoweringError(name.location, "named sequences exceed the expansion limit of 10000");
        }
        auto repeated = first_match
            ? lower_first_match(lower_sva_sequence(*first_match, 0, tokens, signals, constants, four_state, scope),
                                delay_from_previous, name.location)
            : lower_sva_sequence(reference.value_or(unwrapped), delay_from_previous, tokens,
                                 signals, constants, four_state, scope);
        if (reference) scope->active.erase(name.text);
        if (repeat_max == 1) return repeated;
        const auto term_count = repeated.sequence.terms.size();
        if (repeat_max > kMaximumLoweredSvaTerms / term_count) {
            throw LoweringError(tokens[*suffix].location,
                "compound repetition exceeds the lowered SVA term limit of 10000");
        }
        if (repeat_min != repeat_max || !repeated.sequence.path_lengths.empty()) {
            const auto& location = tokens[*suffix].location;
            auto continuation = repeated;
            std::size_t first = 0;
            for (const auto length : lowered_path_lengths(continuation.sequence)) {
                continuation.sequence.terms[first].delay_from_previous = 1;
                first += length;
            }
            LoweredSvaSequence choices;
            choices.maximum_past_delay = repeated.maximum_past_delay;
            for (std::uint64_t count = 1; count <= repeat_max; ++count) {
                if (count >= repeat_min) {
                    std::size_t offset = 0;
                    for (const auto length : lowered_path_lengths(repeated.sequence)) {
                        append_lowered_path(choices, repeated, offset, length, location);
                        choices.sequence.path_lengths.push_back(length);
                        offset += length;
                    }
                }
                if (count < repeat_max) concatenate_lowered(repeated, continuation, location);
            }
            if (choices.sequence.path_lengths.size() == 1) choices.sequence.path_lengths.clear();
            return choices;
        }
        const auto count = static_cast<std::size_t>(repeat_max) * term_count;
        repeated.sequence.terms.reserve(count);
        repeated.term_past_delays.reserve(count);
        for (std::size_t offset = term_count; offset < count; offset += term_count) {
            for (std::size_t index = 0; index < term_count; ++index) {
                auto term = repeated.sequence.terms[index];
                if (index == 0) term.delay_from_previous = 1;
                repeated.sequence.terms.push_back(std::move(term));
                repeated.term_past_delays.push_back(repeated.term_past_delays[index]);
            }
        }
        // The enclosing sequence recalculates history warm-up from the full
        // list of terms and their earliest sample offsets.
        return repeated;
    }
    auto predicate = ExpressionParser(tokens, unwrapped, signals, constants, 1, four_state).parse();
    if (predicate.width != 1) {
        throw LoweringError(predicate.location,
            "SVA sequence terms must be one-bit predicates in this T016 slice");
    }
    const auto history_depth = [&](const auto& self,
                                   const TypedExpression& expression)
        -> std::uint64_t {
        if (expression.kind == "past") {
            std::uint64_t delay = 0;
            const auto parsed = std::from_chars(expression.value.data(),
                expression.value.data() + expression.value.size(), delay);
            if (parsed.ec != std::errc{} ||
                parsed.ptr != expression.value.data() + expression.value.size() ||
                expression.operands.size() != 1) {
                throw LoweringError(expression.location,
                    "malformed lowered $past expression");
            }
            const auto nested = self(self, expression.operands.front());
            if (nested > std::numeric_limits<std::uint64_t>::max() - delay) {
                throw LoweringError(expression.location,
                    "nested $past history depth overflows the supported range");
            }
            return delay + nested;
        }
        std::uint64_t maximum = 0;
        for (const auto& operand : expression.operands) {
            maximum = std::max(maximum, self(self, operand));
        }
        return maximum;
    };
    LoweredSvaSequence result;
    result.maximum_past_delay = history_depth(history_depth, predicate);
    result.sequence.terms.push_back(TIRSequenceTerm{delay_from_previous,
        repeat_min, repeat_max, std::move(predicate),
        tokens[unwrapped.first_token].location});
    result.term_past_delays.push_back(result.maximum_past_delay);
    result.required_history_warmup =
        result.maximum_past_delay > delay_from_previous
            ? result.maximum_past_delay - delay_from_previous : 0;
    return result;
}

LoweredSvaSequence lower_sva_sequence(
    frontend::ExpressionSpan span,
    std::uint64_t delay_from_previous,
    const std::vector<frontend::Token>& tokens,
    const std::map<std::string, TIRSignal>& signals,
    const std::map<std::string, TIRConstant>& constants, bool four_state, SvaSequenceScope* scope) {
    span = strip_outer_parentheses(span, tokens);
    if (span.first_token >= span.after_last_token) {
        throw LoweringError(span.first_token < tokens.size()
            ? tokens[span.first_token].location
            : frontend::SourceLocation{"<sva>", 1, 1, 0},
            "empty SVA sequence");
    }
    if (find_top_level_token(span, tokens, {"|->", "|=>"})) {
        throw LoweringError(tokens[span.first_token].location,
            "nested SVA implication is outside the sequence grammar");
    }
    LoweredSvaSequence result;
    auto alternative = four_state ? find_top_level_token(span, tokens, {"or"}) : std::nullopt;
    if (alternative) {
        // Every operand starts at the same sample. Preserve its match endpoints
        // for implication, concatenation, and subsequent repetition.
        auto begin = span.first_token;
        while (true) {
            const auto end = alternative.value_or(span.after_last_token);
            const auto branch = lower_sva_sequence({begin, end}, delay_from_previous,
                                                   tokens, signals, constants, four_state, scope);
            append_lowered_path(result, branch, 0, branch.sequence.terms.size(),
                                tokens[begin].location);
            for (const auto length : lowered_path_lengths(branch.sequence)) {
                result.sequence.path_lengths.push_back(length);
            }
            result.maximum_past_delay = std::max(result.maximum_past_delay,
                                                 branch.maximum_past_delay);
            result.required_history_warmup = std::max(result.required_history_warmup,
                                                      branch.required_history_warmup);
            if (!alternative) break;
            begin = *alternative + 1;
            alternative = find_top_level_token({begin, span.after_last_token}, tokens, {"or"});
        }
        return result;
    }
    std::optional<std::size_t> combination;
    const char* op = nullptr;
    if (four_state) {
        // Check the lowest-precedence pairing operator first.
        for (const auto* candidate : {"and", "intersect", "within"}) {
            combination = find_top_level_token(span, tokens, {candidate});
            if (combination) {
                op = candidate;
                break;
            }
        }
    }
    if (combination) {
        const auto& spelling = tokens[*combination].text;
        const std::string operation = spelling == "and" ? "conjunction" :
            spelling == "intersect" ? "intersection" : "within";
        auto combined = lower_sva_sequence({span.first_token, *combination}, 0,
                                             tokens, signals, constants, four_state, scope);
        while (combination) {
            const auto separator = *combination;
            const auto begin = separator + 1;
            combination = find_top_level_token({begin, span.after_last_token}, tokens, {op});
            const auto right = lower_sva_sequence({begin, combination.value_or(span.after_last_token)}, 0,
                                                   tokens, signals, constants, four_state, scope);
            combined = combine_sva_matches(combined, right, combination ? 0 : delay_from_previous,
                                           operation, tokens[separator].location);
        }
        return combined;
    }
    const auto throughout = four_state ? find_top_level_token(span, tokens, {"throughout"}) : std::nullopt;
    if (throughout) {
        const auto& location = tokens[*throughout].location;
        const auto condition = strip_outer_parentheses({span.first_token, *throughout}, tokens);
        if (find_top_level_token(condition, tokens, {"##", "[*", "or", "and", "intersect", "within", "throughout"})) {
            throw LoweringError(location, "throughout requires a scalar expression as its left operand",
                                frontend::InputDiagnosticKind::Unsupported);
        }
        if (delay_from_previous > 128) {
            throw LoweringError(location, "throughout delay exceeds the finite 128-sample profile",
                                frontend::InputDiagnosticKind::Unsupported);
        }
        const auto guard = lower_sva_term(condition, 0, tokens, signals, constants, four_state, nullptr);
        const auto body = lower_sva_sequence({*throughout + 1, span.after_last_token}, 0,
                                              tokens, signals, constants, four_state, scope);
        result.maximum_past_delay = std::max(guard.maximum_past_delay, body.maximum_past_delay);
        const std::string operation = "throughout";
        for (const auto& [end, paths] : expand_sequence_operand(body.sequence, operation, location)) {
            // The condition must also hold in delay gaps with no body predicate.
            std::vector<SvaMatchTerm> guard_samples;
            guard_samples.reserve(end + 1);
            for (std::uint64_t sample = 0; sample <= end; ++sample) {
                guard_samples.push_back({0, sample});
            }
            for (const auto& path : paths) {
                append_merged_sva_path(result, guard, body, guard_samples, path,
                                       delay_from_previous, operation, location);
            }
        }
        return result;
    }
    std::size_t term_begin = span.first_token;
    std::uint64_t next_delay = delay_from_previous;
    while (term_begin < span.after_last_token) {
        const frontend::ExpressionSpan remaining{term_begin, span.after_last_token};
        const auto delay_token = find_top_level_token(remaining, tokens, {"##"});
        const auto term_end = delay_token.value_or(span.after_last_token);
        auto term = lower_sva_term(frontend::ExpressionSpan{term_begin, term_end},
            next_delay, tokens, signals, constants, four_state, scope);
        concatenate_lowered(result, std::move(term), tokens[term_begin].location);
        if (!delay_token) break;
        const auto delay_index = *delay_token;
        if (delay_index + 1 >= span.after_last_token) {
            throw LoweringError(tokens[delay_index].location,
                "sequence delay is missing its following term");
        }
        if (tokens[delay_index + 1].text == "[") {
            const auto bounds_begin = delay_index + 2;
            std::size_t close = bounds_begin;
            int bracket_depth = 1;
            for (; close < span.after_last_token; ++close) {
                if (tokens[close].text == "[") ++bracket_depth;
                else if (tokens[close].text == "]" && --bracket_depth == 0) break;
            }
            if (close >= span.after_last_token) {
                throw LoweringError(tokens[delay_index].location,
                    "sequence delay range is missing its closing ']'");
            }
            const frontend::ExpressionSpan bounds{bounds_begin, close};
            const auto colon = find_top_level_token(bounds, tokens, {":"});
            if (!colon) {
                throw LoweringError(tokens[delay_index].location,
                    "sequence delay range must use finite [minimum:maximum] bounds");
            }
            const auto minimum = parse_sva_constant_bound(
                frontend::ExpressionSpan{bounds_begin, *colon}, tokens,
                constants, "sequence delay lower bound");
            const auto maximum = parse_sva_constant_bound(
                frontend::ExpressionSpan{*colon + 1, close}, tokens,
                constants, "sequence delay upper bound");
            if (maximum < minimum) {
                throw LoweringError(tokens[delay_index].location,
                    "sequence delay range requires minimum <= maximum");
            }
            if (maximum == minimum) {
                next_delay = minimum;
            } else {
                const auto range_width = maximum - minimum;
                if (range_width == std::numeric_limits<std::uint64_t>::max()) {
                    throw LoweringError(tokens[delay_index].location,
                        "sequence delay range is too wide for the supported representation");
                }
                // A true predicate repeated over the allowed gap samples turns
                // ##[m:n] into one linear path with existential endpoints:
                // the following term has zero additional delay and may match
                // at any sample from m through n after the previous endpoint.
                LoweredSvaSequence gap;
                gap.sequence.terms.push_back(TIRSequenceTerm{
                    minimum, 1, range_width + 1,
                    TypedExpression{"literal", "1'b1", 1, false,
                        tokens[delay_index].location, {}},
                    tokens[delay_index].location});
                gap.term_past_delays.push_back(0);
                concatenate_lowered(result, std::move(gap), tokens[delay_index].location);
                next_delay = 0;
            }
            term_begin = close + 1;
        } else {
            frontend::ExpressionSpan delay_span{delay_index + 1, delay_index + 2};
            if (tokens[delay_span.first_token].text == "(") {
                ++delay_span.first_token;
                const auto close = find_top_level_token(
                    {delay_span.first_token, span.after_last_token}, tokens, {")"});
                if (!close) {
                    throw LoweringError(tokens[delay_index].location,
                        "parenthesized sequence delay is missing its closing ')'");
                }
                delay_span.after_last_token = *close;
                term_begin = *close + 1;
            } else {
                term_begin = delay_span.after_last_token;
            }
            next_delay = parse_sva_constant_bound(delay_span, tokens, constants, "sequence delay");
        }
    }
    if (result.sequence.terms.empty()) {
        throw LoweringError(tokens[span.first_token].location,
            "SVA sequence contains no terms");
    }
    if (result.term_past_delays.size() != result.sequence.terms.size()) {
        throw LoweringError(tokens[span.first_token].location,
            "SVA history analysis lost sequence-term alignment");
    }
    const auto path_lengths = lowered_path_lengths(result.sequence);
    std::size_t path_index = 0;
    std::size_t path_end = path_lengths.front();
    result.required_history_warmup = 0;
    std::uint64_t earliest_sample = 0;
    for (std::size_t index = 0; index < result.sequence.terms.size(); ++index) {
        if (index == path_end) {
            earliest_sample = 0;
            path_end += path_lengths[++path_index];
        }
        const auto& term = result.sequence.terms[index];
        if (term.delay_from_previous >
            std::numeric_limits<std::uint64_t>::max() - earliest_sample) {
            throw LoweringError(term.location,
                "SVA sequence sample offset overflows during history analysis");
        }
        earliest_sample += term.delay_from_previous;
        if (result.term_past_delays[index] > earliest_sample) {
            result.required_history_warmup = std::max(
                result.required_history_warmup,
                result.term_past_delays[index] - earliest_sample);
        }
        const auto repeat_offset = term.repeat_min - 1;
        if (repeat_offset >
            std::numeric_limits<std::uint64_t>::max() - earliest_sample) {
            throw LoweringError(term.location,
                "SVA repeated sample offset overflows during history analysis");
        }
        earliest_sample += repeat_offset;
    }
    return result;
}

void append_named_property(TIRModule& module, TIRProperty property) {
    if (is_eventual_response(property) && property.kind != "assert") {
        throw LoweringError(property.location, "s_eventually is supported only for assertions",
                            frontend::InputDiagnosticKind::Unsupported);
    }
    const auto duplicate = std::find_if(module.properties.begin(), module.properties.end(),
        [&](const TIRProperty& existing) {
            // An unlabeled reference can be used both to constrain the model
            // and to check it. Only a competing lookup is ambiguous.
            return existing.name == property.name &&
                (existing.kind == "assume") == (property.kind == "assume");
        });
    if (duplicate != module.properties.end()) {
        throw LoweringError(property.location,
            "duplicate property check name '" + property.name + "'");
    }
    module.properties.push_back(std::move(property));
}

struct LoweredSvaProperty {
    std::string implication = "sequence";
    LoweredSvaSequence antecedent;
    std::optional<LoweredSvaSequence> consequent;
};

LoweredSvaProperty lower_sva_property(
    frontend::ExpressionSpan span,
    const std::vector<frontend::Token>& tokens,
    const std::map<std::string, TIRSignal>& signals,
    const std::map<std::string, TIRConstant>& constants, bool four_state = false,
    SvaSequenceScope* scope = nullptr) {
    span = strip_outer_parentheses(span, tokens);
    const auto implication = find_top_level_token(span, tokens, {"|->", "|=>"});
    LoweredSvaProperty result;
    if (!implication) {
        result.antecedent = lower_sva_sequence(span, 0, tokens, signals, constants, four_state, scope);
        return result;
    }
    const auto op = tokens[*implication].text;
    result.implication = op == "|->" ? "overlapped" : "nonoverlapped";
    result.antecedent = lower_sva_sequence(
        frontend::ExpressionSpan{span.first_token, *implication}, 0,
        tokens, signals, constants, four_state, scope);
    auto consequent_start = *implication + 1;
    const bool eventual = tokens[consequent_start].text == "s_eventually";
    if (eventual) ++consequent_start;
    result.consequent = lower_sva_sequence(
        frontend::ExpressionSpan{consequent_start, span.after_last_token}, 0,
        tokens, signals, constants, four_state, scope);
    if (eventual) {
        const auto scalar = [](const LoweredSvaSequence& sequence) {
            const auto& terms = sequence.sequence.terms;
            return sequence.maximum_past_delay == 0 && terms.size() == 1 &&
                terms.front().delay_from_previous == 0 &&
                terms.front().repeat_min == 1 && terms.front().repeat_max == 1;
        };
        if (!scalar(result.antecedent) || !scalar(*result.consequent)) {
            throw LoweringError(tokens[*implication].location,
                "s_eventually requires one same-sample Boolean expression on each side",
                frontend::InputDiagnosticKind::Unsupported);
        }
        result.implication += "-eventual";
    }
    return result;
}

void build_sva_sequence_automaton(TIRSequence& sequence) {
    if (sequence.terms.empty()) {
        throw LoweringError(frontend::SourceLocation{"<sva-automaton>", 1, 1, 0},
            "cannot build a sequence automaton without sequence terms");
    }
    if (sequence.terms.size() >=
        static_cast<std::size_t>(std::numeric_limits<std::uint64_t>::max())) {
        throw LoweringError(sequence.terms.front().location,
            "SVA sequence has too many terms for automaton state identifiers");
    }
    sequence.automaton.start_state = 0;
    const auto lengths = lowered_path_lengths(sequence);
    sequence.automaton.accepting_state = sequence.terms.size() - lengths.size() + 1;
    sequence.automaton.state_count = sequence.automaton.accepting_state + 1;
    sequence.automaton.transitions.clear();
    sequence.automaton.transitions.reserve(sequence.terms.size());
    std::size_t index = 0;
    std::uint64_t next_internal = 1;
    for (const auto length : lengths) {
        std::uint64_t from = 0;
        for (std::size_t edge = 0; edge < length; ++edge) {
            const auto& term = sequence.terms[index++];
            if (term.repeat_min == 0 || term.repeat_max < term.repeat_min) {
                throw LoweringError(term.location,
                    "SVA automaton requires positive ordered repetition bounds");
            }
            const auto to = edge + 1 == length ? sequence.automaton.accepting_state : next_internal++;
            sequence.automaton.transitions.push_back(TIRSequenceTransition{
                from, to, term.delay_from_previous, term.repeat_min, term.repeat_max,
                term.predicate, term.location});
            from = to;
        }
    }
}

class HistoryStateLowerer {
public:
    explicit HistoryStateLowerer(TIRModule& module) : module_(module) {
        for (const auto& signal : module_.signals) used_names_.insert(signal.name);
        for (const auto& parameter : module_.parameters) {
            used_names_.insert(parameter.name);
        }
    }

    TypedExpression lower_past_nodes(const TypedExpression& expression) {
        if (expression.kind == "past" || expression.kind == "first_match_past") {
            if (expression.operands.size() != 1) {
                throw LoweringError(expression.location,
                    "$past expression must have exactly one lowered value operand");
            }
            const auto& operand = expression.operands.front();
            const bool four_state = module_.semantic_profile == frontend::kFourStateProfile;
            const auto* root = &operand;
            while (root->kind == "select" && root->operands.size() == 2) {
                root = &root->operands.front();
            }
            if (four_state && expression.kind == "past" && root->kind != "signal") {
                throw LoweringError(expression.location,
                    "four-state sampled history requires a packed logic signal or constant select",
                    frontend::InputDiagnosticKind::Unsupported);
            }
            auto sampled_value = lower_past_nodes(operand);
            const auto maximum_delay = four_state ? 128U : maximum_history_delay_;
            std::uint64_t delay = 0;
            const auto parsed = std::from_chars(expression.value.data(),
                expression.value.data() + expression.value.size(), delay);
            if (parsed.ec != std::errc{} ||
                parsed.ptr != expression.value.data() + expression.value.size() ||
                delay == 0 || delay > maximum_delay) {
                throw LoweringError(expression.location,
                    "$past delay is outside the current T016 history-state limit");
            }
            return history_reference(sampled_value, delay, expression.location);
        }
        auto result = expression;
        for (auto& operand : result.operands) {
            operand = lower_past_nodes(operand);
        }
        return result;
    }

    void finalize() {
        std::uint64_t maximum_guard_delay = 0;
        for (const auto& guard : module_.history_guards) {
            if (guard.valid_signal.empty()) {
                maximum_guard_delay = std::max(maximum_guard_delay,
                                               guard.delay);
            }
        }
        if (maximum_guard_delay > maximum_history_delay_) {
            throw LoweringError(module_.properties.front().location,
                "history-valid delay is outside the current T016 history-state limit");
        }
        if (maximum_guard_delay > 0) {
            const auto first_pending = std::find_if(module_.history_guards.begin(),
                module_.history_guards.end(), [](const TIRHistoryGuard& guard) {
                    return guard.valid_signal.empty();
                });
            if (first_pending != module_.history_guards.end()) {
                frontend::SourceLocation source =
                    module_.properties.empty()
                    ? frontend::SourceLocation{"<history-state>", 1, 1, 0}
                    : module_.properties.front().location;
                std::vector<std::string> valid_states;
                valid_states.reserve(static_cast<std::size_t>(maximum_guard_delay));
                for (std::uint64_t stage = 0; stage < maximum_guard_delay; ++stage) {
                    const auto name = unique_name("__q3a_history_valid_stage_" +
                        std::to_string(stage));
                    valid_states.push_back(name);
                    module_.signals.push_back(TIRSignal{name, 1, false,
                        "history_valid", source});
                    auto next_value = stage == 0
                        ? TypedExpression{"literal", "1'b1", 1, false, source, {}}
                        : TypedExpression{"signal", valid_states[
                            static_cast<std::size_t>(stage - 1)], 1, false, source, {}};
                    module_.next_state_equations.push_back(TIREquation{name, 1,
                        std::move(next_value), source});
                }
                for (auto& guard : module_.history_guards) {
                    if (!guard.valid_signal.empty()) continue;
                    if (guard.delay == 0 || guard.delay > valid_states.size()) {
                        throw LoweringError(source,
                            "history guard delay does not have a validity-state stage");
                    }
                    guard.state_chain.assign(valid_states.begin(),
                        valid_states.begin() + static_cast<std::ptrdiff_t>(guard.delay));
                    guard.valid_signal = guard.state_chain.back();
                }
            }
        }
        const auto attach_guard = [&](TIRProperty& property,
                                      std::uint64_t delay,
                                      std::string& signal) {
            if (delay == 0 || !signal.empty()) return;
            const auto guard = std::find_if(module_.history_guards.begin(),
                module_.history_guards.end(), [&](const TIRHistoryGuard& item) {
                    return item.clock == property.clock && item.delay == delay;
                });
            if (guard == module_.history_guards.end() ||
                guard->valid_signal.empty()) {
                throw LoweringError(property.location,
                    "property history-valid state was not generated");
            }
            signal = guard->valid_signal;
        };
        for (auto& property : module_.properties) {
            attach_guard(property, property.history_guard_delay,
                         property.history_guard_signal);
            attach_guard(property, property.antecedent_history_guard_delay,
                         property.antecedent_history_guard_signal);
            attach_guard(property, property.consequent_history_guard_delay,
                         property.consequent_history_guard_signal);
        }
    }

private:
    struct HistoryChain {
        TypedExpression sampled_value;
        frontend::SourceLocation location;
        std::vector<std::string> stages;
    };

    std::string unique_name(const std::string& base) {
        std::string name = base;
        std::size_t suffix = 0;
        while (!used_names_.insert(name).second) {
            ++suffix;
            name = base + "_" + std::to_string(suffix);
        }
        return name;
    }

    TypedExpression history_reference(const TypedExpression& sampled_value,
                                      std::uint64_t delay,
                                      const frontend::SourceLocation& location) {
        const auto key = expression_semantic_key(sampled_value);
        auto chain = history_chains_.find(key);
        if (chain == history_chains_.end()) {
            const auto chain_number = next_chain_number_++;
            chain = history_chains_.emplace(key, HistoryChain{
                sampled_value, location, {}}).first;
            chain_numbers_.emplace(key, chain_number);
        }
        auto& history = chain->second;
        const auto chain_number = chain_numbers_.at(key);
        while (history.stages.size() < delay) {
            const auto stage = history.stages.size();
            const auto name = unique_name("__q3a_history_data_" +
                std::to_string(chain_number) + "_stage_" +
                std::to_string(stage));
            history.stages.push_back(name);
            module_.signals.push_back(TIRSignal{name,
                history.sampled_value.width, history.sampled_value.is_signed,
                "history_data", history.location});
            auto next_value = stage == 0
                ? history.sampled_value
                : TypedExpression{"signal", history.stages[stage - 1],
                    history.sampled_value.width,
                    history.sampled_value.is_signed, history.location, {}};
            module_.next_state_equations.push_back(TIREquation{name,
                history.sampled_value.width, std::move(next_value),
                history.location});
        }
        return TypedExpression{"history_ref",
            history.stages[static_cast<std::size_t>(delay - 1)],
            sampled_value.width, sampled_value.is_signed, location, {}};
    }

    static constexpr std::uint64_t maximum_history_delay_ = 65536;
    TIRModule& module_;
    std::set<std::string> used_names_;
    std::map<std::string, HistoryChain> history_chains_;
    std::map<std::string, std::size_t> chain_numbers_;
    std::size_t next_chain_number_ = 0;
};

bool same_location(const frontend::SourceLocation& left,
                   const frontend::SourceLocation& right) {
    return left.file == right.file && left.byte_offset == right.byte_offset &&
        left.line == right.line && left.column == right.column;
}

bool supported_generate_tree(
    const std::vector<frontend::GenerateSyntax>& nodes) {
    for (const auto& node : nodes) {
        if (node.kind == frontend::GenerateKind::Instance) {
            if (!node.instance) return false;
            continue;
        }
        if (node.kind == frontend::GenerateKind::Other &&
            (node.assignment || !node.declarations.empty() || !node.constants.empty())) {
            continue;
        }
        if (node.kind != frontend::GenerateKind::Block &&
            node.kind != frontend::GenerateKind::Conditional &&
            node.kind != frontend::GenerateKind::Loop) {
            return false;
        }
        if (!supported_generate_tree(node.body) ||
            !supported_generate_tree(node.else_body)) {
            return false;
        }
    }
    return true;
}

const frontend::GenerateSyntax* find_unsupported_generate_node(
    const std::vector<frontend::GenerateSyntax>& nodes) {
    for (const auto& node : nodes) {
        if ((node.kind == frontend::GenerateKind::Instance && !node.instance) ||
            (node.kind == frontend::GenerateKind::Other && !node.assignment &&
             node.declarations.empty() && node.constants.empty()) ||
            (node.kind != frontend::GenerateKind::Instance &&
             node.kind != frontend::GenerateKind::Other &&
             node.kind != frontend::GenerateKind::Block &&
             node.kind != frontend::GenerateKind::Conditional &&
             node.kind != frontend::GenerateKind::Loop)) {
            return &node;
        }
        if (const auto* found = find_unsupported_generate_node(node.body)) {
            return found;
        }
        if (const auto* found = find_unsupported_generate_node(node.else_body)) {
            return found;
        }
    }
    return nullptr;
}
const frontend::InstanceSyntax* find_generated_instance(
    const std::vector<frontend::GenerateSyntax>& nodes,
    const frontend::SourceLocation& location) {
    for (const auto& node : nodes) {
        if (node.kind == frontend::GenerateKind::Instance && node.instance &&
            same_location(node.instance->location, location)) {
            return &*node.instance;
        }
        if (const auto* found = find_generated_instance(node.body, location)) {
            return found;
        }
        if (const auto* found = find_generated_instance(node.else_body, location)) {
            return found;
        }
    }
    return nullptr;
}

const frontend::ContinuousAssignmentSyntax* find_generated_assignment(
    const std::vector<frontend::GenerateSyntax>& nodes,
    const frontend::SourceLocation& location) {
    for (const auto& node : nodes) {
        if (node.kind == frontend::GenerateKind::Other && node.assignment &&
            same_location(node.location, location)) {
            return &*node.assignment;
        }
        if (const auto* found = find_generated_assignment(node.body, location)) {
            return found;
        }
        if (const auto* found = find_generated_assignment(node.else_body, location)) {
            return found;
        }
    }
    return nullptr;
}
const frontend::InstanceSyntax* find_source_instance(
    const frontend::ParsedModule& module,
    const frontend::SourceLocation& location) {
    for (const auto& instance : module.instances) {
        if (same_location(instance.location, location)) return &instance;
    }
    return find_generated_instance(module.generate_items, location);
}

} // namespace

LoweringError::LoweringError(frontend::SourceLocation location,
                             const std::string& message, frontend::InputDiagnosticKind kind)
    : std::runtime_error(location.file + ":" + std::to_string(location.line) +
                         ":" + std::to_string(location.column) + ": " + message),
      location_(std::move(location)), kind_(kind) {}

struct HierarchyReference {
    TIRSignal signal;
    TypedExpression expression;
};

using HierarchyReferences = std::map<std::string, HierarchyReference>;

static void add_hierarchy_port(HierarchyReferences& references, const std::string& instance,
                               const elaboration::TypedSignal& formal, TypedExpression expression) {
    const auto name = instance + "." + formal.name;
    expression.is_signed = formal.is_signed;
    references.emplace(name, HierarchyReference{
        TIRSignal{name, formal.width, formal.is_signed, "hierarchical_port", formal.location,
                  formal.packed_left_index, formal.packed_right_index},
        std::move(expression)});
}

static void lower_top_checks(
    TIRModule& result, const frontend::ParsedModule& selected, const frontend::SyntaxUnit& selected_unit,
    const std::map<std::string, TIRSignal>& signals,
    const std::map<std::string, TIRConstant>& constants,
    const std::vector<frontend::SyntaxUnit>& source_units,
    const HierarchyReferences* references) {
    HistoryStateLowerer history_state_lowerer(result);
    for (auto& property : result.properties) {
        for (auto& term : property.antecedent.terms) {
            term.predicate = history_state_lowerer.lower_past_nodes(
                term.predicate);
        }
        if (property.consequent) {
            for (auto& term : property.consequent->terms) {
                term.predicate = history_state_lowerer.lower_past_nodes(
                    term.predicate);
            }
        }
        build_sva_sequence_automaton(property.antecedent);
        if (property.consequent) {
            build_sva_sequence_automaton(*property.consequent);
        }
    }
    const auto root_prefix = "$root." + selected.name + ".";
    const auto resolve_root = [&](const std::string& name, const frontend::SourceLocation& location) {
        if (name.compare(0, 6, "$root.") != 0) return name;
        if (name.compare(0, root_prefix.size(), root_prefix) != 0) {
            throw LoweringError(location, "property reference '" + name + "' is outside the selected top");
        }
        return name.substr(root_prefix.size());
    };
    std::map<std::string, TIRSignal> standalone_signals;
    if (references) {
        standalone_signals = signals;
        for (const auto& [name, reference] : *references) standalone_signals.emplace(name, reference.signal);
    }
    const auto resolve_port_references = [&](const auto& self, TypedExpression& expression) -> void {
        if (expression.kind == "signal") {
            const auto found = references->find(expression.value);
            if (found != references->end()) {
                const auto location = expression.location;
                expression = found->second.expression;
                expression.location = location;
                return;
            }
        }
        for (auto& operand : expression.operands) self(self, operand);
    };
    const auto lower_checks = [&](const auto& declarations, const auto& checks,
                                  const frontend::SyntaxUnit& unit, bool standalone) {
        const bool four_state = result.semantic_profile == frontend::kFourStateProfile;
        const bool reusable = four_state && !standalone;
        std::map<std::string, const frontend::PropertyDeclarationSyntax*> property_declarations;
        for (const auto& declaration : declarations) {
            if (reusable && (signals.count(declaration.name) || constants.count(declaration.name))) {
                throw LoweringError(declaration.location,
                    "conflicting named property declaration '" + declaration.name + "'");
            }
            if (!property_declarations.emplace(declaration.name, &declaration).second) {
                throw LoweringError(declaration.location,
                    "duplicate property declaration '" + declaration.name + "'");
            }
        }
        SvaSequenceScope sequence_scope;
        if (reusable) {
            for (const auto& declaration : selected.sequence_declarations) {
                if (signals.count(declaration.name) || constants.count(declaration.name) ||
                    property_declarations.count(declaration.name) ||
                    !sequence_scope.declarations.emplace(declaration.name, declaration.body).second) {
                    throw LoweringError(declaration.location,
                        "conflicting named sequence declaration '" + declaration.name + "'");
                }
            }
        }
        for (std::size_t index = 0; index < checks.size(); ++index) {
            const auto& check = checks[index];
            std::string property_name = "property_check_" + std::to_string(index + 1);
            std::string clock;
            frontend::ExpressionSpan sequence_span;
            if (check.sequence) {
                if (standalone && !check.label) {
                    throw LoweringError(check.location, "standalone inline property checks require a label");
                }
                sequence_span = *check.sequence;
                if (!check.clock) {
                    throw LoweringError(check.location,
                        "inline property check has no bound clock");
                }
                clock = *check.clock;
            } else if (check.property_reference) {
                property_name = *check.property_reference;
                const auto declaration = property_declarations.find(property_name);
                if (declaration == property_declarations.end()) {
                    throw LoweringError(check.location,
                        "unresolved property reference '" + property_name + "'");
                }
                sequence_span = declaration->second->sequence;
                clock = declaration->second->clock;
            } else {
                throw LoweringError(check.location,
                    "property check has neither an inline sequence nor a property reference");
            }
            if (reusable) {
                std::set<std::string> expanded;
                if (check.property_reference) expanded.insert(*check.property_reference);
                for (;;) {
                    const auto body = strip_outer_parentheses(sequence_span, unit.tokens);
                    const auto count = body.after_last_token - body.first_token;
                    const bool empty_call = count == 3 &&
                        unit.tokens[body.first_token + 1].text == "(" &&
                        unit.tokens[body.first_token + 2].text == ")";
                    if (count != 1 && !empty_call) break;
                    const auto& name = unit.tokens[body.first_token];
                    const auto reference = property_declarations.find(name.text);
                    if (reference == property_declarations.end()) break;
                    if (!expanded.insert(name.text).second || expanded.size() > 128) {
                        throw LoweringError(name.location,
                            "recursive or excessively nested named property '" + name.text + "'");
                    }
                    const auto& declared = *reference->second;
                    if (!declared.clock.empty()) {
                        if (!clock.empty() && clock != declared.clock) {
                            throw LoweringError(name.location, "conflicting named property clocks",
                                frontend::InputDiagnosticKind::Unsupported);
                        }
                        clock = declared.clock;
                    }
                    sequence_span = declared.sequence;
                }
                if (clock.empty()) {
                    throw LoweringError(check.location, "named property requires one explicit sampling clock",
                        frontend::InputDiagnosticKind::Unsupported);
                }
            }
            if (check.label) property_name = *check.label;
            if (standalone) {
                clock = resolve_root(clock, check.location);
                const auto alias = references->find(clock);
                if (alias != references->end() && alias->second.expression.kind == "signal") {
                    clock = alias->second.expression.value;
                }
            }
            const auto clock_signal = signals.find(clock);
            if (clock_signal == signals.end() || clock_signal->second.role != "input" ||
                clock_signal->second.width != 1) {
                throw LoweringError(check.location,
                    "SVA clock must resolve to a declared one-bit input port");
            }
            if (std::find(result.clocks.begin(), result.clocks.end(), clock) ==
                result.clocks.end()) {
                result.clocks.push_back(clock);
            }
            if (result.clocks.size() > 1) {
                throw LoweringError(check.location,
                    "multi-clock lowering is outside the Phase 0 profile",
                    frontend::InputDiagnosticKind::Unsupported);
            }
            std::vector<frontend::Token> scoped_tokens;
            if (standalone) {
                for (auto token_index = sequence_span.first_token; token_index < sequence_span.after_last_token;) {
                    auto token = unit.tokens[token_index];
                    const auto qualified = unit.hierarchical_operands.find(token_index);
                    if (qualified == unit.hierarchical_operands.end()) {
                        ++token_index;
                    } else {
                        token_index = qualified->second.first;
                        token.text = resolve_root(qualified->second.second, token.location);
                    }
                    scoped_tokens.push_back(std::move(token));
                }
                sequence_span = {0, scoped_tokens.size()};
            }
            sequence_scope.expansions = 0;
            auto lowered = lower_sva_property(sequence_span, standalone ? scoped_tokens : unit.tokens,
                standalone ? standalone_signals : signals, constants, four_state,
                four_state && !standalone ? &sequence_scope : nullptr);
            for (auto& term : lowered.antecedent.sequence.terms) {
                if (standalone) resolve_port_references(resolve_port_references, term.predicate);
                term.predicate = history_state_lowerer.lower_past_nodes(
                    term.predicate);
            }
            if (lowered.consequent) {
                for (auto& term : lowered.consequent->sequence.terms) {
                    if (standalone) resolve_port_references(resolve_port_references, term.predicate);
                    term.predicate = history_state_lowerer.lower_past_nodes(
                        term.predicate);
                }
            }
            build_sva_sequence_automaton(lowered.antecedent.sequence);
            if (lowered.consequent) {
                build_sva_sequence_automaton(lowered.consequent->sequence);
            }
            std::string property_kind;
            switch (check.kind) {
            case frontend::PropertyCheckKind::Assert: property_kind = "assert"; break;
            case frontend::PropertyCheckKind::Assume: property_kind = "assume"; break;
            case frontend::PropertyCheckKind::Cover: property_kind = "cover"; break;
            }
            const auto history_delay = std::max(
                lowered.antecedent.maximum_past_delay,
                lowered.consequent
                    ? lowered.consequent->maximum_past_delay : std::uint64_t{0});
            TIRProperty property;
            property.name = property_name;
            property.kind = property_kind;
            property.clock = clock;
            property.implication = lowered.implication;
            property.split_history_guards = true;
            if (!four_state) {
                property.history_guard_delay = history_delay;
                property.antecedent_history_guard_delay = lowered.antecedent.required_history_warmup;
                property.consequent_history_guard_delay = lowered.consequent
                    ? lowered.consequent->required_history_warmup : 0;
            }
            property.antecedent = std::move(lowered.antecedent.sequence);
            if (lowered.consequent) {
                property.consequent = std::move(lowered.consequent->sequence);
            }
            property.location = check.location;
            for (const auto delay : {property.history_guard_delay,
                     property.antecedent_history_guard_delay,
                     property.consequent_history_guard_delay}) {
                if (delay == 0) continue;
                const auto existing = std::find_if(result.history_guards.begin(),
                    result.history_guards.end(), [&](const TIRHistoryGuard& guard) {
                        return guard.clock == clock && guard.delay == delay;
                    });
                if (existing == result.history_guards.end()) {
                    result.history_guards.push_back(TIRHistoryGuard{clock,
                        delay, {}, {}});
                }
            }
            append_named_property(result, std::move(property));
        }
    };
    lower_checks(selected.property_declarations, selected.property_checks, selected_unit, false);
    if (references) {
        for (const auto& unit : source_units) {
            lower_checks(unit.standalone_declarations, unit.standalone_checks, unit, true);
        }
    }
    history_state_lowerer.finalize();
}

static TIRModule lower_module(
    const std::vector<frontend::SyntaxUnit>& source_units,
    const elaboration::ElaborationResult& elaborated,
    HierarchyReferences* references, bool attach_standalone,
    std::map<std::string, std::string>* event_domain_owners = nullptr) {
    const frontend::ParsedModule* selected = nullptr;
    const frontend::SyntaxUnit* selected_unit = nullptr;
    std::size_t matches = 0;
    for (const auto& unit : source_units) {
        for (const auto& module : unit.modules) {
            if (module.name == elaborated.top.name) {
                selected = &module;
                selected_unit = &unit;
                ++matches;
            }
        }
    }
    if (matches != 1 || selected == nullptr || selected_unit == nullptr) {
        const auto location = source_units.empty() || source_units.front().tokens.empty()
            ? frontend::SourceLocation{"<project>", 1, 1, 0}
            : source_units.front().tokens.front().location;
        throw LoweringError(location,
            "top module syntax does not resolve uniquely for T016 lowering");
    }
    if (!supported_generate_tree(selected->generate_items)) {
        const auto* unsupported = find_unsupported_generate_node(
            selected->generate_items);
        throw LoweringError(unsupported ? unsupported->location : selected->location,
            "T016 supports static generate blocks with module instances, scoped bit/logic and integral constant declarations, or supported continuous assignments");
    }
    static const std::set<std::string> unsupported_process_tokens{
        "negedge"
    };
    for (auto index = selected->first_token;
         index < selected->after_last_token && index < selected_unit->tokens.size();
         ++index) {
        if (unsupported_process_tokens.find(
                selected_unit->tokens[index].text) !=
            unsupported_process_tokens.end()) {
            throw LoweringError(selected_unit->tokens[index].location,
                "this T016 slice does not support the selected process/property construct",
                frontend::InputDiagnosticKind::Unsupported);
        }
    }

    TIRModule result;
    result.semantic_profile = elaborated.profile_id;
    const bool four_state = result.semantic_profile == frontend::kFourStateProfile;
    result.input_hash = elaborated.input_hash;
    result.name = elaborated.top.name;
    std::map<std::string, TIRSignal> signals;
    for (const auto& port : elaborated.top.ports) {
        const std::string role = port.direction == frontend::PortDirection::Input
            ? "input" : "output";
        TIRSignal signal{port.name, port.width, port.is_signed, role,
                         port.location};
        signal.packed_left_index = port.packed_left_index;
        signal.packed_right_index = port.packed_right_index;
        signals.emplace(signal.name, signal);
        result.signals.push_back(std::move(signal));
    }
    for (const auto& source_signal : elaborated.top.signals) {
        TIRSignal signal{source_signal.name, source_signal.width,
                         source_signal.is_signed, "internal",
                         source_signal.location};
        signal.packed_left_index = source_signal.packed_left_index;
        signal.packed_right_index = source_signal.packed_right_index;
        if (!signals.emplace(signal.name, signal).second) {
            throw LoweringError(source_signal.location,
                "duplicate signal name in the elaborated symbol table");
        }
        result.signals.push_back(std::move(signal));
    }
    for (const auto& scope : elaborated.top.generate_scopes) {
        if (scope.declared_constant) {
            const auto& constant = *scope.declared_constant;
            result.parameters.push_back(TIRConstant{constant.name, "localparam",
                constant.value, constant.width, constant.is_signed, constant.location, constant.packed_bounds});
        }
        if (!scope.declared_signal) continue;
        const auto& source_signal = *scope.declared_signal;
        TIRSignal signal{source_signal.name, source_signal.width,
                         source_signal.is_signed, "internal",
                         source_signal.location};
        signal.packed_left_index = source_signal.packed_left_index;
        signal.packed_right_index = source_signal.packed_right_index;
        if (!signals.emplace(signal.name, signal).second) {
            throw LoweringError(source_signal.location,
                "duplicate generated signal name in the elaborated symbol table");
        }
        result.signals.push_back(std::move(signal));
    }

    std::map<std::string, TIRConstant> constants;
    for (const auto& parameter : elaborated.top.parameters) {
        TIRConstant constant{parameter.name, "parameter", parameter.value, parameter.width,
                             parameter.is_signed, parameter.location, parameter.packed_bounds};
        constants.emplace(constant.name, constant);
        result.parameters.push_back(std::move(constant));
    }
    for (const auto& localparam : elaborated.top.localparams) {
        TIRConstant constant{localparam.name, "localparam", localparam.value, localparam.width,
                             localparam.is_signed, localparam.location, localparam.packed_bounds};
        if (!constants.emplace(constant.name, constant).second) {
            throw LoweringError(localparam.location,
                "duplicate constant name in the elaborated symbol table");
        }
        result.parameters.push_back(std::move(constant));
    }

    std::set<std::string> driven_targets;
    std::set<std::string> sequential_targets;
    std::map<std::string, frontend::SourceLocation> driver_locations;
    std::map<std::string, std::string> driver_kinds;
    const auto format_location = [](const frontend::SourceLocation& location) {
        return location.file + ":" + std::to_string(location.line) + ":" +
            std::to_string(location.column);
    };
    struct ChildOutputBitDrivers {
        std::uint64_t target_width = 0;
        std::vector<std::optional<TypedExpression>> bits;
        std::set<std::uint64_t> reserved_bits;
        frontend::SourceLocation location;
    };
    std::map<std::string, ChildOutputBitDrivers> child_output_bit_drivers;
    struct ChildOutputBitBinding {
        std::string proxy_signal;
        std::string target_signal;
        std::uint64_t target_offset = 0;
        frontend::SourceLocation location;
        std::uint64_t slice_width = 1;
    };
    for (const auto& process : selected->processes) {
        std::set<std::string> process_targets;
        collect_process_targets(process.body, selected_unit->tokens,
                                process_targets);
        std::map<std::string, frontend::SourceLocation>
            process_target_locations;
        collect_process_target_locations(process.body, selected_unit->tokens,
                                         process_target_locations);
        if (process_targets.empty()) {
            throw LoweringError(process.location,
                "procedural process has no whole-signal assignments");
        }
        for (const auto& target_name : process_targets) {
            const auto target = signals.find(target_name);
            if (target == signals.end() || target->second.role == "input") {
                throw LoweringError(process.location,
                    "procedural target '" + target_name +
                    "' is not a writable declared signal");
            }
        }

        if (process.kind == frontend::ProcessKind::AlwaysComb) {
            if (process.clock) {
                throw LoweringError(process.location,
                    "always_comb cannot carry a clock in the Phase 0 grammar");
            }
            for (const auto& target_name : process_targets) {
                const auto target_location = process_target_locations.find(
                    target_name);
                const auto conflicting_location = target_location ==
                    process_target_locations.end() ? process.location :
                    target_location->second;
                const auto first_driver = driver_locations.find(target_name);
                if (sequential_targets.find(target_name) !=
                        sequential_targets.end() ||
                    driven_targets.find(target_name) != driven_targets.end()) {
                    std::string message = "multiple processes drive signal '" +
                        target_name + "'";
                    if (first_driver != driver_locations.end()) {
                        message += "; first driver at " +
                            format_location(first_driver->second);
                    }
                    message += "; conflicting driver at " +
                        format_location(conflicting_location);
                    throw LoweringError(conflicting_location, message);
                }
                driven_targets.insert(target_name);
                driver_locations.emplace(target_name, conflicting_location);
                driver_kinds.emplace(target_name, "always_comb process");
            }
            CombinationalEnvironment environment;
            for (const auto& [name, signal] : signals) {
                environment.values.emplace(name, TypedExpression{"signal", name,
                    signal.width, signal.is_signed, signal.location, {}});
                environment.assigned.emplace(name, false);
            }
            lower_combinational_statement(process.body, process_targets,
                selected_unit->tokens, signals, constants, environment, four_state);
            for (const auto& target_name : process_targets) {
                if (!environment.assigned[target_name]) {
                    throw LoweringError(process.location,
                        "always_comb signal '" + target_name +
                        "' is not assigned on every control path; latch semantics are unsupported",
                        frontend::InputDiagnosticKind::Unsupported);
                }
                const auto& target = signals.at(target_name);
                result.combinational_equations.push_back(TIREquation{
                    target_name, target.width, environment.values.at(target_name),
                    process.location});
            }
            continue;
        }
        if (!process.clock) {
            throw LoweringError(process.location,
                                   "always_ff process has no bound clock");
        }
        if (std::find(result.clocks.begin(), result.clocks.end(), *process.clock) ==
            result.clocks.end()) {
            result.clocks.push_back(*process.clock);
        }
        if (result.clocks.size() > 1 && !event_domain_owners) {
            throw LoweringError(process.location,
                                   "multi-clock lowering is outside the Phase 0 profile",
                                   frontend::InputDiagnosticKind::Unsupported);
        }
        const auto clock = signals.find(*process.clock);
        if (clock == signals.end() || clock->second.role != "input" ||
            clock->second.width != 1) {
            throw LoweringError(process.location,
                "always_ff clock must be a declared one-bit input port");
        }
        for (const auto& target_name : process_targets) {
            const auto target_location = process_target_locations.find(
                target_name);
            const auto conflicting_location = target_location ==
                process_target_locations.end() ? process.location :
                target_location->second;
            const auto first_driver = driver_locations.find(target_name);
            if (driven_targets.find(target_name) != driven_targets.end() ||
                sequential_targets.find(target_name) !=
                    sequential_targets.end()) {
                std::string message = "multiple processes drive state signal '" +
                    target_name + "'";
                if (first_driver != driver_locations.end()) {
                    message += "; first driver at " +
                        format_location(first_driver->second);
                }
                message += "; conflicting driver at " +
                    format_location(conflicting_location);
                throw LoweringError(conflicting_location, message);
            }
            sequential_targets.insert(target_name);
            driver_locations.emplace(target_name, conflicting_location);
            driver_kinds.emplace(target_name, "always_ff process");
            auto target = signals.find(target_name);
            if (target == signals.end() || target->second.role == "input") {
                throw LoweringError(process.location,
                    "always_ff target '" + target_name +
                    "' is not a writable declared signal");
            }
            target->second.role = "state";
            for (auto& signal : result.signals) {
                if (signal.name == target_name) signal.role = "state";
            }
            auto hold = TypedExpression{"signal", target_name,
                target->second.width, target->second.is_signed,
                process.location, {}};
            auto next_value = lower_process_statement(process.body, target_name,
                target->second, selected_unit->tokens, signals, constants,
                std::move(hold), four_state);
            if (event_domain_owners) event_domain_owners->emplace(target_name, *process.clock);
            result.next_state_equations.push_back(TIREquation{
                target_name, target->second.width, std::move(next_value),
                process.location});
        }
    }

    const auto lower_module_assignments = [&](const frontend::ParsedModule& module,
            const frontend::SyntaxUnit& unit,
            const std::map<std::string, TIRSignal>& module_signals,
            const std::map<std::string, TIRConstant>& module_constants,
            const std::map<std::string, TypedExpression>& module_expression_aliases,
            const std::vector<elaboration::GenerateResolution>& module_generate_scopes) {
        std::map<std::string, std::vector<std::optional<TypedExpression>>>
            bit_drivers;
        std::map<std::string, frontend::SourceLocation> bit_driver_locations;
        std::map<std::string,
            std::vector<std::optional<frontend::SourceLocation>>>
            bit_driver_source_locations;
        std::set<std::string> whole_targets;
        const auto lower_assignment = [&](const frontend::ContinuousAssignmentSyntax& assignment,
                const std::map<std::string, TIRConstant>& assignment_constants,
                const std::map<std::string, TIRSignal>& assignment_signals) {
            const auto& lvalue = assignment.lvalue;
            if (lvalue.first_token >= lvalue.after_last_token ||
                lvalue.first_token >= unit.tokens.size() ||
                unit.tokens[lvalue.first_token].kind !=
                    frontend::TokenKind::Identifier) {
                throw LoweringError(assignment.location,
                    "continuous-assignment target must begin with a declared signal name");
            }
            const auto& target_key = unit.tokens[lvalue.first_token].text;
            const auto target_symbol = assignment_signals.find(target_key);
            if (target_symbol == assignment_signals.end()) {
                throw LoweringError(assignment.location,
                    "continuous assignment target '" + target_key +
                    "' is not declared in the lowered module scope");
            }
            const auto& target_name = target_symbol->second.name;
            const auto target = signals.find(target_name);
            if (target == signals.end()) {
                throw LoweringError(assignment.location,
                    "continuous assignment target '" + target_name +
                    "' does not resolve to a top-level signal");
            }
            if (target_symbol->second.role == "input" ||
                target->second.role == "input") {
                throw LoweringError(assignment.location,
                    "continuous assignment cannot drive input port '" + target_name + "'");
            }

            bool selected_target = false;
            std::uint64_t selected_width = target_symbol->second.width;
            std::uint64_t target_offset = 0;
            if (lvalue.after_last_token != lvalue.first_token + 1) {
                if (lvalue.first_token + 2 >= lvalue.after_last_token ||
                    unit.tokens[lvalue.first_token + 1].text != "[" ||
                    unit.tokens[lvalue.after_last_token - 1].text != "]") {
                    throw LoweringError(assignment.location,
                        "only whole-signal and single constant bit/part-select continuous-assignment targets are supported");
                }
                const auto open = lvalue.first_token + 1;
                std::size_t close = open + 1;
                unsigned int nested_brackets = 1;
                for (; close < lvalue.after_last_token; ++close) {
                    if (unit.tokens[close].text == "[") ++nested_brackets;
                    else if (unit.tokens[close].text == "]" &&
                             --nested_brackets == 0) break;
                }
                if (close != lvalue.after_last_token - 1) {
                    throw LoweringError(assignment.location,
                        "multiple or malformed lvalue selects are outside the current T016 slice");
                }
                for (auto index = open + 1; index < close; ++index) {
                    if (unit.tokens[index].text != ":") continue;
                    if (index + 1 >= close ||
                        std::find_if(unit.tokens.begin() +
                                static_cast<std::ptrdiff_t>(index + 1),
                            unit.tokens.begin() +
                                static_cast<std::ptrdiff_t>(close),
                            [](const frontend::Token& token) {
                                return token.text == ":";
                            }) != unit.tokens.begin() +
                                static_cast<std::ptrdiff_t>(close)) {
                        throw LoweringError(unit.tokens[index].location,
                            "part-select assignment target must have exactly two bounds");
                    }
                    const frontend::ExpressionSpan left_span{open + 1, index};
                    const frontend::ExpressionSpan right_span{index + 1, close};
                    ExpressionParser left_parser(unit.tokens, left_span,
                        assignment_signals, assignment_constants, 32);
                    ExpressionParser right_parser(unit.tokens, right_span,
                        assignment_signals, assignment_constants, 32);
                    const auto left_expression = left_parser.parse();
                    const auto right_expression = right_parser.parse();
                    std::int64_t left_index = 0;
                    std::int64_t right_index = 0;
                    try {
                        left_index = left_parser.evaluate_constant_integer(
                            left_expression);
                        right_index = right_parser.evaluate_constant_integer(
                            right_expression);
                    } catch (const LoweringError&) {
                        throw LoweringError(unit.tokens[index].location,
                            "part-select assignment bounds must resolve to compile-time constants");
                    }
                    if (!target_symbol->second.packed_left_index.has_value() ||
                        !target_symbol->second.packed_right_index.has_value()) {
                        throw LoweringError(assignment.location,
                            "part-select assignment target requires a declared packed vector with known bounds");
                    }
                    const auto declared_left =
                        *target_symbol->second.packed_left_index;
                    const auto declared_right =
                        *target_symbol->second.packed_right_index;
                    const auto minimum_index = std::min(declared_left,
                                                         declared_right);
                    const auto maximum_index = std::max(declared_left,
                                                         declared_right);
                    if (left_index < minimum_index ||
                        left_index > maximum_index ||
                        right_index < minimum_index ||
                        right_index > maximum_index) {
                        throw LoweringError(unit.tokens[index].location,
                            "part-select assignment bounds are outside the declared packed range");
                    }
                    if ((declared_left >= declared_right &&
                         left_index < right_index) ||
                        (declared_left < declared_right &&
                         left_index > right_index)) {
                        throw LoweringError(unit.tokens[index].location,
                            "part-select direction must match the declared packed range");
                    }
                    const auto left_unsigned =
                        static_cast<std::uint64_t>(left_index);
                    const auto right_unsigned =
                        static_cast<std::uint64_t>(right_index);
                    const auto distance = left_index >= right_index
                        ? left_unsigned - right_unsigned
                        : right_unsigned - left_unsigned;
                    if (distance == std::numeric_limits<std::uint64_t>::max()) {
                        throw LoweringError(unit.tokens[index].location,
                            "part-select assignment width overflows the lowering limit");
                    }
                    selected_width = distance + 1;
                    target_offset = declared_left >= declared_right
                        ? right_unsigned -
                              static_cast<std::uint64_t>(declared_right)
                        : static_cast<std::uint64_t>(declared_right) -
                              right_unsigned;
                    if (target_offset >= target_symbol->second.width ||
                        selected_width > target_symbol->second.width -
                            target_offset) {
                        throw LoweringError(unit.tokens[index].location,
                            "part-select assignment does not map inside the packed width");
                    }
                    selected_target = true;
                    break;
                }
                const auto has_part_select = std::any_of(
                    unit.tokens.begin() + static_cast<std::ptrdiff_t>(open + 1),
                    unit.tokens.begin() + static_cast<std::ptrdiff_t>(close),
                    [](const frontend::Token& token) {
                        return token.text == ":";
                    });
                if (has_part_select) {
                    if (!selected_target) {
                        throw LoweringError(assignment.location,
                            "part-select assignment bounds are malformed");
                    }
                } else {
                    if (!target_symbol->second.packed_left_index.has_value() ||
                        !target_symbol->second.packed_right_index.has_value()) {
                        throw LoweringError(assignment.location,
                            "bit-select assignment target requires a declared packed vector with known bounds");
                    }
                    const frontend::ExpressionSpan index_span{open + 1, close};
                    ExpressionParser index_parser(unit.tokens, index_span,
                        assignment_signals, assignment_constants, 32);
                    const auto index_expression = index_parser.parse();
                    std::int64_t declared_index = 0;
                    try {
                        declared_index = index_parser.evaluate_constant_integer(
                            index_expression);
                    } catch (const LoweringError&) {
                        throw LoweringError(index_expression.location,
                            "bit-select assignment index must resolve to a compile-time constant");
                    }
                    const auto declared_left =
                        *target_symbol->second.packed_left_index;
                    const auto declared_right =
                        *target_symbol->second.packed_right_index;
                    if (declared_index < std::min(declared_left, declared_right) ||
                        declared_index > std::max(declared_left, declared_right)) {
                        throw LoweringError(index_expression.location,
                            "bit-select assignment index is outside the declared packed range");
                    }
                    target_offset = declared_left >= declared_right
                        ? static_cast<std::uint64_t>(declared_index) -
                              static_cast<std::uint64_t>(declared_right)
                        : static_cast<std::uint64_t>(declared_right) -
                              static_cast<std::uint64_t>(declared_index);
                    if (target_offset >= target_symbol->second.width) {
                        throw LoweringError(index_expression.location,
                            "bit-select assignment index does not map inside the packed width");
                    }
                    selected_width = 1;
                    selected_target = true;
                }
                if (!selected_target) {
                    throw LoweringError(assignment.location,
                        "unsupported or malformed continuous-assignment target select");
                }
            }

            const bool has_sequential_driver =
                sequential_targets.find(target_name) != sequential_targets.end();
            const bool has_other_module_driver =
                driven_targets.find(target_name) != driven_targets.end();
            if (has_sequential_driver || has_other_module_driver) {
                std::string message;
                if (has_sequential_driver) {
                    message = "continuous assignment conflicts with a sequential driver for '" +
                        target_name + "'";
                } else {
                    const auto driver_kind = driver_kinds.find(target_name);
                    if (driver_kind != driver_kinds.end() &&
                        driver_kind->second == "continuous assignment") {
                        message = "multiple continuous assignments or module drivers drive '" +
                            target_name + "'";
                    } else {
                        const auto kind = driver_kind == driver_kinds.end()
                            ? std::string("existing") : driver_kind->second;
                        message = "continuous assignment conflicts with " + kind +
                            " for '" + target_name + "'";
                    }
                }
                const auto first_driver = driver_locations.find(target_name);
                if (first_driver != driver_locations.end()) {
                    message += "; first driver at " +
                        format_location(first_driver->second);
                }
                message += "; conflicting driver at " +
                    format_location(assignment.location);
                throw LoweringError(assignment.location, message);
            }
            if (child_output_bit_drivers.find(target_name) !=
                    child_output_bit_drivers.end()) {
                throw LoweringError(assignment.location,
                    "continuous assignment conflicts with child output bit-select drivers for '" +
                    target_name + "'");
            }
            if (selected_target && whole_targets.find(target_name) !=
                    whole_targets.end()) {
                throw LoweringError(assignment.location,
                    "whole-signal and bit-select assignments both drive '" +
                    target_name + "'");
            }
            if (!selected_target && bit_drivers.find(target_name) !=
                    bit_drivers.end()) {
                throw LoweringError(assignment.location,
                    "whole-signal and bit-select assignments both drive '" +
                    target_name + "'");
            }
            auto expression = ExpressionParser(unit.tokens,
                assignment.expression, assignment_signals, assignment_constants,
                selected_target ? selected_width :
                    target_symbol->second.width, four_state).parse(true);
            const auto rewrite_module_signal_aliases =
                [&](const auto& self, TypedExpression& node) -> void {
                    if (node.kind == "signal") {
                        const auto expression_alias =
                            module_expression_aliases.find(node.value);
                        if (expression_alias != module_expression_aliases.end()) {
                            auto actual = expression_alias->second;
                            convert_context_operand(actual, node.width, node.is_signed);
                            node = std::move(actual);
                            return;
                        }
                        const auto alias = assignment_signals.find(node.value);
                        if (alias != assignment_signals.end()) {
                            node.value = alias->second.name;
                        }
                    }
                    for (auto& operand : node.operands) {
                        self(self, operand);
                    }
                };
            rewrite_module_signal_aliases(rewrite_module_signal_aliases,
                                           expression);
            expression = resize_assignment(std::move(expression),
                selected_target ? selected_width : target_symbol->second.width,
                !selected_target && target_symbol->second.is_signed);

            if (selected_target) {
                auto [drivers, inserted] = bit_drivers.try_emplace(target_name,
                    static_cast<std::size_t>(target_symbol->second.width));
                auto [source_locations, locations_inserted] =
                    bit_driver_source_locations.try_emplace(target_name,
                        static_cast<std::size_t>(target_symbol->second.width));
                if (inserted) {
                    bit_driver_locations.emplace(target_name,
                                                  assignment.location);
                }
                (void)locations_inserted;
                for (std::uint64_t bit = 0; bit < selected_width; ++bit) {
                    const auto packed_offset = target_offset + bit;
                    const auto packed_index =
                        static_cast<std::size_t>(packed_offset);
                    auto& driver = drivers->second[packed_index];
                    if (driver.has_value()) {
                        std::string message =
                            "multiple continuous assignments drive packed bit offset " +
                            std::to_string(packed_offset) + " of '" + target_name + "'";
                        const auto& first_driver =
                            source_locations->second[packed_index];
                        if (first_driver.has_value()) {
                            message += "; first driver at " +
                                format_location(*first_driver);
                        }
                        message += "; conflicting driver at " +
                            format_location(assignment.location);
                        throw LoweringError(assignment.location, message);
                    }
                    source_locations->second[packed_index] = assignment.location;
                    if (selected_width == 1) {
                        driver = std::move(expression);
                    } else {
                        TypedExpression source_offset{"constant",
                            std::to_string(bit), 32, false,
                            assignment.location, {}};
                        driver = TypedExpression{"select", "bit", 1, false,
                            assignment.location, {expression,
                                                  std::move(source_offset)}};
                    }
                }
                return;
            }

            driven_targets.insert(target_name);
            driver_locations.emplace(target_name, assignment.location);
            driver_kinds.emplace(target_name, "continuous assignment");
            whole_targets.insert(target_name);
            result.combinational_equations.push_back(TIREquation{
                target_name, target_symbol->second.width, std::move(expression),
                assignment.location});
        };

        for (const auto& assignment : module.continuous_assignments) {
            lower_assignment(assignment, module_constants, module_signals);
        }
        for (const auto& scope : module_generate_scopes) {
            if (scope.kind != "assignment") continue;
            const auto* assignment = find_generated_assignment(
                module.generate_items, scope.location);
            if (assignment == nullptr) {
                throw LoweringError(scope.location,
                    "active generated continuous assignment could not be mapped to source syntax");
            }
            auto assignment_constants = module_constants;
            for (const auto& genvar : scope.genvar_values) {
                assignment_constants.insert_or_assign(genvar.first,
                    TIRConstant{genvar.first, "genvar", genvar.second, 32,
                                true, scope.location});
            }
            auto assignment_signals = module_signals;
            for (const auto& [name, value] : scope.scoped_constants) {
                assignment_constants.insert_or_assign(name, TIRConstant{value.name, "localparam",
                    value.value, value.width, value.is_signed, value.location, value.packed_bounds});
                assignment_signals.erase(name);
            }
            std::vector<const elaboration::GenerateResolution*> declarations;
            for (const auto& candidate : module_generate_scopes) {
                if (candidate.kind == "declaration" &&
                    candidate.declared_signal.has_value() &&
                    (candidate.scope_path == scope.path ||
                     (candidate.scope_path.size() < scope.path.size() &&
                      scope.path.compare(0, candidate.scope_path.size(),
                                         candidate.scope_path) == 0 &&
                      scope.path[candidate.scope_path.size()] == '.'))) {
                    declarations.push_back(&candidate);
                }
            }
            std::stable_sort(declarations.begin(), declarations.end(),
                [](const auto* left, const auto* right) {
                    return left->scope_path.size() < right->scope_path.size();
                });
            for (const auto* declaration : declarations) {
                const auto constant = scope.scoped_constants.find(declaration->local_name);
                if (constant != scope.scoped_constants.end() &&
                    declaration->scope_path.size() <= constant->second.name.rfind('.')) {
                    continue;
                }
                const auto signal = module_signals.find(
                    declaration->declared_signal->name);
                if (signal == module_signals.end()) {
                    throw LoweringError(declaration->location,
                        "active generate-local declaration is missing from the flattened signal table");
                }
                assignment_signals.insert_or_assign(declaration->local_name,
                                                     signal->second);
            }
            lower_assignment(*assignment, assignment_constants,
                             assignment_signals);
        }
        for (auto& [target_name, drivers] : bit_drivers) {
            const auto missing = std::find_if(drivers.begin(), drivers.end(),
                [](const auto& driver) { return !driver.has_value(); });
            if (missing != drivers.end()) {
                const auto missing_offset = static_cast<std::uint64_t>(
                    std::distance(drivers.begin(), missing));
                throw LoweringError(bit_driver_locations.at(target_name),
                    "bit-select assignments do not cover every bit of '" +
                    target_name + "'; missing packed bit offset " +
                    std::to_string(missing_offset));
            }
            if (sequential_targets.find(target_name) !=
                    sequential_targets.end() ||
                !driven_targets.insert(target_name).second) {
                throw LoweringError(bit_driver_locations.at(target_name),
                    "multiple continuous or sequential drivers drive '" +
                    target_name + "'");
            }
            std::vector<TypedExpression> operands;
            operands.reserve(drivers.size());
            for (auto driver = drivers.rbegin(); driver != drivers.rend();
                 ++driver) {
                operands.push_back(std::move(driver->value()));
            }
            const auto signal = signals.find(target_name);
            if (signal == signals.end()) {
                throw LoweringError(bit_driver_locations.at(target_name),
                    "bit-select driver target disappeared from the flattened signal table");
            }
            auto expression = drivers.size() == 1
                ? std::move(operands.front())
                : TypedExpression{"concatenation", "{}",
                    static_cast<std::uint64_t>(drivers.size()), false,
                    bit_driver_locations.at(target_name), std::move(operands)};
            result.combinational_equations.push_back(TIREquation{
                target_name, signal->second.width, std::move(expression),
                bit_driver_locations.at(target_name)});
        }
    };
    lower_module_assignments(*selected, *selected_unit, signals, constants, {}, elaborated.top.generate_scopes);

    const auto capture_child_output_bit_bindings =
        [&](const std::map<std::string, ChildOutputBitBinding>& bindings) {
        for (const auto& [formal_name, binding] : bindings) {
            (void)formal_name;
            const auto target = signals.find(binding.target_signal);
            if (target == signals.end()) {
                throw LoweringError(binding.location,
                    "child output bit-select parent signal disappeared during lowering");
            }
            const bool sequential_proxy = sequential_targets.find(
                binding.proxy_signal) != sequential_targets.end();
            TypedExpression driver_expression;
            if (sequential_proxy) {
                const auto proxy = signals.find(binding.proxy_signal);
                const auto state_driver = std::find_if(
                    result.next_state_equations.begin(),
                    result.next_state_equations.end(),
                    [&](const TIREquation& equation) {
                        return equation.target == binding.proxy_signal;
                    });
                if (proxy == signals.end() || proxy->second.role != "state" ||
                    proxy->second.width != binding.slice_width ||
                    state_driver == result.next_state_equations.end() ||
                    state_driver->target_width != binding.slice_width ||
                    state_driver->expression.width != binding.slice_width ||
                    std::find_if(std::next(state_driver),
                        result.next_state_equations.end(),
                        [&](const TIREquation& equation) {
                            return equation.target == binding.proxy_signal;
                        }) != result.next_state_equations.end()) {
                    throw LoweringError(binding.location,
                        "sequential child output bit-select proxy must have exactly one one-bit next-state driver");
                }
                driver_expression = TypedExpression{"signal",
                    binding.proxy_signal, proxy->second.width,
                    proxy->second.is_signed, binding.location, {}};
            } else {
                auto driver = std::find_if(result.combinational_equations.begin(),
                    result.combinational_equations.end(),
                    [&](const TIREquation& equation) {
                        return equation.target == binding.proxy_signal;
                    });
                if (driver == result.combinational_equations.end()) {
                    throw LoweringError(binding.location,
                        "child output bit-select proxy has no combinational driver");
                }
                if (std::find_if(std::next(driver), result.combinational_equations.end(),
                        [&](const TIREquation& equation) {
                            return equation.target == binding.proxy_signal;
                        }) != result.combinational_equations.end()) {
                    throw LoweringError(binding.location,
                        "child output bit-select proxy has multiple combinational drivers");
                }
                if (driver->target_width != binding.slice_width ||
                    driver->expression.width != binding.slice_width) {
                    throw LoweringError(binding.location,
                        "child output select proxy driver width must match the connected slice width");
                }
            const auto replace_proxy = [&](const auto& self,
                    TypedExpression& expression) -> void {
                if (expression.kind == "signal" &&
                    expression.value == binding.proxy_signal) {
                    TypedExpression parent_signal{"signal",
                        binding.target_signal, target->second.width,
                        target->second.is_signed, binding.location, {}};
                    TypedExpression offset{"constant",
                        std::to_string(binding.target_offset), 32, false,
                        binding.location, {}};
                    expression = TypedExpression{"select",
                        binding.slice_width == 1 ? "bit" : "part",
                        binding.slice_width, false,
                        binding.location, {std::move(parent_signal),
                                           std::move(offset)}};
                    return;
                }
                for (auto& operand : expression.operands) {
                    self(self, operand);
                }
            };
            driver_expression = std::move(driver->expression);
            result.combinational_equations.erase(driver);
            replace_proxy(replace_proxy, driver_expression);
            for (auto& equation : result.combinational_equations) {
                replace_proxy(replace_proxy, equation.expression);
            }
            for (auto& equation : result.next_state_equations) {
                replace_proxy(replace_proxy, equation.expression);
            }
            for (auto& property : result.properties) {
                const auto replace_sequence_proxy = [&](TIRSequence& sequence) {
                    for (auto& term : sequence.terms) {
                        replace_proxy(replace_proxy, term.predicate);
                    }
                    for (auto& transition : sequence.automaton.transitions) {
                        replace_proxy(replace_proxy, transition.predicate);
                    }
                };
                replace_sequence_proxy(property.antecedent);
                if (property.consequent)
                    replace_sequence_proxy(*property.consequent);
            }
            if (references) {
                for (auto& entry : *references) {
                    auto& reference = entry.second;
                    replace_proxy(replace_proxy, reference.expression);
                    reference.expression.is_signed = reference.signal.is_signed;
                }
            }
            for (auto& [target_name, target_drivers] :
                    child_output_bit_drivers) {
                (void)target_name;
                for (auto& bit : target_drivers.bits) {
                    if (bit.has_value()) replace_proxy(replace_proxy, *bit);
                }
            }

            driven_targets.erase(binding.proxy_signal);
            signals.erase(binding.proxy_signal);
            result.signals.erase(std::remove_if(result.signals.begin(),
                result.signals.end(), [&](const TIRSignal& signal) {
                    return signal.name == binding.proxy_signal;
                }), result.signals.end());
            }
            auto target_drivers = child_output_bit_drivers.find(
                binding.target_signal);
            if (target_drivers == child_output_bit_drivers.end() ||
                binding.target_offset >= target_drivers->second.bits.size() ||
                binding.slice_width > target_drivers->second.bits.size() -
                    binding.target_offset ||
                binding.slice_width != driver_expression.width) {
                throw LoweringError(binding.location,
                    "child output select driver slots do not match the connected slice");
            }
            for (std::uint64_t lane = 0; lane < binding.slice_width; ++lane) {
                const auto target_offset = binding.target_offset + lane;
                auto& bit = target_drivers->second.bits[
                    static_cast<std::size_t>(target_offset)];
                if (bit.has_value()) {
                    throw LoweringError(binding.location,
                        "multiple child output connections drive packed bit offset " +
                        std::to_string(target_offset) + " of '" +
                        binding.target_signal + "'");
                }
                if (binding.slice_width == 1) {
                    bit = driver_expression;
                } else {
                    TypedExpression source_offset{"constant",
                        std::to_string(lane), 32, false,
                        binding.location, {}};
                    bit = TypedExpression{"select", "bit", 1, false,
                        binding.location, {driver_expression,
                                           std::move(source_offset)}};
                }
            }
        }
    };

    struct ParentOutputSelection {
        bool whole_signal = false;
        std::uint64_t target_offset = 0;
        std::uint64_t width = 0;
    };
    const auto resolve_output_actual_selection =
        [&](const frontend::ExpressionSpan& actual_span,
            const TIRSignal& parent_signal,
            std::uint64_t formal_width,
            const std::map<std::string, TIRConstant>& actual_constants,
            const frontend::SourceLocation& location,
            const std::string& context) -> ParentOutputSelection {
        const auto& tokens = selected_unit->tokens;
        if (actual_span.first_token >= actual_span.after_last_token ||
            actual_span.after_last_token > tokens.size() ||
            tokens[actual_span.first_token].kind !=
                frontend::TokenKind::Identifier) {
            throw LoweringError(location,
                context + " must be a whole signal, constant bit-select, or constant part-select");
        }
        if (actual_span.after_last_token == actual_span.first_token + 1) {
            if (parent_signal.width != formal_width) {
                throw LoweringError(location,
                    "hierarchy output width does not exactly match formal port width");
            }
            return ParentOutputSelection{true, 0, formal_width};
        }
        if (actual_span.first_token + 3 > actual_span.after_last_token ||
            tokens[actual_span.first_token + 1].text != "[" ||
            tokens[actual_span.after_last_token - 1].text != "]") {
            throw LoweringError(location,
                context + " must be a whole signal, constant bit-select, or constant part-select");
        }
        if (!parent_signal.packed_left_index.has_value() ||
            !parent_signal.packed_right_index.has_value()) {
            throw LoweringError(location,
                "child output select actual requires a packed parent signal with known bounds");
        }
        const auto open = actual_span.first_token + 1;
        const auto close = actual_span.after_last_token - 1;
        std::optional<std::size_t> colon;
        for (auto index = open + 1; index < close; ++index) {
            if (tokens[index].text == "[") {
                throw LoweringError(tokens[index].location,
                    context + " does not support nested selects");
            }
            if (tokens[index].text == ":") {
                if (colon.has_value()) {
                    throw LoweringError(tokens[index].location,
                        context + " part-select must contain exactly two bounds");
                }
                colon = index;
            }
        }
        const auto evaluate_bound = [&](frontend::ExpressionSpan bound_span,
                                        const std::string& bound_kind) {
            if (bound_span.first_token >= bound_span.after_last_token) {
                throw LoweringError(location,
                    context + " " + bound_kind + " cannot be empty");
            }
            ExpressionParser parser(tokens, bound_span, signals,
                                    actual_constants, 32);
            const auto expression = parser.parse();
            try {
                return parser.evaluate_constant_integer(expression);
            } catch (const LoweringError&) {
                throw LoweringError(expression.location,
                    context + " " + bound_kind +
                    " must resolve to a compile-time constant");
            }
        };
        const auto declared_left = *parent_signal.packed_left_index;
        const auto declared_right = *parent_signal.packed_right_index;
        const auto map_index = [&](std::int64_t index) -> std::uint64_t {
            if (index < std::min(declared_left, declared_right) ||
                index > std::max(declared_left, declared_right)) {
                throw LoweringError(location,
                    context + " select bound is outside the declared packed range");
            }
            return declared_left >= declared_right
                ? static_cast<std::uint64_t>(index) -
                      static_cast<std::uint64_t>(declared_right)
                : static_cast<std::uint64_t>(declared_right) -
                      static_cast<std::uint64_t>(index);
        };

        std::uint64_t selected_width = 1;
        std::uint64_t target_offset = 0;
        if (colon.has_value()) {
            const auto left = evaluate_bound(
                frontend::ExpressionSpan{open + 1, *colon}, "left part-select bound");
            const auto right = evaluate_bound(
                frontend::ExpressionSpan{*colon + 1, close}, "right part-select bound");
            if ((left < right) != (declared_left < declared_right)) {
                throw LoweringError(location,
                    context + " part-select direction must match the declared packed range");
            }
            const auto ul = static_cast<std::uint64_t>(left);
            const auto ur = static_cast<std::uint64_t>(right);
            const auto distance = left >= right ? ul - ur : ur - ul;
            if (distance == std::numeric_limits<std::uint64_t>::max()) {
                throw LoweringError(location,
                    context + " part-select width overflows the lowering limit");
            }
            selected_width = distance + 1;
            if (selected_width != formal_width) {
                throw LoweringError(location,
                    context + " width " + std::to_string(selected_width) +
                    " does not match formal port width " +
                    std::to_string(formal_width));
            }
            target_offset = map_index(right);
        } else {
            if (formal_width != 1) {
                throw LoweringError(location,
                    context + " bit-select requires a one-bit formal output port");
            }
            const auto index = evaluate_bound(
                frontend::ExpressionSpan{open + 1, close}, "bit-select index");
            target_offset = map_index(index);
        }
        if (target_offset >= parent_signal.width ||
            selected_width > parent_signal.width - target_offset) {
            throw LoweringError(location,
                context + " does not map inside the parent signal width");
        }
        return ParentOutputSelection{false, target_offset, selected_width};
    };

    for (const auto& instance : elaborated.top.instances) {
        const auto& connection_unit = instance.binding
            ? source_units.at(instance.binding->source_unit) : *selected_unit;
        const auto* syntax_instance = instance.binding
            ? &connection_unit.binds.at(instance.binding->directive).instance
            : find_source_instance(*selected, instance.location);
        const auto& connection_tokens = connection_unit.tokens;
        if (syntax_instance == nullptr ||
            syntax_instance->module_type != instance.module_type) {
            throw LoweringError(selected->location,
                "T016 hierarchy lowering could not map an elaborated instance to its source syntax");
        }
        std::map<std::string, TIRConstant> instance_constants = constants;
        for (const auto& genvar : instance.generate_variables) {
            instance_constants.insert_or_assign(genvar.first, TIRConstant{
                genvar.first, "genvar", genvar.second, 32, true,
                instance.location});
        }
        for (const auto& [name, value] : instance.scoped_constants) {
            instance_constants.insert_or_assign(name, TIRConstant{value.name, "localparam",
                value.value, value.width, value.is_signed, value.location, value.packed_bounds});
        }
        std::optional<std::map<std::string, TIRSignal>> scoped_input_signals;
        if (!instance.scoped_constants.empty()) {
            scoped_input_signals = signals;
            for (const auto& [name, value] : instance.scoped_constants) {
                scoped_input_signals->erase(name);
            }
        }
        const auto& instance_input_signals = scoped_input_signals ? *scoped_input_signals : signals;

        const frontend::ParsedModule* child_module = nullptr;
        const frontend::SyntaxUnit* child_unit = nullptr;
        for (const auto& unit : source_units) {
            for (const auto& candidate : unit.modules) {
                if (candidate.name == instance.module_type) {
                    if (child_module != nullptr) {
                        throw LoweringError(syntax_instance->location,
                            "child module name is ambiguous across source units");
                    }
                    child_module = &candidate;
                    child_unit = &unit;
                }
            }
        }
        if (child_module == nullptr || child_unit == nullptr) {
            throw LoweringError(syntax_instance->location,
                "T016 hierarchy source module cannot be resolved");
        }
        if (!supported_generate_tree(child_module->generate_items)) {
            const auto* unsupported = find_unsupported_generate_node(
                child_module->generate_items);
            throw LoweringError(unsupported ? unsupported->location : child_module->location,
                "T016 hierarchy slice rejects generated declarations and unsupported generate constructs");
        }
        for (const auto& child_process : child_module->processes) {
            if ((child_process.kind == frontend::ProcessKind::AlwaysComb &&
                 child_process.clock) ||
                (child_process.kind == frontend::ProcessKind::AlwaysFF &&
                 !child_process.clock)) {
                throw LoweringError(child_process.location,
                    "child process has unsupported clock binding");
            }
        }
        if (syntax_instance->port_connections.size() != instance.connections.size()) {
            throw LoweringError(syntax_instance->location,
                "hierarchy source connection count does not match the elaborated instance");
        }
        if (four_state || !instance.child_instances.empty()) {
            elaboration::ElaborationResult nested_elaboration;
            nested_elaboration.profile_id = elaborated.profile_id;
            nested_elaboration.input_hash = elaborated.input_hash;
            nested_elaboration.top.name = instance.module_type;
            nested_elaboration.top.parameters = instance.parameters;
            nested_elaboration.top.localparams = instance.localparams;
            nested_elaboration.top.ports = instance.ports;
            nested_elaboration.top.signals = instance.signals;
            nested_elaboration.top.generate_scopes = instance.generate_scopes;
            nested_elaboration.top.instances = instance.child_instances;
            HierarchyReferences nested_references;
            auto nested_model = lower_module(source_units, nested_elaboration,
                references ? &nested_references : nullptr, false);
            for (auto parameter : nested_model.parameters) {
                parameter.name = instance.instance_name + "." +
                    parameter.name;
                result.parameters.push_back(std::move(parameter));
            }

            std::map<std::string, TypedExpression> nested_inputs;
            std::map<std::string, std::string> nested_outputs;
            std::map<std::string, ChildOutputBitBinding>
                nested_output_bit_bindings;
            std::set<std::string> nested_whole_output_targets;
            std::set<std::string> nested_port_names;
            for (const auto& formal : instance.ports) {
                nested_port_names.insert(formal.name);
            }
            const bool named_connections =
                !syntax_instance->port_connections.empty() &&
                syntax_instance->port_connections.front().formal_name.has_value();
            for (std::size_t index = 0;
                 index < instance.connections.size(); ++index) {
                const auto& connection = instance.connections[index];
                const frontend::PortConnectionSyntax* syntax_connection = nullptr;
                if (named_connections) {
                    const auto found = std::find_if(
                        syntax_instance->port_connections.begin(),
                        syntax_instance->port_connections.end(),
                        [&](const frontend::PortConnectionSyntax& candidate) {
                            return candidate.formal_name == connection.formal_port;
                        });
                    if (found != syntax_instance->port_connections.end()) {
                        syntax_connection = &*found;
                    }
                } else {
                    syntax_connection =
                        &syntax_instance->port_connections[index];
                }
                if (syntax_connection == nullptr ||
                    syntax_connection->actual.first_token >=
                        connection_tokens.size()) {
                    throw LoweringError(syntax_connection == nullptr
                            ? syntax_instance->location
                            : syntax_connection->location,
                        "nested hierarchy connection could not be mapped to a source expression");
                }
                const auto formal = std::find_if(instance.ports.begin(),
                    instance.ports.end(), [&](const elaboration::TypedSignal& port) {
                        return port.name == connection.formal_port;
                    });
                if (formal == instance.ports.end()) {
                    throw LoweringError(syntax_connection->location,
                        "nested hierarchy port cannot be mapped to its formal declaration");
                }
                if (formal->direction == frontend::PortDirection::Input) {
                    auto expression = ExpressionParser(connection_tokens,
                        syntax_connection->actual, instance_input_signals, instance_constants,
                        formal->width, four_state).parse(true);
                    if (expression.width != formal->width) {
                        throw LoweringError(syntax_connection->location,
                            "nested hierarchy input width does not exactly match formal port '" +
                            connection.formal_port + "'");
                    }
                    if (!nested_inputs.emplace(connection.formal_port,
                            std::move(expression)).second) {
                        throw LoweringError(syntax_connection->location,
                            "duplicate nested hierarchy input port");
                    }
                    continue;
                }
                const auto& actual_span = syntax_connection->actual;
                if (actual_span.first_token >= actual_span.after_last_token ||
                    actual_span.first_token >= connection_tokens.size() ||
                    connection_tokens[actual_span.first_token].kind !=
                        frontend::TokenKind::Identifier) {
                    throw LoweringError(syntax_connection->location,
                        "nested hierarchy output actual must be one signal identifier or constant bit-select");
                }
                const auto& actual_name = connection_tokens[
                    actual_span.first_token].text;
                const auto actual = signals.find(actual_name);
                if (actual == signals.end()) {
                    throw LoweringError(syntax_connection->location,
                        "nested hierarchy output actual '" + actual_name +
                        "' is not declared in the parent module");
                }
                const auto output_selection = resolve_output_actual_selection(
                    actual_span, actual->second, formal->width,
                    instance_constants, syntax_connection->location,
                    "nested hierarchy output actual");
                if (!output_selection.whole_signal) {
                    if (actual->second.role == "input" ||
                        driven_targets.find(actual_name) != driven_targets.end() ||
                        sequential_targets.find(actual_name) !=
                            sequential_targets.end() ||
                        nested_whole_output_targets.find(actual_name) !=
                            nested_whole_output_targets.end()) {
                        throw LoweringError(syntax_connection->location,
                            "whole-signal driver conflicts with nested child output bit-select for '" +
                            actual_name + "'");
                    }
                    auto [drivers, inserted] = child_output_bit_drivers.try_emplace(
                        actual_name, ChildOutputBitDrivers{
                            actual->second.width,
                            std::vector<std::optional<TypedExpression>>(
                                static_cast<std::size_t>(actual->second.width)),
                            {}, syntax_connection->location});
                    if (!inserted &&
                        drivers->second.target_width != actual->second.width) {
                        throw LoweringError(syntax_connection->location,
                            "nested child output bit-select parent width changed during hierarchy lowering");
                    }
                    for (std::uint64_t lane = 0;
                         lane < output_selection.width; ++lane) {
                        const auto target_offset =
                            output_selection.target_offset + lane;
                        if (!drivers->second.reserved_bits.insert(
                                target_offset).second) {
                            throw LoweringError(syntax_connection->location,
                                "multiple child output connections drive packed bit offset " +
                                std::to_string(target_offset) + " of '" +
                                actual_name + "'");
                        }
                    }
                    const auto proxy_name = instance.instance_name +
                        (output_selection.width == 1
                            ? ".__nested_output_bit_actual."
                            : ".__nested_output_part_actual.") +
                        connection.formal_port;
                    TIRSignal proxy{proxy_name, output_selection.width,
                        formal->is_signed,
                        "internal", syntax_connection->location};
                    if (!signals.emplace(proxy_name, proxy).second) {
                        throw LoweringError(syntax_connection->location,
                            "duplicate nested child output proxy signal '" +
                            proxy_name + "'");
                    }
                    result.signals.push_back(proxy);
                    if (!nested_outputs.emplace(connection.formal_port,
                            proxy_name).second ||
                        !nested_output_bit_bindings.emplace(
                            connection.formal_port, ChildOutputBitBinding{
                                proxy_name, actual_name,
                                output_selection.target_offset,
                                syntax_connection->location,
                                output_selection.width}).second) {
                        throw LoweringError(syntax_connection->location,
                            "duplicate nested hierarchy output port");
                    }
                    continue;
                }

                if (actual->second.width != formal->width) {
                    throw LoweringError(syntax_connection->location,
                        "nested hierarchy output width does not exactly match formal port '" +
                        connection.formal_port + "'");
                }
                if (child_output_bit_drivers.find(actual_name) !=
                        child_output_bit_drivers.end()) {
                    throw LoweringError(syntax_connection->location,
                        "whole-signal driver conflicts with nested child output bit-select for '" +
                        actual_name + "'");
                }
                if (!nested_whole_output_targets.insert(actual_name).second) {
                    throw LoweringError(syntax_connection->location,
                        "multiple nested child output connections drive whole signal '" +
                        actual_name + "'");
                }
                if (!nested_outputs.emplace(connection.formal_port,
                        actual->second.name).second) {
                    throw LoweringError(syntax_connection->location,
                        "duplicate nested hierarchy output port");
                }
            }

            const auto rewrite_nested_expression =
                [&](const auto& self, TypedExpression& node) -> void {
                    if (node.kind == "signal" || node.kind == "history_ref") {
                        const auto input = nested_inputs.find(node.value);
                        if (node.kind == "signal" &&
                            input != nested_inputs.end()) {
                            const auto formal_width = node.width;
                            const auto formal_signed = node.is_signed;
                            node = input->second;
                            if (four_state) {
                                // Keep the receiving type through subsequent parent substitutions.
                                convert_context_operand(node, formal_width, formal_signed);
                            }
                            return;
                        }
                        const auto output = nested_outputs.find(node.value);
                        if (node.kind == "signal" &&
                            output != nested_outputs.end()) {
                            node.value = output->second;
                            return;
                        }
                        node.value = instance.instance_name + "." +
                            node.value;
                    }
                    for (auto& operand : node.operands) {
                        self(self, operand);
                    }
                };
            if (references) {
                for (const auto& port : instance.ports) {
                    const auto input = nested_inputs.find(port.name);
                    if (input != nested_inputs.end()) {
                        add_hierarchy_port(*references, instance.instance_name, port, input->second);
                    } else {
                        add_hierarchy_port(*references, instance.instance_name, port,
                            TypedExpression{"signal", nested_outputs.at(port.name), port.width,
                                port.is_signed, port.location, {}});
                    }
                }
                for (auto& [name, reference] : nested_references) {
                    rewrite_nested_expression(rewrite_nested_expression, reference.expression);
                    reference.expression.is_signed = reference.signal.is_signed;
                    const auto qualified = instance.instance_name + "." + name;
                    reference.signal.name = qualified;
                    references->emplace(qualified, std::move(reference));
                }
            }
            for (const auto& nested_signal : nested_model.signals) {
                if (nested_port_names.find(nested_signal.name) !=
                    nested_port_names.end()) {
                    continue;
                }
                auto flattened = nested_signal;
                flattened.name = instance.instance_name + "." +
                    nested_signal.name;
                const auto existing = signals.find(flattened.name);
                if (existing != signals.end()) {
                    throw LoweringError(nested_signal.location,
                        "duplicate nested hierarchical signal name '" +
                        flattened.name + "'");
                }
                signals.emplace(flattened.name, flattened);
                result.signals.push_back(std::move(flattened));
            }
            for (auto& equation : nested_model.combinational_equations) {
                const auto output = nested_outputs.find(equation.target);
                if (output != nested_outputs.end()) {
                    equation.target = output->second;
                } else {
                    equation.target = instance.instance_name + "." +
                        equation.target;
                }
                rewrite_nested_expression(rewrite_nested_expression,
                                           equation.expression);
                const auto target = signals.find(equation.target);
                if (target == signals.end() || target->second.role == "input" ||
                    sequential_targets.find(equation.target) !=
                        sequential_targets.end() ||
                    !driven_targets.insert(equation.target).second) {
                    throw LoweringError(syntax_instance->location,
                        "nested hierarchy has an invalid or multiply driven combinational target '" +
                        equation.target + "'");
                }
                result.combinational_equations.push_back(std::move(equation));
            }
            for (auto& equation : nested_model.next_state_equations) {
                const auto output = nested_outputs.find(equation.target);
                if (output != nested_outputs.end()) {
                    equation.target = output->second;
                } else {
                    equation.target = instance.instance_name + "." +
                        equation.target;
                }
                rewrite_nested_expression(rewrite_nested_expression,
                                           equation.expression);
                auto target = signals.find(equation.target);
                if (target == signals.end() || target->second.role == "input" ||
                    driven_targets.find(equation.target) != driven_targets.end() ||
                    !sequential_targets.insert(equation.target).second) {
                    throw LoweringError(syntax_instance->location,
                        "nested hierarchy has an invalid or multiply driven state target '" +
                        equation.target + "'");
                }
                if (target->second.role == "internal" || (four_state && target->second.role == "output")) {
                    target->second.role = "state";
                }
                for (auto& signal : result.signals) {
                    if (signal.name == equation.target) {
                        signal.role = target->second.role;
                    }
                }
                result.next_state_equations.push_back(std::move(equation));
            }
            for (const auto& clock : nested_model.clocks) {
                const auto actual = nested_inputs.find(clock);
                if (actual == nested_inputs.end() ||
                    actual->second.kind != "signal") {
                    throw LoweringError(syntax_instance->location,
                        "nested hierarchy clock must connect directly to a signal");
                }
                const auto clock_signal = signals.find(actual->second.value);
                if (clock_signal == signals.end() ||
                    clock_signal->second.role != "input" ||
                    clock_signal->second.width != 1) {
                    throw LoweringError(syntax_instance->location,
                        "nested hierarchy clock must resolve to a one-bit parent input");
                }
                if (std::find(result.clocks.begin(), result.clocks.end(),
                              actual->second.value) == result.clocks.end()) {
                    result.clocks.push_back(actual->second.value);
                }
                if (result.clocks.size() > 1) {
                    throw LoweringError(syntax_instance->location,
                        "multi-clock lowering is outside the Phase 0 profile",
                        frontend::InputDiagnosticKind::Unsupported);
                }
            }
            const auto map_nested_clock = [&](const std::string& clock_name,
                    const frontend::SourceLocation& location) {
                const auto actual = nested_inputs.find(clock_name);
                if (actual == nested_inputs.end() ||
                    actual->second.kind != "signal" ||
                    actual->second.width != 1) {
                    throw LoweringError(location,
                        "nested child property clock must map directly to a one-bit parent input");
                }
                const auto clock_signal = signals.find(actual->second.value);
                if (clock_signal == signals.end() ||
                    clock_signal->second.role != "input" ||
                    clock_signal->second.width != 1) {
                    throw LoweringError(location,
                        "nested child property clock must resolve to a one-bit top-level input");
                }
                return actual->second.value;
            };
            for (auto property : nested_model.properties) {
                property.clock = map_nested_clock(property.clock,
                                                   property.location);
                property.name = instance.instance_name + "." + property.name;
                const auto rewrite_nested_property_sequence =
                    [&](TIRSequence& sequence) {
                        for (auto& term : sequence.terms) {
                            rewrite_nested_expression(
                                rewrite_nested_expression, term.predicate);
                        }
                        for (auto& transition : sequence.automaton.transitions) {
                            rewrite_nested_expression(
                                rewrite_nested_expression,
                                transition.predicate);
                        }
                    };
                rewrite_nested_property_sequence(property.antecedent);
                if (property.consequent) {
                    rewrite_nested_property_sequence(*property.consequent);
                }
                if (!property.history_guard_signal.empty()) {
                    property.history_guard_signal = instance.instance_name +
                        "." + property.history_guard_signal;
                }
                if (!property.antecedent_history_guard_signal.empty()) {
                    property.antecedent_history_guard_signal =
                        instance.instance_name + "." +
                        property.antecedent_history_guard_signal;
                }
                if (!property.consequent_history_guard_signal.empty()) {
                    property.consequent_history_guard_signal =
                        instance.instance_name + "." +
                        property.consequent_history_guard_signal;
                }
                append_named_property(result, std::move(property));
            }
            for (auto guard : nested_model.history_guards) {
                guard.clock = map_nested_clock(guard.clock,
                                               syntax_instance->location);
                if (!guard.valid_signal.empty()) {
                    guard.valid_signal = instance.instance_name + "." +
                        guard.valid_signal;
                }
                for (auto& state : guard.state_chain) {
                    state = instance.instance_name + "." + state;
                }
                result.history_guards.push_back(std::move(guard));
            }
            capture_child_output_bit_bindings(nested_output_bit_bindings);
            continue;
        }

        std::map<std::string, TIRSignal> child_signals;
        if (instance.signals.size() != child_module->signals.size()) {
            throw LoweringError(child_module->location,
                "child internal signal declarations do not match the elaborated instance");
        }
        for (const auto& local_signal : instance.signals) {
            const auto hierarchical_name = instance.instance_name + "." +
                local_signal.name;
            TIRSignal flattened_signal{hierarchical_name, local_signal.width,
                local_signal.is_signed, "internal", local_signal.location};
            flattened_signal.packed_left_index = local_signal.packed_left_index;
            flattened_signal.packed_right_index = local_signal.packed_right_index;
            if (!signals.emplace(hierarchical_name, flattened_signal).second) {
                throw LoweringError(local_signal.location,
                    "duplicate hierarchical signal name '" + hierarchical_name + "'");
            }
            result.signals.push_back(flattened_signal);
            if (!child_signals.emplace(local_signal.name,
                    std::move(flattened_signal)).second) {
                throw LoweringError(local_signal.location,
                    "duplicate child-local signal name");
            }
        }
        for (const auto& scope : instance.generate_scopes) {
            if (scope.kind != "declaration" || !scope.declared_signal) continue;
            const auto& local_signal = *scope.declared_signal;
            const auto hierarchical_name = instance.instance_name + "." +
                local_signal.name;
            TIRSignal flattened_signal{hierarchical_name, local_signal.width,
                local_signal.is_signed, "internal", local_signal.location};
            flattened_signal.packed_left_index = local_signal.packed_left_index;
            flattened_signal.packed_right_index = local_signal.packed_right_index;
            if (!signals.emplace(hierarchical_name, flattened_signal).second) {
                throw LoweringError(local_signal.location,
                    "duplicate generated hierarchical signal name '" +
                    hierarchical_name + "'");
            }
            result.signals.push_back(flattened_signal);
            if (!child_signals.emplace(local_signal.name,
                    std::move(flattened_signal)).second) {
                throw LoweringError(local_signal.location,
                    "duplicate child generated-signal name");
            }
        }
        std::map<std::string, TypedExpression> child_expression_aliases;
        std::map<std::string, ChildOutputBitBinding> child_output_bindings;
        std::set<std::string> child_whole_output_targets;
        const bool named_connections = !syntax_instance->port_connections.empty() &&
            syntax_instance->port_connections.front().formal_name.has_value();
        for (std::size_t index = 0; index < instance.connections.size(); ++index) {
            const auto& connection = instance.connections[index];
            const frontend::PortConnectionSyntax* syntax_connection = nullptr;
            if (named_connections) {
                const auto found = std::find_if(
                    syntax_instance->port_connections.begin(),
                    syntax_instance->port_connections.end(),
                    [&](const frontend::PortConnectionSyntax& candidate) {
                        return candidate.formal_name == connection.formal_port;
                    });
                if (found != syntax_instance->port_connections.end()) {
                    syntax_connection = &*found;
                }
            } else {
                syntax_connection = &syntax_instance->port_connections[index];
            }
            if (syntax_connection == nullptr ||
                syntax_connection->actual.first_token >=
                    connection_tokens.size()) {
                throw LoweringError(syntax_connection == nullptr
                        ? syntax_instance->location : syntax_connection->location,
                    "T016 hierarchy connection could not be mapped to a source expression");
            }
            const auto formal = std::find_if(instance.ports.begin(),
                instance.ports.end(), [&](const elaboration::TypedSignal& port) {
                    return port.name == connection.formal_port;
                });
            if (formal == instance.ports.end()) {
                throw LoweringError(syntax_connection->location,
                    "elaborated hierarchy port cannot be mapped to its formal declaration");
            }

            if (formal->direction == frontend::PortDirection::Input) {
                auto actual_expression = ExpressionParser(connection_tokens,
                    syntax_connection->actual, instance_input_signals, instance_constants,
                    formal->width).parse(true);
                if (actual_expression.width != formal->width) {
                    throw LoweringError(syntax_connection->location,
                        "hierarchy input expression width does not exactly match formal port '" +
                        connection.formal_port + "'");
                }
                TIRSignal input_alias{connection.formal_port, formal->width,
                    formal->is_signed, "input", formal->location};
                input_alias.packed_left_index = formal->packed_left_index;
                input_alias.packed_right_index = formal->packed_right_index;
                if (!child_signals.emplace(connection.formal_port,
                        std::move(input_alias)).second ||
                    !child_expression_aliases.emplace(connection.formal_port,
                        std::move(actual_expression)).second) {
                    throw LoweringError(syntax_connection->location,
                        "duplicate formal port in hierarchy lowering map");
                }
                continue;
            }

            const auto& actual_span = syntax_connection->actual;
            if (actual_span.first_token >= actual_span.after_last_token ||
                actual_span.first_token >= connection_tokens.size() ||
                connection_tokens[actual_span.first_token].kind !=
                    frontend::TokenKind::Identifier) {
                throw LoweringError(syntax_connection->location,
                    "T016 hierarchy output actual must be one signal identifier or constant bit-select");
            }
            const auto& actual_name = connection_tokens[
                actual_span.first_token].text;
            const auto actual = signals.find(actual_name);
            if (actual == signals.end()) {
                throw LoweringError(syntax_connection->location,
                    "hierarchy output actual '" + actual_name +
                    "' is not a declared top-level signal");
            }
            const auto output_selection = resolve_output_actual_selection(
                actual_span, actual->second, formal->width, instance_constants,
                syntax_connection->location, "hierarchy output actual");
            if (!output_selection.whole_signal) {
                if (actual->second.role == "input" ||
                    driven_targets.find(actual_name) != driven_targets.end() ||
                    sequential_targets.find(actual_name) != sequential_targets.end() ||
                    child_whole_output_targets.find(actual_name) !=
                        child_whole_output_targets.end()) {
                    throw LoweringError(syntax_connection->location,
                        "whole-signal driver conflicts with child output bit-select for '" +
                        actual_name + "'");
                }
                auto [drivers, inserted] = child_output_bit_drivers.try_emplace(
                    actual_name, ChildOutputBitDrivers{
                        actual->second.width,
                        std::vector<std::optional<TypedExpression>>(
                            static_cast<std::size_t>(actual->second.width)),
                        {}, syntax_connection->location});
                if (!inserted && drivers->second.target_width != actual->second.width) {
                    throw LoweringError(syntax_connection->location,
                        "child output bit-select parent width changed during hierarchy lowering");
                }
                for (std::uint64_t lane = 0;
                     lane < output_selection.width; ++lane) {
                    const auto target_offset = output_selection.target_offset + lane;
                    if (!drivers->second.reserved_bits.insert(
                            target_offset).second) {
                        throw LoweringError(syntax_connection->location,
                            "multiple child output connections drive packed bit offset " +
                            std::to_string(target_offset) + " of '" +
                            actual_name + "'");
                    }
                }
                const auto proxy_name = instance.instance_name +
                    (output_selection.width == 1
                        ? ".__output_bit_actual."
                        : ".__output_part_actual.") + connection.formal_port;
                TIRSignal proxy{proxy_name, output_selection.width,
                    formal->is_signed, "internal", syntax_connection->location};
                if (!signals.emplace(proxy_name, proxy).second) {
                    throw LoweringError(syntax_connection->location,
                        "duplicate generated child output proxy signal '" +
                        proxy_name + "'");
                }
                result.signals.push_back(proxy);
                if (!child_signals.emplace(connection.formal_port,
                        std::move(proxy)).second ||
                    !child_output_bindings.emplace(connection.formal_port,
                        ChildOutputBitBinding{proxy_name, actual_name,
                            output_selection.target_offset,
                            syntax_connection->location,
                            output_selection.width}).second) {
                    throw LoweringError(syntax_connection->location,
                        "duplicate formal port in hierarchy lowering map");
                }
                continue;
            }

            if (actual->second.width != formal->width) {
                throw LoweringError(syntax_connection->location,
                    "hierarchy output width does not exactly match formal port '" +
                    connection.formal_port + "'");
            }
            if (child_output_bit_drivers.find(actual_name) !=
                    child_output_bit_drivers.end()) {
                throw LoweringError(syntax_connection->location,
                    "whole-signal driver conflicts with child output bit-select for '" +
                    actual_name + "'");
            }
            if (!child_whole_output_targets.insert(actual_name).second) {
                throw LoweringError(syntax_connection->location,
                    "multiple child output connections drive whole signal '" +
                    actual_name + "'");
            }
            auto alias = actual->second;
            alias.width = formal->width;
            alias.is_signed = formal->is_signed;
            alias.packed_left_index = formal->packed_left_index;
            alias.packed_right_index = formal->packed_right_index;
            if (!child_signals.emplace(connection.formal_port,
                    std::move(alias)).second) {
                throw LoweringError(syntax_connection->location,
                    "duplicate formal port in hierarchy lowering map");
            }
        }
        if (references) {
            for (const auto& port : instance.ports) {
                const auto input = child_expression_aliases.find(port.name);
                if (input != child_expression_aliases.end()) {
                    add_hierarchy_port(*references, instance.instance_name, port, input->second);
                } else {
                    add_hierarchy_port(*references, instance.instance_name, port,
                        TypedExpression{"signal", child_signals.at(port.name).name,
                            port.width, port.is_signed, port.location, {}});
                }
            }
        }
        std::map<std::string, TIRConstant> child_constants;
        const auto add_child_constant = [&](const elaboration::TypedConstant& value,
                                            const std::string& kind) {
            TIRConstant constant{value.name, kind, value.value, value.width,
                value.is_signed, value.location, value.packed_bounds};
            if (!child_constants.emplace(constant.name, constant).second) {
                throw LoweringError(value.location,
                    "duplicate child parameter/localparam name '" + value.name + "'");
            }
            constant.name = instance.instance_name + "." + value.name;
            result.parameters.push_back(std::move(constant));
        };
        for (const auto& parameter : instance.parameters) {
            add_child_constant(parameter, "parameter");
        }
        for (const auto& localparam : instance.localparams) {
            add_child_constant(localparam, "localparam");
        }
        for (const auto& scope : instance.generate_scopes) {
            if (!scope.declared_constant) continue;
            const auto& value = *scope.declared_constant;
            result.parameters.push_back(TIRConstant{
                instance.instance_name + "." + value.name, "localparam", value.value,
                value.width, value.is_signed, value.location, value.packed_bounds});
        }
        lower_module_assignments(*child_module, *child_unit, child_signals,
                                 child_constants, child_expression_aliases,
                                 instance.generate_scopes);

        for (const auto& child_process : child_module->processes) {
            if (child_process.kind == frontend::ProcessKind::AlwaysFF) {
                const auto clock_alias = child_expression_aliases.find(
                    *child_process.clock);
                if (clock_alias == child_expression_aliases.end() ||
                    clock_alias->second.kind != "signal") {
                    throw LoweringError(child_process.location,
                        "child always_ff clock must connect directly to one top-level clock input");
                }
                const auto clock_name = clock_alias->second.value;
                const auto clock_signal = signals.find(clock_name);
                if (clock_signal == signals.end() ||
                    clock_signal->second.role != "input" ||
                    clock_signal->second.width != 1) {
                    throw LoweringError(child_process.location,
                        "child always_ff clock must resolve to a declared one-bit top-level input");
                }
                if (std::find(result.clocks.begin(), result.clocks.end(),
                              clock_name) == result.clocks.end()) {
                    result.clocks.push_back(clock_name);
                }
                if (result.clocks.size() > 1) {
                    throw LoweringError(child_process.location,
                        "multi-clock lowering is outside the Phase 0 profile",
                        frontend::InputDiagnosticKind::Unsupported);
                }

                std::set<std::string> child_targets;
                collect_process_targets(child_process.body, child_unit->tokens,
                                        child_targets);
                if (child_targets.empty()) {
                    throw LoweringError(child_process.location,
                        "child always_ff process has no whole-signal assignments");
                }
                for (const auto& target_key : child_targets) {
                    auto alias = child_signals.find(target_key);
                    if (alias == child_signals.end()) {
                        throw LoweringError(child_process.location,
                            "child always_ff target '" + target_key +
                            "' is not a declared child signal or output port");
                    }
                    const auto target_name = alias->second.name;
                    auto target = signals.find(target_name);
                    if (target == signals.end() || target->second.role == "input" ||
                        alias->second.role == "input") {
                        throw LoweringError(child_process.location,
                            "child always_ff target is not a writable transition signal");
                    }
                    if (driven_targets.find(target_name) != driven_targets.end() ||
                        !sequential_targets.insert(target_name).second) {
                        throw LoweringError(child_process.location,
                            "multiple processes drive state signal '" + target_name + "'");
                    }
                    target->second.role = "state";
                    alias->second.role = "state";
                    for (auto& signal : result.signals) {
                        if (signal.name == target_name) signal.role = "state";
                    }
                    auto hold = TypedExpression{"signal", target_key,
                        target->second.width, target->second.is_signed,
                        child_process.location, {}};
                    auto next_value = lower_process_statement(child_process.body,
                        target_key, alias->second, child_unit->tokens,
                        child_signals, child_constants, std::move(hold));
                    const auto rewrite_child_aliases =
                        [&](const auto& self, TypedExpression& node) -> void {
                            if (node.kind == "signal") {
                                const auto expression_alias =
                                    child_expression_aliases.find(node.value);
                                if (expression_alias !=
                                    child_expression_aliases.end()) {
                                    node = expression_alias->second;
                                    return;
                                }
                                const auto signal_alias =
                                    child_signals.find(node.value);
                                if (signal_alias != child_signals.end()) {
                                    node.value = signal_alias->second.name;
                                }
                            }
                            for (auto& operand : node.operands) {
                                self(self, operand);
                            }
                        };
                    rewrite_child_aliases(rewrite_child_aliases, next_value);
                    result.next_state_equations.push_back(TIREquation{
                        target_name, target->second.width,
                        std::move(next_value), child_process.location});
                }
                continue;
            }

            std::set<std::string> child_targets;
            collect_process_targets(child_process.body, child_unit->tokens,
                                    child_targets);
            if (child_targets.empty()) {
                throw LoweringError(child_process.location,
                    "child always_comb process has no whole-signal assignments");
            }
            for (const auto& target_key : child_targets) {
                const auto alias = child_signals.find(target_key);
                if (alias == child_signals.end()) {
                    throw LoweringError(child_process.location,
                        "child always_comb target '" + target_key +
                        "' is not a connected formal port");
                }
                const auto target = signals.find(alias->second.name);
                if (target == signals.end() || target->second.role == "input" ||
                    alias->second.role == "input") {
                    throw LoweringError(child_process.location,
                        "child always_comb target does not resolve to a writable top-level signal");
                }
                if (sequential_targets.find(alias->second.name) !=
                        sequential_targets.end() ||
                    !driven_targets.insert(alias->second.name).second) {
                    throw LoweringError(child_process.location,
                        "multiple processes or assignments drive '" +
                        alias->second.name + "'");
                }
            }

            CombinationalEnvironment environment;
            for (const auto& [name, signal] : child_signals) {
                const auto expression_alias = child_expression_aliases.find(name);
                if (expression_alias != child_expression_aliases.end()) {
                    environment.values.emplace(name, expression_alias->second);
                } else {
                    environment.values.emplace(name, TypedExpression{"signal",
                        signal.name, signal.width, signal.is_signed,
                        signal.location, {}});
                }
                environment.assigned.emplace(name, false);
            }
            lower_combinational_statement(child_process.body, child_targets,
                child_unit->tokens, child_signals, child_constants, environment);
            for (const auto& target_key : child_targets) {
                if (!environment.assigned[target_key]) {
                    throw LoweringError(child_process.location,
                        "child always_comb signal is not assigned on every control path",
                        frontend::InputDiagnosticKind::Unsupported);
                }
                const auto& target_alias = child_signals.at(target_key);
                result.combinational_equations.push_back(TIREquation{
                    target_alias.name, target_alias.width,
                    environment.values.at(target_key), child_process.location});
            }
        }

        capture_child_output_bit_bindings(child_output_bindings);

        std::map<std::string,
            const frontend::PropertyDeclarationSyntax*> child_property_declarations;
        for (const auto& declaration : child_module->property_declarations) {
            if (!child_property_declarations.emplace(declaration.name,
                    &declaration).second) {
                throw LoweringError(declaration.location,
                    "duplicate child property declaration '" +
                    declaration.name + "'");
            }
        }
        for (std::size_t property_index = 0;
             property_index < child_module->property_checks.size();
             ++property_index) {
            const auto& check = child_module->property_checks[property_index];
            std::string local_property_name = "property_check_" +
                std::to_string(property_index + 1);
            std::string child_clock;
            frontend::ExpressionSpan sequence_span;
            if (check.sequence) {
                sequence_span = *check.sequence;
                if (!check.clock) {
                    throw LoweringError(check.location,
                        "child inline property check has no bound clock");
                }
                child_clock = *check.clock;
            } else if (check.property_reference) {
                local_property_name = *check.property_reference;
                const auto declaration = child_property_declarations.find(
                    local_property_name);
                if (declaration == child_property_declarations.end()) {
                    throw LoweringError(check.location,
                        "unresolved child property reference '" +
                        local_property_name + "'");
                }
                sequence_span = declaration->second->sequence;
                child_clock = declaration->second->clock;
            } else {
                throw LoweringError(check.location,
                    "child property check has neither an inline sequence nor a property reference");
            }
            if (check.label) local_property_name = *check.label;

            const auto clock_alias = child_expression_aliases.find(child_clock);
            if (clock_alias == child_expression_aliases.end() ||
                clock_alias->second.kind != "signal" ||
                clock_alias->second.width != 1) {
                throw LoweringError(check.location,
                    "child SVA clock must connect directly to one top-level clock input");
            }
            const auto clock = clock_alias->second.value;
            const auto clock_signal = signals.find(clock);
            if (clock_signal == signals.end() ||
                clock_signal->second.role != "input" ||
                clock_signal->second.width != 1) {
                throw LoweringError(check.location,
                    "child SVA clock must resolve to a declared one-bit top-level input");
            }
            if (std::find(result.clocks.begin(), result.clocks.end(), clock) ==
                    result.clocks.end()) {
                result.clocks.push_back(clock);
            }
            if (result.clocks.size() > 1) {
                throw LoweringError(check.location,
                    "multi-clock lowering is outside the Phase 0 profile",
                    frontend::InputDiagnosticKind::Unsupported);
            }

            auto lowered = lower_sva_property(sequence_span,
                child_unit->tokens, child_signals, child_constants);
            const auto rewrite_child_property_aliases =
                [&](const auto& self, TypedExpression& expression) -> void {
                if (expression.kind == "signal") {
                    const auto input = child_expression_aliases.find(
                        expression.value);
                    if (input != child_expression_aliases.end()) {
                        expression = input->second;
                        return;
                    }
                    const auto bit_output = child_output_bindings.find(
                        expression.value);
                    if (bit_output != child_output_bindings.end()) {
                        const auto parent = signals.find(
                            bit_output->second.target_signal);
                        if (parent == signals.end()) {
                            throw LoweringError(expression.location,
                                "child property output bit-select parent disappeared during lowering");
                        }
                        TypedExpression parent_signal{"signal",
                            bit_output->second.target_signal, parent->second.width,
                            parent->second.is_signed, expression.location, {}};
                        TypedExpression offset{"constant",
                            std::to_string(bit_output->second.target_offset),
                            32, false, expression.location, {}};
                        expression = TypedExpression{"select",
                            bit_output->second.slice_width == 1
                                ? "bit" : "part",
                            bit_output->second.slice_width, false,
                            expression.location,
                            {std::move(parent_signal), std::move(offset)}};
                        return;
                    }
                    const auto signal_alias = child_signals.find(
                        expression.value);
                    if (signal_alias != child_signals.end()) {
                        expression.value = signal_alias->second.name;
                    }
                }
                for (auto& operand : expression.operands) {
                    self(self, operand);
                }
            };
            for (auto& term : lowered.antecedent.sequence.terms) {
                rewrite_child_property_aliases(
                    rewrite_child_property_aliases, term.predicate);
            }
            if (lowered.consequent) {
                for (auto& term : lowered.consequent->sequence.terms) {
                    rewrite_child_property_aliases(
                        rewrite_child_property_aliases, term.predicate);
                }
            }

            std::string property_kind;
            switch (check.kind) {
            case frontend::PropertyCheckKind::Assert:
                property_kind = "assert";
                break;
            case frontend::PropertyCheckKind::Assume:
                property_kind = "assume";
                break;
            case frontend::PropertyCheckKind::Cover:
                property_kind = "cover";
                break;
            }
            const auto history_delay = std::max(
                lowered.antecedent.maximum_past_delay,
                lowered.consequent
                    ? lowered.consequent->maximum_past_delay
                    : std::uint64_t{0});
            TIRProperty property;
            property.name = instance.instance_name + "." +
                local_property_name;
            property.kind = property_kind;
            property.clock = clock;
            property.implication = lowered.implication;
            property.history_guard_delay = history_delay;
            property.split_history_guards = true;
            property.antecedent_history_guard_delay =
                lowered.antecedent.required_history_warmup;
            property.consequent_history_guard_delay = lowered.consequent
                ? lowered.consequent->required_history_warmup : 0;
            property.antecedent = std::move(lowered.antecedent.sequence);
            if (lowered.consequent) {
                property.consequent = std::move(lowered.consequent->sequence);
            }
            property.location = check.location;
            for (const auto delay : {property.history_guard_delay,
                     property.antecedent_history_guard_delay,
                     property.consequent_history_guard_delay}) {
                if (delay == 0) continue;
                const auto existing = std::find_if(
                    result.history_guards.begin(), result.history_guards.end(),
                    [&](const TIRHistoryGuard& guard) {
                        return guard.clock == clock &&
                               guard.delay == delay;
                    });
                if (existing == result.history_guards.end()) {
                    result.history_guards.push_back(TIRHistoryGuard{
                        clock, delay, {}, {}});
                }
            }
            append_named_property(result, std::move(property));
        }
    }

    for (auto& [target_name, drivers] : child_output_bit_drivers) {
        const auto missing = std::find_if(drivers.bits.begin(),
            drivers.bits.end(), [](const auto& bit) { return !bit.has_value(); });
        if (missing != drivers.bits.end()) {
            const auto missing_offset = static_cast<std::uint64_t>(
                std::distance(drivers.bits.begin(), missing));
            throw LoweringError(drivers.location,
                "child output bit-select connections do not cover every bit of '" +
                target_name + "'; missing packed bit offset " +
                std::to_string(missing_offset));
        }
        const auto signal = signals.find(target_name);
        if (signal == signals.end() || signal->second.role == "input" ||
            sequential_targets.find(target_name) != sequential_targets.end() ||
            !driven_targets.insert(target_name).second) {
            throw LoweringError(drivers.location,
                "child output bit-select connections have an invalid or multiply driven target '" +
                target_name + "'");
        }
        std::vector<TypedExpression> operands;
        operands.reserve(drivers.bits.size());
        for (auto bit = drivers.bits.rbegin(); bit != drivers.bits.rend(); ++bit) {
            operands.push_back(std::move(bit->value()));
        }
        auto expression = operands.size() == 1
            ? std::move(operands.front())
            : TypedExpression{"concatenation", "{}",
                static_cast<std::uint64_t>(operands.size()), false,
                drivers.location, std::move(operands)};
        result.combinational_equations.push_back(TIREquation{
            target_name, signal->second.width, std::move(expression),
            drivers.location});
    }

    if (!event_domain_owners) {
        lower_top_checks(result, *selected, *selected_unit, signals, constants,
                         source_units, attach_standalone ? references : nullptr);
    }
    validate_combinational_acyclic(result);
    for (const auto& signal : result.signals) {
        if (signal.role == "output" &&
            driven_targets.find(signal.name) == driven_targets.end() &&
            sequential_targets.find(signal.name) == sequential_targets.end()) {
            throw LoweringError(selected->location,
                "continuous-assignment-only TIR slice cannot resolve undriven output '" +
                signal.name + "'");
        }
    }
    return result;
}

TIRModule lower_continuous_assignments(
    const std::vector<frontend::SyntaxUnit>& source_units,
    const elaboration::ElaborationResult& elaborated) {
    if (!elaborated.top.memories.empty()) {
        throw LoweringError(elaborated.top.memories.front().element.location,
            "unpacked memory requires the development transition entry point",
            frontend::InputDiagnosticKind::Unsupported);
    }
    const bool has_standalone = std::any_of(source_units.begin(), source_units.end(),
        [](const auto& unit) { return !unit.standalone_checks.empty() || !unit.standalone_declarations.empty(); });
    HierarchyReferences references;
    return lower_module(source_units, elaborated, has_standalone ? &references : nullptr, has_standalone);
}

TIRModule lower_event_domain_equations(const std::vector<frontend::SyntaxUnit>& units,
    const elaboration::ElaborationResult& design, std::map<std::string, std::string>& owners) {
    const frontend::ParsedModule* selected = nullptr;
    const frontend::SyntaxUnit* source_unit = nullptr;
    for (const auto& unit : units) {
        for (const auto& module : unit.modules) {
            if (module.name == design.top.name) {
                selected = &module;
                source_unit = &unit;
            }
        }
        if (!unit.binds.empty() || !unit.standalone_checks.empty() || !unit.standalone_declarations.empty()) {
            throw LoweringError(unit.tokens.front().location,
                "development event-mask lowering requires a flat RTL project",
                frontend::InputDiagnosticKind::Unsupported);
        }
    }
    if (!selected) throw std::invalid_argument("event-mask source does not contain the elaborated top");
    if (!selected->instances.empty() || !selected->generate_items.empty() || !selected->memories.empty() ||
        !design.top.instances.empty() || !design.top.generate_scopes.empty() || !design.top.memories.empty()) {
        throw LoweringError(selected->location,
            "development event-mask lowering requires a flat scalar RTL top",
            frontend::InputDiagnosticKind::Unsupported);
    }
    std::map<std::string, std::string> collected;
    auto model = lower_module(units, design, nullptr, false, &collected);
    if (!selected->property_checks.empty()) {
        std::map<std::string, std::string> declaration_clocks;
        for (const auto& declaration : selected->property_declarations) {
            if (!declaration_clocks.emplace(declaration.name, declaration.clock).second) {
                throw LoweringError(declaration.location, "duplicate event-domain property declaration");
            }
        }
        const auto domains = model.clocks;
        std::map<std::string, frontend::ParsedModule> groups;
        for (std::size_t i = 0; i < selected->property_checks.size(); ++i) {
            auto check = selected->property_checks[i];
            auto clock = check.clock.value_or("");
            if (check.property_reference) {
                const auto found = declaration_clocks.find(*check.property_reference);
                if (found == declaration_clocks.end()) {
                    throw LoweringError(check.location, "unresolved event-domain property reference");
                }
                clock = found->second;
            } else if (!check.label) {
                check.label = "property_check_" + std::to_string(i + 1);
            }
            if (std::find(domains.begin(), domains.end(), clock) == domains.end()) {
                throw LoweringError(check.location, "property clock is not a declared RTL event domain",
                    frontend::InputDiagnosticKind::Unsupported);
            }
            groups[clock].property_checks.push_back(std::move(check));
        }
        std::map<std::string, TIRSignal> signals;
        for (const auto& signal : model.signals) signals.emplace(signal.name, signal);
        std::map<std::string, TIRConstant> constants;
        for (const auto& constant : model.parameters) constants.emplace(constant.name, constant);
        for (auto& [clock, group] : groups) {
            group.name = selected->name;
            group.property_declarations = selected->property_declarations;
            model.clocks.assign(1, clock);
            const auto first_generated_state = model.next_state_equations.size();
            lower_top_checks(model, group, *source_unit, signals, constants, {}, nullptr);
            for (auto i = first_generated_state; i < model.next_state_equations.size(); ++i) {
                collected.emplace(model.next_state_equations[i].target, clock);
            }
        }
        model.clocks = domains;
    }
    owners = std::move(collected);
    return model;
}

void attach_exact_memory_source_properties(TIRModule& model, const frontend::SyntaxUnit& unit,
    const frontend::ParsedModule& declaration, const elaboration::ElaboratedModule& elaborated) {
    std::map<std::string, TIRSignal> visible;
    for (const auto* declared : {&elaborated.ports, &elaborated.signals}) {
        for (const auto& source : *declared) {
            const auto match = std::find_if(model.signals.begin(), model.signals.end(),
                [&](const auto& signal) { return signal.name == source.name; });
            if (match == model.signals.end()) {
                throw LoweringError(source.location, "memory property signal is missing from the transition model");
            }
            visible.emplace(source.name, *match);
        }
    }
    model.parameters.clear();
    std::map<std::string, TIRConstant> constants;
    const auto add_constants = [&](const auto& declarations, const char* kind) {
        for (const auto& value : declarations) {
            TIRConstant constant{value.name, kind, value.value, value.width, value.is_signed,
                value.location, value.packed_bounds};
            constants.emplace(value.name, constant);
            model.parameters.push_back(std::move(constant));
        }
    };
    add_constants(elaborated.parameters, "parameter");
    add_constants(elaborated.localparams, "localparam");
    lower_top_checks(model, declaration, unit, visible, constants, {}, nullptr);
}

std::string serialize_tir(const TIRModule& module) {
    std::string output = "{\"schema_version\":" +
        json_string(module.schema_version) +
        ",\"semantic_profile\":" + json_string(module.semantic_profile) +
        ",\"input_sha256\":" + json_string(module.input_hash) +
        ",\"top_module\":" + json_string(module.name) +
        ",\"signals\":[";
    for (std::size_t i = 0; i < module.signals.size(); ++i) {
        if (i != 0) output.push_back(',');
        const auto& signal = module.signals[i];
        output += "{\"name\":" + json_string(signal.name) +
            ",\"width\":" + std::to_string(signal.width) +
            ",\"signed\":" + (signal.is_signed ? "true" : "false") +
            ",\"role\":" + json_string(signal.role) +
            ",\"source\":{" +
            "\"file\":" + json_string(signal.location.file) +
            ",\"line\":" + std::to_string(signal.location.line) +
            ",\"column\":" + std::to_string(signal.location.column) + "}}";
    }
    output += "],\"parameters\":[";
    for (std::size_t i = 0; i < module.parameters.size(); ++i) {
        if (i != 0) output.push_back(',');
        const auto& parameter = module.parameters[i];
        output += "{\"name\":" + json_string(parameter.name) +
            ",\"kind\":" + json_string(parameter.kind) +
            ",\"value\":" + elaboration::integral_value_text(parameter.value, parameter.is_signed) +
            ",\"width\":" + std::to_string(parameter.width) +
            ",\"signed\":" + (parameter.is_signed ? "true" : "false") +
            ",\"source\":{" +
            "\"file\":" + json_string(parameter.location.file) +
            ",\"line\":" + std::to_string(parameter.location.line) +
            ",\"column\":" + std::to_string(parameter.location.column) + "}}";
    }
    output += "],\"clocks\":[";
    for (std::size_t i = 0; i < module.clocks.size(); ++i) {
        if (i != 0) output.push_back(',');
        output += json_string(module.clocks[i]);
    }
    output += "],\"history_guards\":[";
    for (std::size_t i = 0; i < module.history_guards.size(); ++i) {
        if (i != 0) output.push_back(',');
        const auto& guard = module.history_guards[i];
        output += "{\"clock\":" + json_string(guard.clock) +
            ",\"delay\":" + std::to_string(guard.delay) +
            ",\"initially_valid\":false," +
            "\"state_chain_initial_value\":\"0\"," +
            "\"valid_after_samples\":" + std::to_string(guard.delay) +
            ",\"reset_behavior\":\"retains_across_reset\",\"valid_signal\":" +
            json_string(guard.valid_signal) + ",\"state_chain\":[";
        for (std::size_t stage = 0; stage < guard.state_chain.size(); ++stage) {
            if (stage != 0) output.push_back(',');
            output += json_string(guard.state_chain[stage]);
        }
        output += "]}";
    }
    const auto serialize_sequence = [](const TIRSequence& sequence) {
        std::string serialized = "{\"terms\":[";
        for (std::size_t term_index = 0;
             term_index < sequence.terms.size(); ++term_index) {
            if (term_index != 0) serialized.push_back(',');
            const auto& term = sequence.terms[term_index];
            serialized += "{\"delay_from_previous\":" +
                std::to_string(term.delay_from_previous) +
                ",\"repeat_min\":" + std::to_string(term.repeat_min) +
                ",\"repeat_max\":" + std::to_string(term.repeat_max) +
                ",\"source\":{\"file\":" +
                json_string(term.location.file) +
                ",\"line\":" + std::to_string(term.location.line) +
                ",\"column\":" + std::to_string(term.location.column) +
                "},\"predicate\":" +
                serialize_expression(term.predicate) + "}";
        }
        serialized += "],\"automaton\":{\"state_count\":" +
            std::to_string(sequence.automaton.state_count) +
            ",\"start_state\":" +
            std::to_string(sequence.automaton.start_state) +
            ",\"accepting_state\":" +
            std::to_string(sequence.automaton.accepting_state) +
            ",\"transitions\":[";
        for (std::size_t index = 0;
             index < sequence.automaton.transitions.size(); ++index) {
            if (index != 0) serialized.push_back(',');
            const auto& transition = sequence.automaton.transitions[index];
            serialized += "{\"source_state\":" +
                std::to_string(transition.source_state) +
                ",\"target_state\":" +
                std::to_string(transition.target_state) +
                ",\"delay_cycles\":" +
                std::to_string(transition.delay_cycles) +
                ",\"repeat_min\":" +
                std::to_string(transition.repeat_min) +
                ",\"repeat_max\":" +
                std::to_string(transition.repeat_max) +
                ",\"predicate\":" +
                serialize_expression(transition.predicate) +
                ",\"source\":{\"file\":" +
                json_string(transition.location.file) +
                ",\"line\":" +
                std::to_string(transition.location.line) +
                ",\"column\":" +
                std::to_string(transition.location.column) + "}}";
        }
        serialized += "]}}";
        return serialized;
    };
    output += "],\"properties\":[";
    for (std::size_t i = 0; i < module.properties.size(); ++i) {
        if (i != 0) output.push_back(',');
        const auto& property = module.properties[i];
        output += "{\"name\":" + json_string(property.name) +
            ",\"kind\":" + json_string(property.kind) +
            ",\"clock\":" + json_string(property.clock) +
            ",\"implication\":" + json_string(property.implication) +
            ",\"history_guard_delay\":" +
            std::to_string(property.history_guard_delay) +
            ",\"history_guard_signal\":" +
            (property.history_guard_signal.empty()
                ? std::string("null")
                : json_string(property.history_guard_signal)) +
            ",\"split_history_guards\":" +
            std::string(property.split_history_guards ? "true" : "false") +
            ",\"antecedent_history_guard_delay\":" +
            std::to_string(property.antecedent_history_guard_delay) +
            ",\"antecedent_history_guard_signal\":" +
            (property.antecedent_history_guard_signal.empty()
                ? std::string("null")
                : json_string(property.antecedent_history_guard_signal)) +
            ",\"consequent_history_guard_delay\":" +
            std::to_string(property.consequent_history_guard_delay) +
            ",\"consequent_history_guard_signal\":" +
            (property.consequent_history_guard_signal.empty()
                ? std::string("null")
                : json_string(property.consequent_history_guard_signal)) +
            ",\"source\":{\"file\":" +
            json_string(property.location.file) +
            ",\"line\":" + std::to_string(property.location.line) +
            ",\"column\":" + std::to_string(property.location.column) +
            "},\"antecedent\":" +
            serialize_sequence(property.antecedent) +
            ",\"consequent\":";
        output += property.consequent
            ? serialize_sequence(*property.consequent) : "null";
        output.push_back('}');
    }
    output += "],\"initial_state\":\"unconstrained\",\"combinational_equations\":[";
    for (std::size_t i = 0; i < module.combinational_equations.size(); ++i) {
        if (i != 0) output.push_back(',');
        const auto& equation = module.combinational_equations[i];
        output += "{\"target\":" + json_string(equation.target) +
            ",\"target_width\":" + std::to_string(equation.target_width) +
            ",\"source\":{" +
            "\"file\":" + json_string(equation.location.file) +
            ",\"line\":" + std::to_string(equation.location.line) +
            ",\"column\":" + std::to_string(equation.location.column) + "}" +
            ",\"expression\":" + serialize_expression(equation.expression) + "}";
    }
    output += "],\"next_state_equations\":[";
    for (std::size_t i = 0; i < module.next_state_equations.size(); ++i) {
        if (i != 0) output.push_back(',');
        const auto& equation = module.next_state_equations[i];
        output += "{\"target\":" + json_string(equation.target) +
            ",\"target_width\":" + std::to_string(equation.target_width) +
            ",\"source\":{" +
            "\"file\":" + json_string(equation.location.file) +
            ",\"line\":" + std::to_string(equation.location.line) +
            ",\"column\":" + std::to_string(equation.location.column) + "}" +
            ",\"expression\":" + serialize_expression(equation.expression) + "}";
    }
    output += "]}";
    return output;
}

} // namespace q3a::lowering
