#include "elaborator.hpp"
#include "../frontend/decimal_literal.hpp"

#include "../frontend/lexer.hpp"

#include <algorithm>
#include <charconv>
#include <cctype>
#include <limits>
#include <set>
#include <string_view>
#include <utility>

namespace q3a::elaboration {
namespace {

using Environment = std::map<std::string, std::int64_t>;
struct ConstantType {
    std::uint64_t width;
    bool is_signed;
    std::optional<frontend::PackedBounds> packed_bounds = std::nullopt;
};
struct ConstantValue {
    std::int64_t value;
    ConstantType type;
};
using ConstantTypes = std::map<std::string, ConstantType>;

std::int64_t interpret_bits(std::uint64_t bits) {
    constexpr auto max_signed = static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max());
    return bits <= max_signed ? static_cast<std::int64_t>(bits)
                              : -1 - static_cast<std::int64_t>(~bits);
}

class ConstantExpression {
public:
    ConstantExpression(const std::vector<frontend::Token>& tokens,
                       frontend::ExpressionSpan span,
                       const Environment& environment,
                       const ConstantTypes* bound_types = nullptr,
                       std::uint64_t destination_width = 0)
        : tokens_(tokens), index_(span.first_token), end_(span.after_last_token),
          environment_(environment), bound_types_(bound_types),
          destination_width_(destination_width) {}

    std::int64_t evaluate(bool require_signed_index = true) {
        const auto expression = parse_complete_expression();
        // Keep the prior untyped integer policy at call sites that do not
        // supply declaration types, and for untyped parameter dependencies.
        if (!bound_types_ || !types_complete_ || destination_width_ > 64 ||
            (require_signed_index && !destination_width_ && !saw_typed_operand_)) {
            return evaluate_legacy(expression);
        }
        auto context = expression.type;
        context.width = std::max(context.width, destination_width_);
        const auto value = evaluate_as(expression, context);
        if (require_signed_index && !destination_width_ && !context.is_signed && value < 0) {
            fail_at(expression.token, "constant select bound exceeds the signed 64-bit index range");
        }
        return value;
    }

    ConstantValue infer() {
        const auto expression = parse_complete_expression();
        if (!types_complete_) {
            fail_at(expression.token, "inferred integral constant requires resolved operand widths from 1 to 64 bits");
        }
        return {evaluate_as(expression, expression.type),
                {expression.type.width, expression.type.is_signed}};
    }

private:
    struct Node {
        std::size_t token;
        ConstantType type;
        std::uint64_t bits;
        std::vector<Node> children;
    };

    static constexpr ConstantType boolean_type{1, false};

    Node parse_complete_expression() {
        if (index_ >= end_) fail_at(end_ == 0 ? 0 : end_ - 1, "empty constant expression");
        auto expression = parse_expression();
        if (index_ != end_) {
            fail("unexpected token in constant expression: '" + current().text + "'");
        }
        return expression;
    }

    std::int64_t evaluate_as(const Node& node, ConstantType type) const {
        return interpret_bits(extend(evaluate_bits(node, type), type));
    }

    static ConstantType merge_types(ConstantType left, ConstantType right) {
        return {std::max(left.width, right.width), left.is_signed && right.is_signed};
    }

    static std::uint64_t bits_mask(std::uint64_t width) {
        return width >= 64 ? std::numeric_limits<std::uint64_t>::max()
                           : (std::uint64_t{1} << width) - 1;
    }

    static std::uint64_t extend(std::uint64_t bits, ConstantType type) {
        const auto mask = bits_mask(type.width);
        bits &= mask;
        if (type.is_signed && type.width < 64 && (bits >> (type.width - 1)) != 0) {
            bits |= ~mask;
        }
        return bits;
    }

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
        fail_at(index_ < tokens_.size() ? index_ : tokens_.size() - 1, message);
    }
    [[noreturn]] void fail_at(std::size_t index,
                              const std::string& message) const {
        const auto& location = tokens_[std::min(index, tokens_.size() - 1)].location;
        throw ElaborationError(location, message);
    }

    static int binary_precedence(const std::string& op) {
        if (op == "||") return 1;
        if (op == "&&") return 2;
        if (op == "|") return 3;
        if (op == "^" || op == "~^" || op == "^~") return 4;
        if (op == "&") return 5;
        if (op == "==" || op == "!=") return 6;
        if (op == "<" || op == "<=" || op == ">" || op == ">=") return 7;
        if (op == "<<" || op == ">>") return 8;
        if (op == "+" || op == "-") return 9;
        return -1;
    }

    Node parse_expression(int minimum_precedence = 0) {
        auto left = parse_unary();
        while (index_ < end_) {
            const auto precedence = binary_precedence(current().text);
            if (precedence < minimum_precedence) break;
            const auto position = index_++;
            auto right = parse_expression(precedence + 1);
            const auto type = precedence <= 2 || precedence == 6 || precedence == 7
                ? boolean_type : precedence == 8 ? left.type : merge_types(left.type, right.type);
            Node binary{position, type, 0, {}};
            binary.children.push_back(std::move(left));
            binary.children.push_back(std::move(right));
            left = std::move(binary);
        }
        if (minimum_precedence == 0 && at("?")) {
            const auto position = index_++;
            auto when_true = parse_expression();
            if (!accept(":")) fail("expected ':' in constant conditional expression");
            auto when_false = parse_expression();
            Node conditional{position, merge_types(when_true.type, when_false.type), 0, {}};
            conditional.children.push_back(std::move(left));
            conditional.children.push_back(std::move(when_true));
            conditional.children.push_back(std::move(when_false));
            return conditional;
        }
        return left;
    }

    Node parse_unary() {
        if (at("+") || at("-") || at("!") || at("~")) {
            const auto position = index_++;
            auto operand = parse_unary();
            Node unary{position, tokens_[position].text == "!" ? boolean_type : operand.type, 0, {}};
            unary.children.push_back(std::move(operand));
            return unary;
        }
        if (at("~^") || at("^~")) {
            fail("reduction operators are not supported in constant expressions");
        }
        return parse_primary();
    }

    Node parse_primary() {
        if (index_ >= end_) fail("expected operand in constant expression");
        const auto position = index_;
        if (current().kind == frontend::TokenKind::Number) {
            advance();
            return parse_integer_literal(position);
        }
        if (current().kind == frontend::TokenKind::Identifier) {
            const auto& name = advance().text;
            const auto found = environment_.find(name);
            if (found == environment_.end()) {
                fail_at(position, "constant expression references unresolved name '" + name + "'");
            }
            ConstantType type{64, true};
            if (bound_types_) {
                const auto declared = bound_types_->find(name);
                if (declared == bound_types_->end() || declared->second.width == 0 ||
                    declared->second.width > 64) {
                    types_complete_ = false;
                } else {
                    type = declared->second;
                    saw_typed_operand_ = true;
                }
            }
            // Identifier values already carry their declaration conversion.
            const auto bits = static_cast<std::uint64_t>(found->second);
            if (!at("[")) return {position, type, bits, {}};
            const auto selection_token = index_;
            advance();
            if (!type.packed_bounds) {
                fail_at(selection_token, "bit/part select requires a declared packed vector with known bounds");
            }
            const auto index_value = [&](const Node& expression) {
                if (expression.type.width > 64) {
                    fail_at(expression.token, "constant select requires an index at most 64 bits wide");
                }
                const auto value = evaluate_as(expression, expression.type);
                if (!expression.type.is_signed && value < 0) {
                    fail_at(expression.token, "constant select bound exceeds the signed 64-bit index range");
                }
                return value;
            };
            const auto first = index_value(parse_expression());
            std::optional<std::int64_t> last;
            if (accept(":")) last = index_value(parse_expression());
            if (!accept("]")) fail("expected ']' after select expression");
            try {
                const auto selected = frontend::resolve_packed_select(*type.packed_bounds, type.width, first, last);
                return {position, {selected.width, false},
                        (bits >> selected.offset) & bits_mask(selected.width), {}};
            } catch (const std::invalid_argument& error) {
                fail_at(selection_token, error.what());
            }
        }
        if (accept("(")) {
            auto value = parse_expression();
            if (!accept(")")) fail("expected ')' in constant expression");
            return value;
        }
        if (accept("{")) {
            Node concatenation{position, {0, false}, 0, {}};
            do {
                auto member = parse_expression();
                const auto& member_token = tokens_[member.token];
                if (member.children.empty() && member_token.kind == frontend::TokenKind::Number &&
                    member_token.text.find('\'') == std::string::npos) {
                    fail_at(member.token, "unsized decimal concatenation member requires an explicit width");
                }
                if (member.type.width > 64 - concatenation.type.width) {
                    fail_at(position, "constant concatenation width exceeds the 64-bit implementation limit");
                }
                concatenation.type.width += member.type.width;
                concatenation.children.push_back(std::move(member));
            } while (accept(","));
            if (!accept("}")) fail("expected '}' after constant concatenation");
            saw_typed_operand_ = true;
            return concatenation;
        }
        fail("unsupported constant-expression operand '" + current().text + "'");
    }

    Node parse_integer_literal(std::size_t position) {
        const auto& token = tokens_[position];
        if (token.text == "'0" || token.text == "'1") {
            saw_typed_operand_ = true;
            return {position, {1, false}, token.text == "'1" ? 1U : 0U, {}};
        }
        const auto quote = token.text.find('\'');
        if (quote == std::string::npos) {
            const auto decimal = frontend::decode_unsized_decimal(token.text);
            if (!decimal) {
                fail_at(position, "unsized decimal constant is outside the signed 64-bit implementation range");
            }
            return {position, {decimal->width, true}, decimal->value, {}};
        }
        if (quote == 0) {
            fail_at(position, "unsized based constant is unsupported in Phase 0");
        }
        std::string width_text = token.text.substr(0, quote);
        width_text.erase(std::remove(width_text.begin(), width_text.end(), '_'),
                         width_text.end());
        std::uint64_t declared_width = 0;
        const auto width_parse = std::from_chars(width_text.data(),
            width_text.data() + width_text.size(), declared_width);
        if (width_parse.ec != std::errc{} ||
            width_parse.ptr != width_text.data() + width_text.size() ||
            declared_width == 0) {
            fail_at(position, "based literal width must be a positive constant");
        }
        auto base_index = quote + 1;
        bool is_signed = false;
        if (base_index < token.text.size() &&
            (token.text[base_index] == 's' || token.text[base_index] == 'S')) {
            is_signed = true;
            ++base_index;
        }
        if (base_index >= token.text.size()) {
            fail_at(position, "malformed based integer literal");
        }
        const char base_char = static_cast<char>(std::tolower(
            static_cast<unsigned char>(token.text[base_index])));
        unsigned base = 0;
        if (base_char == 'b') base = 2;
        else if (base_char == 'o') base = 8;
        else if (base_char == 'd') base = 10;
        else if (base_char == 'h') base = 16;
        else fail_at(position, "unsupported based integer radix");

        std::uint64_t raw = 0;
        const auto digits = token.text.substr(base_index + 1);
        if (digits.empty()) fail_at(position, "based integer literal has no digits");
        for (const char raw_digit : digits) {
            if (raw_digit == '_') continue;
            const char digit = static_cast<char>(std::tolower(
                static_cast<unsigned char>(raw_digit)));
            unsigned value = 0;
            if (digit >= '0' && digit <= '9') value = static_cast<unsigned>(digit - '0');
            else if (digit >= 'a' && digit <= 'f') value = static_cast<unsigned>(digit - 'a' + 10);
            else fail_at(position, "X/Z digit in a constant expression is unsupported");
            if (value >= base || raw > (std::numeric_limits<std::uint64_t>::max() - value) / base) {
                fail_at(position, "based constant is invalid or outside the 64-bit implementation range");
            }
            raw = raw * base + value;
        }
        types_complete_ = types_complete_ && declared_width <= 64;
        saw_typed_operand_ = true;
        return {position, {declared_width, is_signed}, raw, {}};
    }

    template <typename Integer>
    static bool compare(const std::string& op, Integer left, Integer right) {
        if (op == "==") return left == right;
        if (op == "!=") return left != right;
        if (op == "<") return left < right;
        if (op == "<=") return left <= right;
        if (op == ">") return left > right;
        return left >= right;
    }

    std::uint64_t evaluate_bits(const Node& node, ConstantType context) const {
        const auto& op = tokens_[node.token].text;
        const auto count = node.children.size();
        const auto mask = bits_mask(context.width);
        if (op == "{") {
            std::uint64_t packed = 0;
            for (const auto& member : node.children) {
                const auto bits = evaluate_bits(member, member.type);
                packed = member.type.width == 64 ? bits : (packed << member.type.width) | bits;
            }
            return packed & mask;
        }
        if (count == 0) {
            if (op == "'1") return mask;
            return extend(node.bits, {node.type.width, node.type.is_signed && context.is_signed}) & mask;
        }

        const auto& left = node.children[0];
        if (count == 1) {
            if (op == "!") return evaluate_bits(left, left.type) == 0;
            const auto value = evaluate_bits(left, context);
            if (op == "+") return value;
            if (op == "-") return (std::uint64_t{0} - value) & mask;
            return ~value & mask;
        }
        const auto& right = node.children[1];
        if (count == 3) {
            const auto condition = evaluate_bits(left, left.type);
            const auto when_true = evaluate_bits(right, context);
            const auto& third = node.children[2];
            const auto when_false = evaluate_bits(third, context);
            return condition != 0 ? when_true : when_false;
        }

        const auto precedence = binary_precedence(op);
        if (precedence <= 2) {
            const auto a = evaluate_bits(left, left.type);
            const auto b = evaluate_bits(right, right.type);
            return op == "&&" ? a != 0 && b != 0 : a != 0 || b != 0;
        }
        if (precedence == 6 || precedence == 7) {
            const auto comparison = merge_types(left.type, right.type);
            const auto a = evaluate_bits(left, comparison);
            const auto b = evaluate_bits(right, comparison);
            if (comparison.is_signed) {
                return compare(op, interpret_bits(extend(a, comparison)),
                                   interpret_bits(extend(b, comparison)));
            }
            return compare(op, a, b);
        }
        const auto a = evaluate_bits(left, context);
        if (precedence == 8) {
            const auto shift = evaluate_bits(right, right.type);
            if (right.type.is_signed && ((shift >> (right.type.width - 1)) & 1U) != 0) {
                fail_at(right.token, "negative constant shift distances are unsupported");
            }
            if (shift >= context.width) return 0;
            return op == "<<" ? (a << shift) & mask : a >> shift;
        }
        const auto b = evaluate_bits(right, context);
        if (op == "+") return (a + b) & mask;
        if (op == "-") return (a - b) & mask;
        if (op == "&") return a & b;
        if (op == "|") return a | b;
        if (op == "^") return a ^ b;
        return ~(a ^ b) & mask;
    }

    std::int64_t evaluate_legacy(const Node& node) const {
        const auto& token = tokens_[node.token];
        if (token.text == "{") {
            const auto bits = evaluate_bits(node, node.type);
            if (interpret_bits(bits) < 0) {
                fail_at(node.token, "constant exceeds the signed 64-bit implementation range");
            }
            return interpret_bits(bits);
        }
        if (node.children.empty()) {
            if (token.kind == frontend::TokenKind::Identifier) return interpret_bits(node.bits);
            const auto raw = extend(node.bits, node.type);
            if (!node.type.is_signed && interpret_bits(raw) < 0) {
                fail_at(node.token, "constant exceeds the signed 64-bit implementation range");
            }
            return interpret_bits(raw);
        }

        const auto left = evaluate_legacy(node.children[0]);
        if (node.children.size() == 1) {
            if (token.text == "+") return left;
            if (token.text == "~") return ~left;
            if (token.text == "!") return left == 0;
            if (left == std::numeric_limits<std::int64_t>::min()) {
                fail_at(node.token, "signed overflow in constant unary minus");
            }
            return -left;
        }
        const auto right = evaluate_legacy(node.children[1]);
        if (node.children.size() == 3) {
            const auto when_false = evaluate_legacy(node.children[2]);
            return left != 0 ? right : when_false;
        }
        return apply_legacy_binary(token.text, left, right);
    }

    std::int64_t apply_legacy_binary(const std::string& op,
                              std::int64_t lhs,
                              std::int64_t rhs) const {
        if (op == "+") {
            if ((rhs > 0 && lhs > std::numeric_limits<std::int64_t>::max() - rhs) ||
                (rhs < 0 && lhs < std::numeric_limits<std::int64_t>::min() - rhs)) {
                fail("signed overflow in constant addition");
            }
            return lhs + rhs;
        }
        if (op == "-") {
            if ((rhs < 0 && lhs > std::numeric_limits<std::int64_t>::max() + rhs) ||
                (rhs > 0 && lhs < std::numeric_limits<std::int64_t>::min() + rhs)) {
                fail("signed overflow in constant subtraction");
            }
            return lhs - rhs;
        }
        if (op == "&") return lhs & rhs;
        if (op == "|") return lhs | rhs;
        if (op == "^") return lhs ^ rhs;
        if (op == "~^" || op == "^~") return ~(lhs ^ rhs);
        if (op == "&&") return lhs != 0 && rhs != 0;
        if (op == "||") return lhs != 0 || rhs != 0;
        if (op == "==") return lhs == rhs;
        if (op == "!=") return lhs != rhs;
        if (op == "<") return lhs < rhs;
        if (op == "<=") return lhs <= rhs;
        if (op == ">") return lhs > rhs;
        if (op == ">=") return lhs >= rhs;
        if (op == "<<" || op == ">>") {
            if (rhs < 0) fail("negative constant shift distances are unsupported");
            if (rhs >= 64) return 0;
            const auto shift = static_cast<unsigned>(rhs);
            if (op == ">>") {
                return interpret_bits(
                    static_cast<std::uint64_t>(lhs) >> shift);
            }
            return static_cast<std::int64_t>(
                static_cast<std::uint64_t>(lhs) << shift);
        }
        fail("unsupported constant operator '" + op + "'");
    }

    const std::vector<frontend::Token>& tokens_;
    std::size_t index_;
    std::size_t end_;
    const Environment& environment_;
    const ConstantTypes* bound_types_;
    std::uint64_t destination_width_;
    bool types_complete_ = true;
    bool saw_typed_operand_ = false;
};

std::int64_t evaluate_span(const std::vector<frontend::Token>& tokens,
                           const frontend::ExpressionSpan& span,
                           const Environment& environment,
                           const ConstantTypes* types = nullptr,
                           std::uint64_t destination_width = 0) {
    return ConstantExpression(tokens, span, environment, types, destination_width).evaluate();
}

class ExpressionWidth {
public:
    ExpressionWidth(const std::vector<frontend::Token>& tokens,
                    frontend::ExpressionSpan span,
                    const Environment& environment,
                    const std::map<std::string, std::uint64_t>& symbols,
                    const ConstantTypes& constant_types,
                    std::uint64_t context_width)
        : tokens_(tokens), index_(span.first_token), end_(span.after_last_token),
          environment_(environment), symbols_(symbols), constant_types_(constant_types),
          context_width_(context_width) {}

    std::uint64_t evaluate() {
        if (index_ >= end_) fail("empty port-connection expression");
        const auto width = parse_expression();
        if (index_ != end_) {
            fail("unexpected token in port-connection expression: '" +
                 tokens_[index_].text + "'");
        }
        return width;
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
        const auto index = std::min(index_, tokens_.size() - 1);
        throw ElaborationError(tokens_[index].location, message);
    }

    static int precedence(const std::string& op) {
        if (op == "||") return 1;
        if (op == "&&") return 2;
        if (op == "|") return 3;
        if (op == "^" || op == "~^" || op == "^~") return 4;
        if (op == "&") return 5;
        if (op == "==" || op == "!=") return 6;
        if (op == "<" || op == "<=" || op == ">" || op == ">=") return 7;
        if (op == "<<" || op == ">>") return 8;
        if (op == "+" || op == "-") return 9;
        return -1;
    }

    std::uint64_t parse_expression(int minimum_precedence = 0) {
        auto lhs = parse_unary();
        for (;;) {
            const auto op = index_ < end_ ? current().text : std::string{};
            const auto op_precedence = precedence(op);
            if (op_precedence < minimum_precedence) break;
            advance();
            const auto rhs = parse_expression(op_precedence + 1);
            if (op == "&&" || op == "||" || op == "==" || op == "!=" ||
                op == "<" || op == "<=" || op == ">" || op == ">=") {
                lhs = 1;
            } else if (op != "<<" && op != ">>") {
                lhs = std::max(lhs, rhs);
            }
        }
        if (minimum_precedence == 0 && accept("?")) {
            const auto when_true = parse_expression();
            if (!accept(":")) fail("expected ':' in conditional expression");
            const auto when_false = parse_expression();
            lhs = std::max(when_true, when_false);
        }
        return lhs;
    }

    std::uint64_t parse_unary() {
        if (accept("!")) {
            (void)parse_unary();
            return 1;
        }
        if (accept("+") || accept("-") || accept("~")) {
            return parse_unary();
        }
        return parse_primary();
    }

    std::uint64_t number_width(const frontend::Token& token) const {
        if (token.text == "'0" || token.text == "'1") {
            return concat_depth_ == 0 ? context_width_ : 1;
        }
        const auto quote = token.text.find('\'');
        if (quote == std::string::npos) {
            const auto decimal = frontend::decode_unsized_decimal(token.text);
            if (!decimal) {
                throw ElaborationError(token.location,
                    "unsized decimal literal exceeds the supported signed 64-bit range");
            }
            return decimal->width;
        }
        if (quote == 0) return 32;
        auto digits = token.text.substr(0, quote);
        digits.erase(std::remove(digits.begin(), digits.end(), '_'), digits.end());
        std::uint64_t width = 0;
        const auto result = std::from_chars(digits.data(),
            digits.data() + digits.size(), width);
        if (result.ec != std::errc{} ||
            result.ptr != digits.data() + digits.size() || width == 0) {
            fail("cannot determine sized literal width in port connection");
        }
        return width;
    }

    std::uint64_t parse_primary() {
        if (index_ >= end_) fail("expected operand in port-connection expression");
        const auto token = current();
        if (token.kind == frontend::TokenKind::Number) {
            advance();
            return number_width(token);
        }
        if (token.kind == frontend::TokenKind::Identifier) {
            advance();
            const auto found = symbols_.find(token.text);
            if (found == symbols_.end()) {
                fail("port connection references unresolved signal or constant '" +
                     token.text + "'");
            }
            auto width = found->second;
            while (accept("[")) {
                const auto first = index_;
                (void)parse_expression();
                const frontend::ExpressionSpan left{first, index_};
                if (accept(":")) {
                    const auto right_first = index_;
                    (void)parse_expression();
                    const frontend::ExpressionSpan right{right_first, index_};
                    if (!accept("]")) fail("expected ']' after part-select");
                    const auto left_value = ConstantExpression(tokens_, left, environment_, &constant_types_).evaluate();
                    const auto right_value = ConstantExpression(tokens_, right, environment_, &constant_types_).evaluate();
                    const auto ul = static_cast<std::uint64_t>(left_value);
                    const auto ur = static_cast<std::uint64_t>(right_value);
                    const auto distance = left_value >= right_value ? ul - ur : ur - ul;
                    if (distance == std::numeric_limits<std::uint64_t>::max()) {
                        fail("part-select width overflows the implementation limit");
                    }
                    width = distance + 1;
                } else if (accept("+:") || accept("-:")) {
                    const auto first_width_token = index_;
                    (void)parse_expression();
                    const frontend::ExpressionSpan width_span{first_width_token, index_};
                    if (!accept("]")) fail("expected ']' after indexed part-select");
                    const auto selected = ConstantExpression(tokens_, width_span, environment_, &constant_types_).evaluate();
                    if (selected <= 0 || selected > 64) fail("indexed part-select width must be 1..64");
                    width = static_cast<std::uint64_t>(selected);
                } else {
                    if (!accept("]")) fail("expected ']' after bit-select");
                    width = 1;
                }
            }
            return width;
        }
        if (accept("(")) {
            const auto width = parse_expression();
            if (!accept(")")) fail("expected ')' in port-connection expression");
            return width;
        }
        if (accept("{")) {
            ++concat_depth_;
            std::uint64_t total = 0;
            do {
                const auto element_width = parse_expression();
                if (total > std::numeric_limits<std::uint64_t>::max() - element_width) {
                    fail("concatenation width overflows the implementation limit");
                }
                total += element_width;
            } while (accept(","));
            if (!accept("}")) fail("expected '}' after concatenation");
            --concat_depth_;
            return total;
        }
        fail("unsupported port-connection expression operand '" + token.text + "'");
    }

    const std::vector<frontend::Token>& tokens_;
    std::size_t index_;
    std::size_t end_;
    const Environment& environment_;
    const std::map<std::string, std::uint64_t>& symbols_;
    const ConstantTypes& constant_types_;
    std::uint64_t context_width_;
    std::size_t concat_depth_ = 0;
};

std::string expression_text(const std::vector<frontend::Token>& tokens,
                            const frontend::ExpressionSpan& span) {
    std::string result;
    const auto end = std::min(span.after_last_token, tokens.size());
    for (auto index = span.first_token; index < end; ++index) {
        if (!result.empty()) result.push_back(' ');
        result += tokens[index].text;
    }
    return result;
}

std::string resolved_expression_text(
    const std::vector<frontend::Token>& tokens,
    const frontend::ExpressionSpan& span,
    const Environment& environment,
    const ConstantTypes& types) {
    std::string result;
    const auto end = std::min(span.after_last_token, tokens.size());
    for (auto index = span.first_token; index < end; ++index) {
        if (!result.empty()) result.push_back(' ');
        const auto& token = tokens[index];
        const auto constant = token.kind == frontend::TokenKind::Identifier
            ? environment.find(token.text) : environment.end();
        if (constant == environment.end()) {
            result += token.text;
        } else {
            const auto type = types.find(token.text);
            result += integral_value_text(constant->second, type == types.end() || type->second.is_signed);
        }
    }
    return result;
}

std::uint64_t packed_width(const std::optional<std::pair<std::int64_t, std::int64_t>>& bounds,
                           const frontend::SourceLocation& location) {
    if (!bounds) return 1;
    const auto [left, right] = *bounds;
    const auto unsigned_left = static_cast<std::uint64_t>(left);
    const auto unsigned_right = static_cast<std::uint64_t>(right);
    const auto distance = left >= right ? unsigned_left - unsigned_right
                                        : unsigned_right - unsigned_left;
    if (distance == std::numeric_limits<std::uint64_t>::max()) {
        throw ElaborationError(location, "packed range width overflows the implementation limit");
    }
    return distance + 1;
}

std::optional<std::pair<std::int64_t, std::int64_t>> packed_bounds(
    const std::optional<frontend::PackedRangeSyntax>& range,
    const std::vector<frontend::Token>& tokens,
    const Environment& environment,
    const ConstantTypes& types) {
    if (!range) return std::nullopt;
    const auto left = evaluate_span(tokens, range->left, environment, &types);
    const auto right = evaluate_span(tokens, range->right, environment, &types);
    return std::make_pair(left, right);
}

std::int64_t apply_declared_type(std::int64_t value,
                                std::uint64_t width,
                                bool is_signed,
                                const frontend::SourceLocation& location) {
    if (width == 0) return value;
    if (width > 64) {
        throw ElaborationError(location,
                               "Phase 0 typed constant width must be in the range 1..64 in this prototype");
    }
    auto raw = static_cast<std::uint64_t>(value);
    if (width < 64) {
        const auto mask = (std::uint64_t{1} << width) - 1;
        raw &= mask;
        if (is_signed && (raw & (std::uint64_t{1} << (width - 1))) != 0) {
            raw |= ~mask;
        }
    }
    return interpret_bits(raw);
}

ConstantValue resolve_initializer(const std::vector<frontend::Token>& tokens,
                                  frontend::ExpressionSpan span,
                                  const Environment& environment,
                                  const ConstantTypes& types,
                                  ConstantType destination,
                                  const frontend::SourceLocation& location) {
    ConstantExpression initializer(tokens, span, environment, &types, destination.width);
    auto result = destination.width == 0 ? initializer.infer()
                                         : ConstantValue{initializer.evaluate(), destination};
    result.value = apply_declared_type(result.value, result.type.width, result.type.is_signed, location);
    return result;
}

ConstantType declared_constant_type(const frontend::ParameterSyntax& declaration,
                                    const std::vector<frontend::Token>& tokens,
                                    const Environment& environment, const ConstantTypes& types) {
    if (declaration.type == frontend::ScalarType::Integer) return {32, declaration.is_signed};
    if (declaration.type == frontend::ScalarType::Untyped) return {0, declaration.is_signed};
    const auto bounds = packed_bounds(declaration.packed_range, tokens, environment, types);
    return {packed_width(bounds, declaration.location), declaration.is_signed, bounds};
}

std::string module_error_prefix(const frontend::ParsedModule& module) {
    return "module '" + module.name + "': ";
}

constexpr std::uint64_t kPrototypeGenerateIterationLimit = 1000000;

std::string child_path(const std::string& prefix, const std::string& name) {
    if (prefix.empty()) return name;
    if (name.empty()) return prefix;
    return prefix + "." + name;
}

std::string generated_block_name(const frontend::GenerateSyntax& node) {
    if (!node.label.empty()) return node.label;
    return "genblk@" + std::to_string(node.location.line);
}

struct ActiveInstance {
    const frontend::InstanceSyntax* syntax = nullptr;
    Environment environment;
    std::string path;
    std::map<std::string, std::int64_t> generate_variables;
    std::map<std::string, TypedConstant> scoped_constants;
    std::optional<BindOrigin> binding = std::nullopt;
};

struct ActiveBind {
    const frontend::BindSyntax* binding;
    BindOrigin origin;
    bool matched = false;
};

using ScopedConstants = std::map<std::string, TypedConstant>;

void resolve_generate_node(
    const frontend::GenerateSyntax& node,
    const std::vector<frontend::Token>& tokens,
    Environment& environment,
    ConstantTypes& types,
    const std::string& prefix,
    std::vector<GenerateResolution>& output,
    std::vector<ActiveInstance>& instances,
    ScopedConstants& scoped_constants,
    std::map<std::string, std::int64_t>& generate_variables);

void resolve_generate_list(
    const std::vector<frontend::GenerateSyntax>& nodes,
    const std::vector<frontend::Token>& tokens,
    Environment& environment,
    ConstantTypes& types,
    const std::string& prefix,
    std::vector<GenerateResolution>& output,
    std::vector<ActiveInstance>& instances,
    ScopedConstants& scoped_constants,
    std::map<std::string, std::int64_t>& generate_variables) {
    struct PriorBinding {
        std::string name;
        std::optional<std::int64_t> value;
        std::optional<ConstantType> type;
        std::optional<TypedConstant> scoped;
    };
    std::vector<PriorBinding> prior_bindings;
    std::set<std::string> declarations;
    for (const auto& node : nodes) {
        for (const auto& signal : node.declarations) {
            if (!declarations.insert(signal.name).second) {
                throw ElaborationError(signal.location, "duplicate generate-local declaration '" + signal.name + "'");
            }
        }
        for (const auto& declaration : node.constants) {
            const auto& name = declaration.name;
            if (prefix.empty()) {
                throw ElaborationError(declaration.location,
                    "generate-local constants require a named or implicit block");
            }
            if (!declarations.insert(name).second) {
                throw ElaborationError(declaration.location, "duplicate generate-local declaration '" + name + "'");
            }
            const auto previous_value = environment.find(name);
            const auto previous_type = types.find(name);
            const auto previous_scoped = scoped_constants.find(name);
            prior_bindings.push_back({name,
                previous_value == environment.end() ? std::nullopt : std::optional{previous_value->second},
                previous_type == types.end() ? std::nullopt : std::optional{previous_type->second},
                previous_scoped == scoped_constants.end() ? std::nullopt : std::optional{previous_scoped->second}});
            const auto target = declared_constant_type(declaration, tokens, environment, types);
            const auto resolved = resolve_initializer(tokens, *declaration.initializer,
                environment, types, target, declaration.location);
            const auto qualified = child_path(prefix, name);
            TypedConstant constant{qualified, resolved.value,
                declaration.type == frontend::ScalarType::Untyped
                    ? frontend::ScalarType::Logic : declaration.type,
                resolved.type.is_signed, resolved.type.width, declaration.location, resolved.type.packed_bounds};
            environment.insert_or_assign(name, resolved.value);
            types.insert_or_assign(name, resolved.type);
            scoped_constants.insert_or_assign(name, constant);
            GenerateResolution entry{"constant", qualified, true, std::nullopt, 0,
                                     declaration.location, {}};
            entry.declared_constant = std::move(constant);
            output.push_back(std::move(entry));
        }
        resolve_generate_node(node, tokens, environment, types, prefix, output,
                              instances, scoped_constants, generate_variables);
    }
    for (const auto& saved : prior_bindings) {
        if (saved.value) environment.insert_or_assign(saved.name, *saved.value);
        else environment.erase(saved.name);
        if (saved.type) types.insert_or_assign(saved.name, *saved.type);
        else types.erase(saved.name);
        if (saved.scoped) scoped_constants.insert_or_assign(saved.name, *saved.scoped);
        else scoped_constants.erase(saved.name);
    }
}

void resolve_generate_node(
    const frontend::GenerateSyntax& node,
    const std::vector<frontend::Token>& tokens,
    Environment& environment,
    ConstantTypes& types,
    const std::string& prefix,
    std::vector<GenerateResolution>& output,
    std::vector<ActiveInstance>& instances,
    ScopedConstants& scoped_constants,
    std::map<std::string, std::int64_t>& generate_variables) {
    if (node.kind == frontend::GenerateKind::Other) {
        if (node.assignment) {
            output.push_back(GenerateResolution{"assignment", prefix, true,
                std::nullopt, 0, node.location, generate_variables});
            output.back().scoped_constants = scoped_constants;
        }
        for (const auto& declaration : node.declarations) {
            if (prefix.empty()) {
                throw ElaborationError(declaration.location,
                    "generate-local signal declarations must be inside a named or implicit generate block");
            }
            const auto bounds = packed_bounds(declaration.packed_range,
                                               tokens, environment, types);
            const auto qualified_name = child_path(prefix, declaration.name);
            TypedSignal signal{qualified_name,
                packed_width(bounds, declaration.location),
                declaration.is_signed, declaration.type,
                frontend::PortDirection::Input, false, declaration.location,
                bounds ? std::optional<std::int64_t>{bounds->first} : std::nullopt,
                bounds ? std::optional<std::int64_t>{bounds->second} : std::nullopt};
            GenerateResolution resolution{"declaration", qualified_name,
                true, std::nullopt, 0, declaration.location, generate_variables};
            resolution.scope_path = prefix;
            resolution.local_name = declaration.name;
            resolution.declared_signal = std::move(signal);
            output.push_back(std::move(resolution));
        }
        return;
    }

    if (node.kind == frontend::GenerateKind::Instance) {
        if (!node.instance) {
            throw ElaborationError(node.location,
                "generate instance node has no instance declaration");
        }
        const auto path = child_path(prefix, node.instance->instance_name);
        instances.push_back(ActiveInstance{&*node.instance, environment, path, generate_variables,
                                          scoped_constants});
        output.push_back(GenerateResolution{"instance", path, true,
            std::nullopt, 0, node.location, {}});
        return;
    }

    if (node.kind == frontend::GenerateKind::Block) {
        const auto path = child_path(prefix, generated_block_name(node));
        output.push_back(GenerateResolution{"block", path, true, std::nullopt,
                                            0, node.location, {}});
        resolve_generate_list(node.body, tokens, environment, types, path, output,
                              instances, scoped_constants, generate_variables);
        return;
    }

    if (node.kind == frontend::GenerateKind::Conditional) {
        if (!node.condition) {
            throw ElaborationError(node.location,
                                   "generate-if is missing its condition expression");
        }
        const bool selected = ConstantExpression(tokens, *node.condition, environment, &types)
            .evaluate(false) != 0;
        const auto decision_path = child_path(
            prefix, "if@" + std::to_string(node.location.line));
        output.push_back(GenerateResolution{"if", decision_path, selected,
                                            std::nullopt, 0, node.location, {}});
        const auto& branch = selected ? node.body : node.else_body;
        resolve_generate_list(branch, tokens, environment, types, prefix, output,
                              instances, scoped_constants, generate_variables);
        return;
    }

    if (node.kind == frontend::GenerateKind::Loop) {
        if (!node.initial_value || !node.condition || !node.update_value) {
            throw ElaborationError(node.location,
                "generate-for is missing an initialization, condition, or update expression");
        }
        if (node.variable != node.update_variable) {
            throw ElaborationError(node.location,
                                   "generate-for update must assign the declared genvar");
        }
        constexpr ConstantType genvar_type{32, true};
        const auto assign_genvar = [&](const frontend::ExpressionSpan& expression) {
            const auto raw = evaluate_span(tokens, expression, environment, &types, genvar_type.width);
            return apply_declared_type(raw, genvar_type.width, genvar_type.is_signed, node.location);
        };
        auto value = assign_genvar(*node.initial_value);
        const auto prior = environment.find(node.variable);
        const bool had_prior = prior != environment.end();
        const auto prior_value = had_prior ? prior->second : 0;
        const auto prior_genvar = generate_variables.find(node.variable);
        const bool had_prior_genvar = prior_genvar != generate_variables.end();
        const auto prior_genvar_value = had_prior_genvar ? prior_genvar->second : 0;
        const auto prior_type = types.find(node.variable);
        const auto saved_type = prior_type == types.end() ? std::optional<ConstantType>{}
            : std::optional<ConstantType>{prior_type->second};
        types[node.variable] = genvar_type;
        auto shadowed_constant = scoped_constants.extract(node.variable);
        std::uint64_t count = 0;
        while (true) {
            environment[node.variable] = value;
            generate_variables[node.variable] = value;
            if (ConstantExpression(tokens, *node.condition, environment, &types).evaluate(false) == 0) {
                break;
            }
            if (count >= kPrototypeGenerateIterationLimit) {
                throw ElaborationError(node.location,
                    "generate-for exceeds the prototype safety limit of " +
                    std::to_string(kPrototypeGenerateIterationLimit) + " iterations");
            }
            const auto body_name = node.body.empty()
                ? "genblk@" + std::to_string(node.location.line)
                : generated_block_name(node.body.front());
            const auto iteration_path = child_path(
                prefix, body_name + "[" + std::to_string(value) + "]");
            output.push_back(GenerateResolution{"for-iteration", iteration_path,
                true, value, 0, node.location, {}});
            if (!node.body.empty() &&
                node.body.front().kind == frontend::GenerateKind::Block) {
                resolve_generate_list(node.body.front().body, tokens,
                                      environment, types, iteration_path, output,
                                      instances, scoped_constants, generate_variables);
            } else {
                resolve_generate_list(node.body, tokens, environment, types,
                                      iteration_path, output,
                                      instances, scoped_constants, generate_variables);
            }
            const auto next_value = assign_genvar(*node.update_value);
            if (next_value == value) {
                throw ElaborationError(node.location,
                                       "generate-for update does not advance the genvar");
            }
            value = next_value;
            ++count;
        }
        if (had_prior) environment[node.variable] = prior_value;
        else environment.erase(node.variable);
        if (had_prior_genvar) generate_variables[node.variable] = prior_genvar_value;
        else generate_variables.erase(node.variable);
        if (saved_type) types[node.variable] = *saved_type;
        else types.erase(node.variable);
        if (shadowed_constant) scoped_constants.insert(std::move(shadowed_constant));
        output.push_back(GenerateResolution{"for", child_path(prefix,
            "for@" + std::to_string(node.location.line)), true,
            std::nullopt, count, node.location, {}});
    }
}

std::pair<const frontend::ParsedModule*, const frontend::SyntaxUnit*>
find_module(const std::vector<frontend::SyntaxUnit>& source_units,
            const std::string& name,
            const frontend::SourceLocation& use_location) {
    const frontend::ParsedModule* found_module = nullptr;
    const frontend::SyntaxUnit* found_unit = nullptr;
    std::size_t matches = 0;
    for (const auto& unit : source_units) {
        for (const auto& module : unit.modules) {
            if (module.name == name) {
                found_module = &module;
                found_unit = &unit;
                ++matches;
            }
        }
    }
    if (matches != 1 || found_module == nullptr || found_unit == nullptr) {
        throw ElaborationError(use_location, matches == 0
            ? "instance references unresolved module '" + name + "'"
            : "module '" + name + "' has multiple declarations");
    }
    return {found_module, found_unit};
}

std::vector<const frontend::ParameterSyntax*> constants_in_source_order(
    const frontend::ParsedModule& module) {
    std::vector<const frontend::ParameterSyntax*> declarations;
    declarations.reserve(module.parameters.size() + module.localparams.size());
    for (const auto& parameter : module.parameters) declarations.push_back(&parameter);
    for (const auto& localparam : module.localparams) declarations.push_back(&localparam);
    std::sort(declarations.begin(), declarations.end(), [](const auto* left, const auto* right) {
        return left->location.byte_offset < right->location.byte_offset;
    });
    return declarations;
}

Environment resolve_instance_parameters(
    const frontend::ParsedModule& child,
    const frontend::SyntaxUnit& child_unit,
    const frontend::InstanceSyntax& instance,
    const std::vector<frontend::Token>& parent_tokens,
    const Environment& parent_environment,
    const ConstantTypes& parent_types,
    ConstantTypes& child_types) {
    const bool has_named = !instance.parameter_overrides.empty() &&
        instance.parameter_overrides.front().name.has_value();
    std::map<std::string, const frontend::ParameterOverrideSyntax*> named;
    std::vector<const frontend::ParameterOverrideSyntax*> positional;
    for (const auto& override : instance.parameter_overrides) {
        if (override.name.has_value() != has_named) {
            throw ElaborationError(override.location,
                "named and positional parameter overrides cannot be mixed");
        }
        if (has_named) {
            if (!named.emplace(*override.name, &override).second) {
                throw ElaborationError(override.location,
                    "duplicate named parameter override '" + *override.name + "'");
            }
        } else {
            positional.push_back(&override);
        }
    }
    if (!has_named && positional.size() > child.parameters.size()) {
        throw ElaborationError(instance.location,
                               "too many positional parameter overrides");
    }

    Environment child_environment;
    std::set<std::string> parameter_names;
    std::size_t ordinal = 0;
    for (const auto* declaration : constants_in_source_order(child)) {
        const auto& parameter = *declaration;
        if (child_environment.count(parameter.name)) {
            throw ElaborationError(parameter.location,
                "duplicate child constant declaration '" + parameter.name + "'");
        }
        const frontend::ParameterOverrideSyntax* override = nullptr;
        if (!parameter.is_localparam) {
            parameter_names.insert(parameter.name);
            if (has_named) {
                const auto found = named.find(parameter.name);
                if (found != named.end()) override = found->second;
            } else if (ordinal < positional.size()) {
                override = positional[ordinal];
            }
            ++ordinal;
        }
        if (!override && !parameter.initializer) {
            throw ElaborationError(parameter.location,
                parameter.is_localparam ? "child localparam requires an initializer"
                    : "child parameter '" + parameter.name + "' has no default and no instance override");
        }
        const auto destination = declared_constant_type(parameter, child_unit.tokens, child_environment, child_types);
        const auto resolved = override
            ? resolve_initializer(parent_tokens, override->value, parent_environment,
                                  parent_types, destination, override->location)
            : resolve_initializer(child_unit.tokens, *parameter.initializer, child_environment,
                                  child_types, destination, parameter.location);
        child_environment.emplace(parameter.name, resolved.value);
        child_types.emplace(parameter.name, resolved.type);
    }
    for (const auto& item : named) {
        if (parameter_names.find(item.first) == parameter_names.end()) {
            throw ElaborationError(item.second->location,
                "unknown child parameter override '" + item.first + "'");
        }
    }
    return child_environment;
}

void elaborate_direct_instances(
    const std::vector<frontend::SyntaxUnit>& source_units,
    const frontend::ParsedModule& parent,
    const frontend::SyntaxUnit& parent_unit,
    const Environment& parent_environment,
    const ConstantTypes& parent_constant_types,
    const std::vector<TypedSignal>& parent_ports,
    const std::vector<TypedSignal>& parent_signals,
    std::vector<ElaboratedInstance>& output,
    std::vector<GenerateResolution>& generate_scopes,
    const std::vector<std::string>& module_stack,
    const std::string& parent_path,
    std::vector<ActiveBind>& binds) {
    std::vector<ActiveInstance> active_instances;
    for (const auto& instance : parent.instances) {
        active_instances.push_back(ActiveInstance{
            &instance, parent_environment, instance.instance_name, {}, {}});
    }
    auto generate_environment = parent_environment;
    auto generate_types = parent_constant_types;
    std::map<std::string, std::int64_t> generate_variables;
    ScopedConstants scoped_constants;
    resolve_generate_list(parent.generate_items, parent_unit.tokens,
        generate_environment, generate_types, {}, generate_scopes,
        active_instances, scoped_constants, generate_variables);
    for (auto& entry : binds) {
        const auto& binding = *entry.binding;
        if (binding.target == (binding.hierarchical ? parent_path : parent.name)) {
            entry.matched = true;
            active_instances.push_back({&binding.instance, parent_environment,
                binding.instance.instance_name, {}, {}, entry.origin});
        }
    }

    std::map<std::string, std::uint64_t> parent_symbols;
    for (const auto& signal : parent_ports) {
        parent_symbols.emplace(signal.name, signal.width);
    }
    for (const auto& signal : parent_signals) {
        parent_symbols.emplace(signal.name, signal.width);
    }
    for (const auto& [name, type] : parent_constant_types) {
        parent_symbols.emplace(name, type.width);
    }
    for (const auto& value : parent_environment) {
        parent_symbols.emplace(value.first, 32);
    }
    std::set<std::string> instance_names;

    for (const auto& active : active_instances) {
        const auto& instance = *active.syntax;
        const auto& instance_path = active.path;
        const auto& connection_tokens = active.binding
            ? source_units[active.binding->source_unit].tokens : parent_unit.tokens;
        if (!instance_names.insert(instance_path).second) {
            throw ElaborationError(instance.location,
                "duplicate instance name '" + instance_path + "'");
        }
        const auto [child, child_unit] = find_module(source_units,
            instance.module_type, instance.location);
        if (!child->memories.empty()) {
            throw ElaborationError(child->memories.front().element.location,
                "development memory declarations are supported only on the elaborated top");
        }
        if (std::find(module_stack.begin(), module_stack.end(), child->name) !=
            module_stack.end()) {
            throw ElaborationError(instance.location,
                "recursive module instantiation detected at instance '" +
                instance.instance_name + "' of module '" + child->name + "'");
        }
        auto connection_constant_types = parent_constant_types;
        for (const auto& genvar : active.generate_variables) {
            connection_constant_types[genvar.first] = ConstantType{32, true};
        }
        for (const auto& [name, value] : active.scoped_constants) {
            connection_constant_types[name] = ConstantType{value.width, value.is_signed, value.packed_bounds};
        }
        ConstantTypes child_types;
        auto child_environment = resolve_instance_parameters(
            *child, *child_unit, instance, connection_tokens,
            active.environment, connection_constant_types, child_types);
        const bool has_named = !instance.port_connections.empty() &&
            instance.port_connections.front().formal_name.has_value();
        std::map<std::string, const frontend::PortConnectionSyntax*> named;
        std::vector<const frontend::PortConnectionSyntax*> positional;
        for (const auto& connection : instance.port_connections) {
            if (connection.formal_name.has_value() != has_named) {
                throw ElaborationError(connection.location,
                    "named and positional port connections cannot be mixed");
            }
            if (has_named) {
                if (!named.emplace(*connection.formal_name, &connection).second) {
                    throw ElaborationError(connection.location,
                        "duplicate named port connection '" +
                        *connection.formal_name + "'");
                }
            } else {
                positional.push_back(&connection);
            }
        }
        for (const auto& item : named) {
            const bool formal_exists = std::any_of(child->ports.begin(),
                child->ports.end(), [&](const auto& port) {
                    return port.name == item.first;
                });
            if (!formal_exists) {
                throw ElaborationError(item.second->location,
                    "instance '" + instance_path +
                    "' references unknown port '" + item.first + "'");
            }
        }
        if (!has_named && positional.size() != child->ports.size()) {
            throw ElaborationError(instance.location,
                "positional port connection count does not match module '" +
                child->name + "'");
        }

        ElaboratedInstance result;
        result.binding = active.binding;
        result.module_type = child->name;
        result.instance_name = instance_path;
        result.location = instance.location;
        result.generate_variables = active.generate_variables;
        result.scoped_constants = active.scoped_constants;
        for (const auto& parameter : child->parameters) {
            const auto value = child_environment.at(parameter.name);
            const auto type = child_types.at(parameter.name);
            result.parameters.push_back(TypedConstant{
                parameter.name, value, parameter.type == frontend::ScalarType::Untyped
                    ? frontend::ScalarType::Logic : parameter.type, type.is_signed, type.width,
                parameter.location, type.packed_bounds});
        }
        for (const auto& localparam : child->localparams) {
            const auto value = child_environment.at(localparam.name);
            const auto type = child_types.at(localparam.name);
            result.localparams.push_back(TypedConstant{
                localparam.name, value, localparam.type == frontend::ScalarType::Untyped
                    ? frontend::ScalarType::Logic : localparam.type, type.is_signed, type.width,
                localparam.location, type.packed_bounds});
        }
        std::set<std::string> child_symbol_names;
        for (const auto& port : child->ports) {
            if (!child_symbol_names.insert(port.name).second) {
                throw ElaborationError(port.location,
                    "module '" + child->name + "' declares duplicate port '" +
                    port.name + "'");
            }
            const auto bounds = packed_bounds(port.packed_range,
                child_unit->tokens, child_environment, child_types);
            result.ports.push_back(TypedSignal{
                port.name, packed_width(bounds, port.location), port.is_signed, port.type,
                port.direction, true, port.location,
                bounds ? std::optional<std::int64_t>{bounds->first} : std::nullopt,
                bounds ? std::optional<std::int64_t>{bounds->second} : std::nullopt});
        }
        for (const auto& signal : child->signals) {
            if (!child_symbol_names.insert(signal.name).second) {
                throw ElaborationError(signal.location,
                    "module '" + child->name +
                    "' declares a duplicate port/signal '" + signal.name + "'");
            }
            const auto bounds = packed_bounds(signal.packed_range,
                child_unit->tokens, child_environment, child_types);
            result.signals.push_back(TypedSignal{
                signal.name, packed_width(bounds, signal.location), signal.is_signed,
                signal.type, frontend::PortDirection::Input, false,
                signal.location,
                bounds ? std::optional<std::int64_t>{bounds->first} : std::nullopt,
                bounds ? std::optional<std::int64_t>{bounds->second} : std::nullopt});
        }
        std::set<std::string> formal_names;
        for (std::size_t i = 0; i < child->ports.size(); ++i) {
            const auto& formal = child->ports[i];
            if (!formal_names.insert(formal.name).second) {
                throw ElaborationError(formal.location,
                    "module '" + child->name + "' declares duplicate port '" +
                    formal.name + "'");
            }
            const frontend::PortConnectionSyntax* connection = nullptr;
            if (has_named) {
                const auto found = named.find(formal.name);
                if (found == named.end()) {
                    throw ElaborationError(instance.location,
                        "instance '" + instance_path +
                        "' is missing connection for port '" + formal.name + "'");
                }
                connection = found->second;
            } else {
                connection = positional[i];
            }

            const auto formal_width = result.ports[i].width;
            const auto& actual_start = connection_tokens[connection->actual.first_token];
            if (formal.direction == frontend::PortDirection::Output &&
                active.scoped_constants.count(actual_start.text)) {
                throw ElaborationError(connection->location,
                    "output port cannot drive generate-local constant '" + actual_start.text + "'");
            }
            auto connection_symbols = parent_symbols;
            for (const auto& value : active.environment) {
                connection_symbols.emplace(value.first, 32);
            }
            for (const auto& [name, value] : active.scoped_constants) {
                connection_symbols.insert_or_assign(name, value.width);
            }
            const auto actual_width = ExpressionWidth(connection_tokens,
                connection->actual, active.environment, connection_symbols,
                connection_constant_types, formal_width).evaluate();
            if (actual_width != formal_width) {
                throw ElaborationError(connection->location,
                    "instance '" + instance_path + "' port '" +
                    formal.name + "' connects actual expression '" +
                    expression_text(connection_tokens, connection->actual) +
                    "' width " + std::to_string(actual_width) + " to formal width " +
                    std::to_string(formal_width) + "; exact widths are required");
            }
            result.connections.push_back(ElaboratedConnection{
                formal.name,
                resolved_expression_text(connection_tokens, connection->actual,
                                         active.environment, connection_constant_types),
                formal_width, actual_width,
                formal.direction});
        }
        auto child_stack = module_stack;
        child_stack.push_back(child->name);
        elaborate_direct_instances(source_units, *child, *child_unit,
            child_environment, child_types, result.ports, result.signals,
            result.child_instances, result.generate_scopes, child_stack,
            child_path(parent_path, instance_path), binds);
        output.push_back(std::move(result));
    }
}

} // namespace

ElaborationError::ElaborationError(frontend::SourceLocation location,
                                   const std::string& message)
    : std::runtime_error(location.file + ":" + std::to_string(location.line) +
                         ":" + std::to_string(location.column) + ": " + message),
      location_(std::move(location)) {}

ElaborationResult elaborate_top(
    const std::vector<frontend::SyntaxUnit>& source_units,
    const std::string& top_module,
    const std::map<std::string, std::string>& parameter_overrides,
    const std::string& profile_id,
    const std::string& input_hash) {
    const frontend::ParsedModule* selected = nullptr;
    const frontend::SyntaxUnit* selected_unit = nullptr;
    std::size_t matches = 0;
    for (const auto& unit : source_units) {
        for (const auto& module : unit.modules) {
            if (module.name == top_module) {
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
        throw ElaborationError(location, matches == 0
            ? "top module '" + top_module + "' was not found in the source set"
            : "top module '" + top_module + "' is declared more than once");
    }

    const auto& tokens = selected_unit->tokens;
    ElaboratedModule elaborated;
    elaborated.name = selected->name;
    Environment environment;
    ConstantTypes constant_types;
    std::set<std::string> parameter_names;

    for (const auto* declaration : constants_in_source_order(*selected)) {
        const auto& parameter = *declaration;
        if (environment.count(parameter.name)) {
            throw ElaborationError(parameter.location,
                                   module_error_prefix(*selected) +
                                   "duplicate constant declaration '" + parameter.name + "'");
        }
        if (!parameter.is_localparam) parameter_names.insert(parameter.name);
        const auto value_it = parameter.is_localparam ? parameter_overrides.end()
            : parameter_overrides.find(parameter.name);
        const auto destination = declared_constant_type(parameter, tokens, environment, constant_types);
        ConstantValue resolved{};
        if (value_it != parameter_overrides.end()) {
            auto override_tokens = frontend::tokenize(value_it->second,
                                                      "<parameter-override>");
            if (override_tokens.size() < 2) {
                throw ElaborationError(parameter.location,
                                       "empty value for parameter override '" + parameter.name + "'");
            }
            const frontend::ExpressionSpan span{0, override_tokens.size() - 1};
            resolved = resolve_initializer(override_tokens, span, environment,
                constant_types, destination, parameter.location);
        } else if (parameter.initializer) {
            resolved = resolve_initializer(tokens, *parameter.initializer, environment,
                constant_types, destination, parameter.location);
        } else {
            throw ElaborationError(parameter.location,
                parameter.is_localparam ? "localparam requires an initializer"
                    : "parameter '" + parameter.name + "' has no default and no project override");
        }
        environment.emplace(parameter.name, resolved.value);
        constant_types.emplace(parameter.name, resolved.type);
        auto& output = parameter.is_localparam ? elaborated.localparams : elaborated.parameters;
        output.push_back(TypedConstant{
            parameter.name, resolved.value, parameter.type == frontend::ScalarType::Untyped
                ? frontend::ScalarType::Logic : parameter.type, resolved.type.is_signed,
            resolved.type.width, parameter.location, resolved.type.packed_bounds});
    }
    for (const auto& item : parameter_overrides) {
        if (parameter_names.find(item.first) == parameter_names.end()) {
            throw ElaborationError(selected->location,
                                   "override names no parameter on top module: '" +
                                   item.first + "'");
        }
    }

    std::set<std::string> symbol_names;
    for (const auto& port : selected->ports) {
        if (!symbol_names.insert(port.name).second) {
            throw ElaborationError(port.location,
                                   "duplicate port declaration '" + port.name + "'");
        }
        const auto bounds = packed_bounds(port.packed_range, tokens, environment, constant_types);
        elaborated.ports.push_back(TypedSignal{
            port.name, packed_width(bounds, port.location),
            port.is_signed, port.type, port.direction, true, port.location,
            bounds ? std::optional<std::int64_t>{bounds->first} : std::nullopt,
            bounds ? std::optional<std::int64_t>{bounds->second} : std::nullopt});
    }
    for (const auto& signal : selected->signals) {
        if (!symbol_names.insert(signal.name).second) {
            throw ElaborationError(signal.location,
                                   "duplicate port/signal declaration '" + signal.name + "'");
        }
        const auto bounds = packed_bounds(signal.packed_range, tokens, environment, constant_types);
        elaborated.signals.push_back(TypedSignal{
            signal.name, packed_width(bounds, signal.location),
            signal.is_signed, signal.type, frontend::PortDirection::Input,
            false, signal.location,
            bounds ? std::optional<std::int64_t>{bounds->first} : std::nullopt,
            bounds ? std::optional<std::int64_t>{bounds->second} : std::nullopt});
    }

    for (const auto& memory : selected->memories) {
        const auto& element = memory.element;
        if (!symbol_names.insert(element.name).second) {
            throw ElaborationError(element.location, "duplicate memory declaration '" + element.name + "'");
        }
        const auto indices = packed_bounds(memory.index_range, tokens, environment, constant_types);
        if (!indices || indices->first < 0 || indices->second < 0) {
            throw ElaborationError(element.location, "development memory bounds must be nonnegative constants");
        }
        const auto packed = packed_bounds(element.packed_range, tokens, environment, constant_types);
        elaborated.memories.push_back({
            {element.name, packed_width(packed, element.location), element.is_signed, element.type,
             frontend::PortDirection::Input, false, element.location,
             packed ? std::optional<std::int64_t>{packed->first} : std::nullopt,
             packed ? std::optional<std::int64_t>{packed->second} : std::nullopt},
            static_cast<std::uint64_t>(indices->first), static_cast<std::uint64_t>(indices->second)});
    }

    std::vector<ActiveBind> binds;
    for (const auto& unit : source_units) {
        for (const auto& binding : unit.binds) {
            if (!binding.hierarchical) find_module(source_units, binding.target, binding.location);
            const auto [monitor, monitor_unit] =
                find_module(source_units, binding.instance.module_type, binding.location);
            (void)monitor_unit;
            if (std::any_of(monitor->ports.begin(), monitor->ports.end(),
                    [](const auto& port) { return port.direction != frontend::PortDirection::Input; })) {
                throw ElaborationError(binding.location, "bound property modules must have only input ports");
            }
            binds.push_back({&binding, {static_cast<std::size_t>(&unit - source_units.data()),
                static_cast<std::size_t>(&binding - unit.binds.data())}});
        }
    }
    const std::vector<std::string> module_stack(1, selected->name);
    elaborate_direct_instances(source_units, *selected, *selected_unit,
        environment, constant_types, elaborated.ports, elaborated.signals, elaborated.instances,
        elaborated.generate_scopes, module_stack, selected->name, binds);
    for (const auto& entry : binds) {
        if (entry.binding->hierarchical && !entry.matched) {
            throw ElaborationError(entry.binding->location,
                "bind target instance '" + entry.binding->target + "' is not in the elaborated hierarchy");
        }
    }

    return ElaborationResult{profile_id, input_hash, std::move(elaborated)};
}

const char* scalar_type_name(frontend::ScalarType type) noexcept {
    switch (type) {
    case frontend::ScalarType::Untyped: return "untyped";
    case frontend::ScalarType::Integer: return "integer";
    case frontend::ScalarType::Logic: return "logic";
    case frontend::ScalarType::Bit: return "bit";
    }
    return "unknown";
}

} // namespace q3a::elaboration
