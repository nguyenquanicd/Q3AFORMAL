#include "tir_bit_blaster.hpp"

#include <algorithm>
#include <charconv>
#include <cstdint>
#include <limits>
#include <optional>
#include <system_error>
#include <utility>

namespace q3a::sat {
namespace {

constexpr std::uint64_t kMaximumBitBlastWidth = 64;

std::string location_prefix(const frontend::SourceLocation& location) {
    return location.file + ":" + std::to_string(location.line) + ":" +
        std::to_string(location.column) + ": ";
}

std::uint64_t parse_unsigned_digits(const std::string& digits, int base) {
    if (digits.empty()) throw std::invalid_argument("empty numeric literal");
    std::uint64_t value = 0;
    const auto parsed = std::from_chars(
        digits.data(), digits.data() + digits.size(), value, base);
    if (parsed.ec != std::errc{} || parsed.ptr != digits.data() + digits.size()) {
        throw std::invalid_argument("unsupported or out-of-range numeric literal");
    }
    return value;
}

std::vector<Literal> constant_bits(
    const lowering::TypedExpression& expression) {
    if (expression.width == 0 || expression.width > kMaximumBitBlastWidth) {
        throw std::invalid_argument("constant width is outside the bit-blaster limit");
    }
    std::uint64_t raw = 0;
    if (expression.kind == "constant" && !expression.is_signed && !expression.value.empty() &&
        expression.value.front() != '-') {
        raw = parse_unsigned_digits(expression.value, 10);
    } else if (expression.kind == "constant") {
        std::int64_t signed_value = 0;
        const auto parsed = std::from_chars(
            expression.value.data(),
            expression.value.data() + expression.value.size(), signed_value);
        if (parsed.ec != std::errc{} ||
            parsed.ptr != expression.value.data() + expression.value.size()) {
            throw std::invalid_argument("malformed constant value");
        }
        raw = static_cast<std::uint64_t>(signed_value);
    } else {
        const auto& text = expression.value;
        if (text == "'0" || text == "'1") {
            const bool one = text == "'1";
            std::vector<Literal> bits;
            bits.reserve(static_cast<std::size_t>(expression.width));
            // Boolean constants are encoded later by the owning encoder.
            for (std::uint64_t bit = 0; bit < expression.width; ++bit) {
                bits.push_back(one ? 1 : 0);
            }
            return bits;
        }
        const auto quote = text.find('\'');
        if (quote == std::string::npos) {
            std::int64_t signed_value = 0;
            const auto parsed = std::from_chars(
                text.data(), text.data() + text.size(), signed_value);
            if (parsed.ec != std::errc{} ||
                parsed.ptr != text.data() + text.size()) {
                throw std::invalid_argument("malformed unsized integer literal");
            }
            raw = static_cast<std::uint64_t>(signed_value);
        } else {
            std::size_t radix_index = quote + 1;
            if (radix_index < text.size() &&
                (text[radix_index] == 's' || text[radix_index] == 'S')) {
                ++radix_index;
            }
            if (radix_index >= text.size()) {
                throw std::invalid_argument("based literal has no radix");
            }
            const char radix = static_cast<char>(text[radix_index]);
            const int base = radix == 'b' || radix == 'B' ? 2 :
                radix == 'o' || radix == 'O' ? 8 :
                radix == 'd' || radix == 'D' ? 10 :
                radix == 'h' || radix == 'H' ? 16 : 0;
            if (base == 0) throw std::invalid_argument("unsupported literal radix");
            std::string digits = text.substr(radix_index + 1);
            digits.erase(std::remove(digits.begin(), digits.end(), '_'), digits.end());
            raw = parse_unsigned_digits(digits, base);
        }
    }

    std::vector<Literal> bits;
    bits.reserve(static_cast<std::size_t>(expression.width));
    for (std::uint64_t bit = 0; bit < expression.width; ++bit) {
        bits.push_back(bit < 64 && ((raw >> bit) & 1U) != 0 ? 1 : 0);
    }
    return bits;
}

std::uint64_t width_mask(std::uint64_t width) {
    if (width == 0) return 0;
    if (width >= 64) return std::numeric_limits<std::uint64_t>::max();
    return (std::uint64_t{1} << width) - 1;
}

std::uint64_t extend_constant(std::uint64_t bits,
                              const lowering::TypedExpression& source,
                              std::uint64_t width, bool sign_extend) {
    bits &= width_mask(source.width);
    if (sign_extend && source.width < width &&
        ((bits >> (source.width - 1)) & 1U) != 0) {
        bits |= ~width_mask(source.width);
    }
    return bits & width_mask(width);
}

std::optional<std::uint64_t> try_constant_value(
    const lowering::TypedExpression& expression) {
    if (expression.width == 0 || expression.width > kMaximumBitBlastWidth) {
        return std::nullopt;
    }
    if (expression.kind == "literal" || expression.kind == "constant") {
        try {
            const auto bits = constant_bits(expression);
            std::uint64_t value = 0;
            for (std::size_t bit = 0; bit < bits.size(); ++bit) {
                if (bits[bit] == 1) value |= std::uint64_t{1} << bit;
            }
            return value;
        } catch (const std::exception&) {
            return std::nullopt;
        }
    }
    if (expression.kind == "concatenation") {
        std::uint64_t value = 0;
        for (const auto& operand : expression.operands) {
            const auto part = try_constant_value(operand);
            if (!part || operand.width > 64 || expression.width > 64) {
                return std::nullopt;
            }
            if (operand.width == 64) {
                if (value != 0) return std::nullopt;
                value = *part;
            } else {
                value = (value << operand.width) |
                    (*part & width_mask(operand.width));
            }
        }
        return value & width_mask(expression.width);
    }
    if (expression.kind == "assignment_resize" && expression.operands.size() == 1) {
        const auto& source = expression.operands.front();
        const auto value = try_constant_value(source);
        if (!value) return std::nullopt;
        return extend_constant(*value, source, expression.width, source.is_signed);
    }
    if (expression.kind == "bit_vector_function" && expression.operands.size() == 1) {
        auto bits = try_constant_value(expression.operands.front());
        if (!bits) return std::nullopt;
        unsigned count = 0;
        for (auto value = *bits; value != 0; value >>= 1) count += value & 1U;
        if (expression.value == "$countones") return count;
        if (expression.value == "$onehot") return count == 1;
        if (expression.value == "$onehot0") return count <= 1;
        return std::nullopt;
    }
    if (expression.kind == "unary" && expression.operands.size() == 1) {
        const auto operand = try_constant_value(expression.operands.front());
        if (!operand) return std::nullopt;
        const auto mask = width_mask(expression.width);
        if (expression.value == "+") return *operand & mask;
        if (expression.value == "-") return (std::uint64_t{0} - *operand) & mask;
        if (expression.value == "~") return ~*operand & mask;
        if (expression.value == "!") return *operand == 0 ? 1U : 0U;
        return std::nullopt;
    }
    if (expression.kind == "conditional" && expression.operands.size() == 3) {
        const auto condition = try_constant_value(expression.operands[0]);
        const auto when_true = try_constant_value(expression.operands[1]);
        const auto when_false = try_constant_value(expression.operands[2]);
        if (!condition || !when_true || !when_false) return std::nullopt;
        const bool selected = *condition != 0;
        const bool signed_branches = expression.operands[1].is_signed &&
            expression.operands[2].is_signed;
        return extend_constant(selected ? *when_true : *when_false,
            expression.operands[selected ? 1 : 2], expression.width, signed_branches);
    }
    if (expression.kind == "binary" && expression.operands.size() == 2) {
        const auto& left_expression = expression.operands[0];
        const auto& right_expression = expression.operands[1];
        const auto left_value = try_constant_value(left_expression);
        const auto right_value = try_constant_value(right_expression);
        if (!left_value || !right_value) return std::nullopt;
        const auto mask = width_mask(expression.width);
        if (expression.value == "<<" || expression.value == ">>" ||
            expression.value == ">>>") {
            const auto amount = *right_value & width_mask(right_expression.width);
            if (right_expression.is_signed && right_expression.width != 0 &&
                ((amount >> (right_expression.width - 1)) & 1U) != 0) {
                return std::nullopt;
            }
            const auto source = *left_value & width_mask(left_expression.width);
            const bool arithmetic_right = expression.value == ">>>" &&
                left_expression.is_signed && left_expression.width != 0 &&
                ((source >> (left_expression.width - 1)) & 1U) != 0;
            std::uint64_t shifted = 0;
            if (expression.value == "<<") {
                shifted = amount >= 64 ? 0 : source << amount;
            } else if (expression.value == ">>") {
                shifted = amount >= 64 ? 0 : source >> amount;
            } else if (amount >= left_expression.width) {
                shifted = arithmetic_right ? mask : 0;
            } else {
                shifted = source >> amount;
                if (arithmetic_right && amount != 0) {
                    shifted |= mask & ~width_mask(left_expression.width - amount);
                }
            }
            return shifted & mask;
        }
        const bool signed_operands =
            left_expression.is_signed && right_expression.is_signed;
        const auto& op = expression.value;
        if (op == "&&") return *left_value != 0 && *right_value != 0;
        if (op == "||") return *left_value != 0 || *right_value != 0;
        const auto comparison_width = std::max(left_expression.width, right_expression.width);
        auto left = extend_constant(*left_value, left_expression, comparison_width, signed_operands);
        auto right = extend_constant(*right_value, right_expression, comparison_width, signed_operands);
        if (op == "==") return left == right;
        if (op == "!=") return left != right;
        const auto sign = signed_operands ? std::uint64_t{1} << (comparison_width - 1) : 0;
        if (op == "<") return (left ^ sign) < (right ^ sign);
        if (op == "<=") return (left ^ sign) <= (right ^ sign);
        if (op == ">") return (left ^ sign) > (right ^ sign);
        if (op == ">=") return (left ^ sign) >= (right ^ sign);
        std::uint64_t value = 0;
        if (expression.value == "+") value = left + right;
        else if (expression.value == "-") value = left - right;
        else if (expression.value == "&") value = left & right;
        else if (expression.value == "|") value = left | right;
        else if (expression.value == "^") value = left ^ right;
        else if (op == "~^" || op == "^~") value = ~(left ^ right);
        else {
            return std::nullopt;
        }
        return value & mask;
    }
    return std::nullopt;
}

} // namespace

BitBlastError::BitBlastError(frontend::SourceLocation location,
                           const std::string& message, bool unsupported)
    : std::runtime_error(location_prefix(location) + message),
      location_(std::move(location)), unsupported_(unsupported) {}

[[noreturn]] void TirBitBlaster::fail(
    const lowering::TypedExpression& expression, const std::string& message) const {
    throw BitBlastError(expression.location, message);
}

Literal TirBitBlaster::constant(bool value) {
    auto& cached = value ? true_literal_ : false_literal_;
    if (cached == 0) {
        cached = static_cast<Literal>(solver_.new_variable());
        solver_.add_clause({value ? cached : static_cast<Literal>(-cached)});
    }
    return cached;
}

Literal TirBitBlaster::make_and(Literal left, Literal right) {
    const auto output = static_cast<Literal>(solver_.new_variable());
    solver_.add_clause({static_cast<Literal>(-output), left});
    solver_.add_clause({static_cast<Literal>(-output), right});
    solver_.add_clause({output, static_cast<Literal>(-left),
                        static_cast<Literal>(-right)});
    return output;
}

Literal TirBitBlaster::make_or(Literal left, Literal right) {
    const auto output = static_cast<Literal>(solver_.new_variable());
    solver_.add_clause({static_cast<Literal>(-left), output});
    solver_.add_clause({static_cast<Literal>(-right), output});
    solver_.add_clause({left, right, static_cast<Literal>(-output)});
    return output;
}

Literal TirBitBlaster::make_xor(Literal left, Literal right) {
    const auto output = static_cast<Literal>(solver_.new_variable());
    solver_.add_clause({left, right, static_cast<Literal>(-output)});
    solver_.add_clause({static_cast<Literal>(-left), static_cast<Literal>(-right),
                        static_cast<Literal>(-output)});
    solver_.add_clause({static_cast<Literal>(-left), right, output});
    solver_.add_clause({left, static_cast<Literal>(-right), output});
    return output;
}

Literal TirBitBlaster::make_mux(
    Literal select, Literal when_true, Literal when_false) {
    const auto output = static_cast<Literal>(solver_.new_variable());
    solver_.add_clause({static_cast<Literal>(-select),
                        static_cast<Literal>(-when_true), output});
    solver_.add_clause({static_cast<Literal>(-select), when_true,
                        static_cast<Literal>(-output)});
    solver_.add_clause({select, static_cast<Literal>(-when_false), output});
    solver_.add_clause({select, when_false, static_cast<Literal>(-output)});
    return output;
}

std::vector<Literal> TirBitBlaster::extend_bits(
    std::vector<Literal> bits, std::size_t width, bool sign_extend) {
    const auto fill = sign_extend && !bits.empty()
        ? bits.back() : constant(false);
    bits.resize(width, fill);
    return bits;
}

Literal TirBitBlaster::compare_less(
    const std::vector<Literal>& left,
    const std::vector<Literal>& right,
    bool signed_comparison) {
    auto less = constant(false);
    auto equal_prefix = constant(true);
    for (std::size_t bit = left.size(); bit-- > 0;) {
        auto left_bit = left[bit];
        auto right_bit = right[bit];
        if (signed_comparison && bit + 1 == left.size()) {
            // Flipping the sign bit maps two's-complement order to unsigned order.
            left_bit = static_cast<Literal>(-left_bit);
            right_bit = static_cast<Literal>(-right_bit);
        }
        const auto this_bit_less = make_and(
            equal_prefix,
            make_and(static_cast<Literal>(-left_bit), right_bit));
        less = make_or(less, this_bit_less);
        const auto this_bit_equal = static_cast<Literal>(
            -make_xor(left_bit, right_bit));
        equal_prefix = make_and(equal_prefix, this_bit_equal);
    }
    return less;
}

Literal TirBitBlaster::reduce_or(const std::vector<Literal>& bits) {
    auto result = constant(false);
    for (const auto bit : bits) result = make_or(result, bit);
    return result;
}

Literal TirBitBlaster::reduce_and(const std::vector<Literal>& bits) {
    auto result = constant(true);
    for (const auto bit : bits) result = make_and(result, bit);
    return result;
}

std::vector<Literal>& TirBitBlaster::signal_bits(
    const lowering::TypedExpression& expression) {
    if (expression.width == 0 || expression.width > kMaximumBitBlastWidth) {
        fail(expression, "signal width exceeds the current 64-bit CNF bit-blast subset");
    }
    auto& bits = signal_variables_[expression.value];
    if (!bits.empty() && bits.size() != expression.width) {
        fail(expression, "one signal name was encountered with inconsistent widths");
    }
    while (bits.size() < expression.width) {
        bits.push_back(static_cast<Literal>(solver_.new_variable()));
    }
    return bits;
}

std::vector<Literal> TirBitBlaster::encode_literal(
    const lowering::TypedExpression& expression) {
    std::vector<Literal> raw;
    try {
        raw = constant_bits(expression);
    } catch (const std::exception& error) {
        fail(expression, error.what());
    }
    for (auto& bit : raw) bit = bit == 0 ? constant(false) : constant(true);
    return raw;
}

Literal TirBitBlaster::encode_unary(
    const lowering::TypedExpression& expression) {
    if (expression.operands.size() != 1) fail(expression, "unary node must have one operand");
    const auto& operand = expression.operands.front();
    auto bits = encode(operand);
    if (expression.value == "!") return static_cast<Literal>(-reduce_or(bits));
    if (expression.value == "+") {
        if (expression.width != bits.size()) fail(expression, "unary plus width mismatch");
        return expression.width == 1 ? bits.front() : 0;
    }
    if (expression.value == "~") {
        if (expression.width != bits.size()) fail(expression, "bitwise-not width mismatch");
        if (bits.size() != 1) fail(expression, "vector result must use encode_bits");
        return static_cast<Literal>(-bits.front());
    }
    fail(expression, "unsupported unary operator for the current SAT bit-blast subset");
}

std::vector<Literal> TirBitBlaster::add_equal_width(const std::vector<Literal>& left,
                                                    const std::vector<Literal>& right, bool subtract) {
    auto carry = constant(subtract);
    std::vector<Literal> result;
    result.reserve(left.size());
    for (std::size_t bit = 0; bit < left.size(); ++bit) {
        const auto right_bit = subtract ? static_cast<Literal>(-right[bit]) : right[bit];
        const auto propagate = make_xor(left[bit], right_bit);
        result.push_back(make_xor(propagate, carry));
        carry = make_or(make_and(left[bit], right_bit), make_and(propagate, carry));
    }
    return result;
}

std::vector<Literal> TirBitBlaster::encode_bit_vector_function(const lowering::TypedExpression& expression) {
    const bool count = expression.value == "$countones";
    if (!frontend::is_bit_vector_assertion_function(expression.value) ||
        expression.operands.size() != 1 || expression.width != (count ? 32U : 1U) ||
        expression.is_signed != count) {
        fail(expression, "malformed bit-vector function");
    }
    const auto bits = encode(expression.operands.front());
    if (count) {
        const auto count_bits = [&](const auto& self, std::size_t first, std::size_t length) -> std::vector<Literal> {
            if (length == 1) return {bits[first]};
            std::size_t result_width = 1;
            for (auto remaining = length; remaining > 1; remaining >>= 1) ++result_width;
            const auto left_length = length / 2;
            auto lhs = extend_bits(self(self, first, left_length), result_width, false);
            auto rhs = extend_bits(self(self, first + left_length, length - left_length), result_width, false);
            return add_equal_width(lhs, rhs, false);
        };
        return extend_bits(count_bits(count_bits, 0, bits.size()), expression.width, false);
    }
    auto seen = constant(false);
    auto multiple = seen;
    for (const auto bit : bits) {
        multiple = make_or(multiple, make_and(seen, bit));
        seen = make_or(seen, bit);
    }
    const auto at_most_one = static_cast<Literal>(-multiple);
    return {expression.value == "$onehot" ? make_and(seen, at_most_one) : at_most_one};
}

std::vector<Literal> TirBitBlaster::encode_binary(
    const lowering::TypedExpression& expression) {
    if (expression.operands.size() != 2) fail(expression, "binary node must have two operands");
    const auto& left_expression = expression.operands[0];
    const auto& right_expression = expression.operands[1];
    const auto left = encode(left_expression);
    const auto right = encode(right_expression);
    if (expression.value == "&&" || expression.value == "||") {
        const auto left_truth = reduce_or(left);
        const auto right_truth = reduce_or(right);
        const auto value = expression.value == "&&"
            ? make_and(left_truth, right_truth)
            : make_or(left_truth, right_truth);
        if (expression.width != 1) fail(expression, "logical operator result must be one bit");
        return {value};
    }
    if (expression.value == "<<" || expression.value == ">>" ||
        expression.value == ">>>") {
        if (expression.width != left.size()) {
            fail(expression, "shift result width must equal the left operand width");
        }
        const auto amount = try_constant_value(right_expression);
        if (!amount) {
            throw BitBlastError(expression.location,
                "Phase 0 supports only compile-time constant shift distances", true);
        }
        if (right_expression.is_signed && right_expression.width != 0 &&
            ((*amount >> (right_expression.width - 1)) & 1U) != 0) {
            throw BitBlastError(expression.location,
                "negative constant shift distances are unsupported", true);
        }
        const bool arithmetic_right = expression.value == ">>>" &&
            left_expression.is_signed;
        std::vector<Literal> result(left.size(), constant(false));
        if (*amount >= left.size()) {
            if (arithmetic_right && !left.empty()) {
                std::fill(result.begin(), result.end(), left.back());
            }
            return result;
        }
        const auto shift = static_cast<std::size_t>(*amount);
        for (std::size_t bit = 0; bit < left.size(); ++bit) {
            if (expression.value == "<<") {
                if (bit >= shift) result[bit] = left[bit - shift];
            } else if (bit + shift < left.size()) {
                result[bit] = left[bit + shift];
            } else if (arithmetic_right) {
                result[bit] = left.back();
            }
        }
        return result;
    }
    if (expression.value == "+" || expression.value == "-") {
        const auto result_width = std::max(left.size(), right.size());
        if (expression.width != result_width) {
            fail(expression, "arithmetic result width must equal the maximum operand width in this subset");
        }
        const bool signed_arithmetic =
            left_expression.is_signed && right_expression.is_signed;
        auto extend = [this, result_width, signed_arithmetic](
                          std::vector<Literal> bits) {
            const auto fill = signed_arithmetic && !bits.empty()
                ? bits.back() : constant(false);
            bits.resize(result_width, fill);
            return bits;
        };
        const auto lhs = extend(left);
        const auto rhs = extend(right);
        return add_equal_width(lhs, rhs, expression.value == "-");
    }
    if (expression.value == "<" || expression.value == "<=" ||
        expression.value == ">" || expression.value == ">=") {
        if (expression.width != 1) fail(expression, "relational operator result must be one bit");
        const bool signed_comparison =
            left_expression.is_signed && right_expression.is_signed;
        const auto comparison_width = std::max(left.size(), right.size());
        const auto extended_left = extend_bits(left, comparison_width,
                                               signed_comparison);
        const auto extended_right = extend_bits(right, comparison_width,
                                                signed_comparison);
        const auto less = compare_less(extended_left, extended_right,
                                       signed_comparison);
        const auto greater = compare_less(extended_right, extended_left,
                                          signed_comparison);
        const auto equal = static_cast<Literal>(-make_xor(less, greater));
        if (expression.value == "<") return {less};
        if (expression.value == "<=") return {make_or(less, equal)};
        if (expression.value == ">") return {greater};
        return {make_or(greater, equal)};
    }
    if (expression.value == "==" || expression.value == "!=") {
        const bool signed_equality =
            left_expression.is_signed && right_expression.is_signed;
        const auto comparison_width = std::max(left.size(), right.size());
        const auto extended_left = extend_bits(left, comparison_width,
                                               signed_equality);
        const auto extended_right = extend_bits(right, comparison_width,
                                                signed_equality);
        std::vector<Literal> equal_bits;
        equal_bits.reserve(comparison_width);
        for (std::size_t index = 0; index < comparison_width; ++index) {
            equal_bits.push_back(static_cast<Literal>(-make_xor(
                extended_left[index], extended_right[index])));
        }
        const auto equal = reduce_and(equal_bits);
        if (expression.width != 1) fail(expression, "equality operator result must be one bit");
        return {expression.value == "==" ? equal : static_cast<Literal>(-equal)};
    }
    const auto result_width = std::max(left.size(), right.size());
    if (expression.width != result_width) {
        fail(expression, "bitwise result width must equal the maximum operand width");
    }
    const bool signed_bitwise =
        left_expression.is_signed && right_expression.is_signed;
    const auto extended_left = extend_bits(left, result_width, signed_bitwise);
    const auto extended_right = extend_bits(right, result_width, signed_bitwise);
    std::vector<Literal> result;
    result.reserve(result_width);
    for (std::size_t index = 0; index < result_width; ++index) {
        if (expression.value == "&") result.push_back(make_and(extended_left[index], extended_right[index]));
        else if (expression.value == "|" ) result.push_back(make_or(extended_left[index], extended_right[index]));
        else if (expression.value == "^") result.push_back(make_xor(extended_left[index], extended_right[index]));
        else if (expression.value == "~^" || expression.value == "^~") {
            result.push_back(static_cast<Literal>(-make_xor(extended_left[index], extended_right[index])));
        } else {
            fail(expression, "unsupported binary operator for the current SAT bit-blast subset");
        }
    }
    return result;
}

std::vector<Literal> TirBitBlaster::encode_conditional(
    const lowering::TypedExpression& expression) {
    if (expression.operands.size() != 3) {
        fail(expression, "conditional node must have condition and two branches");
    }
    const auto condition = reduce_or(encode(expression.operands[0]));
    const auto when_true = encode(expression.operands[1]);
    const auto when_false = encode(expression.operands[2]);
    const auto result_width = std::max(when_true.size(), when_false.size());
    if (expression.width != result_width) {
        fail(expression, "conditional result width must equal the maximum branch width");
    }
    const bool signed_branches =
        expression.operands[1].is_signed && expression.operands[2].is_signed;
    const auto extended_true = extend_bits(when_true, result_width, signed_branches);
    const auto extended_false = extend_bits(when_false, result_width, signed_branches);
    std::vector<Literal> result;
    result.reserve(result_width);
    for (std::size_t index = 0; index < result_width; ++index) {
        result.push_back(make_mux(condition, extended_true[index], extended_false[index]));
    }
    return result;
}

std::vector<Literal> TirBitBlaster::encode_concatenation(
    const lowering::TypedExpression& expression) {
    std::vector<Literal> result;
    for (auto operand = expression.operands.rbegin();
         operand != expression.operands.rend(); ++operand) {
        const auto bits = encode(*operand);
        result.insert(result.end(), bits.begin(), bits.end());
    }
    if (result.size() != expression.width) {
        fail(expression, "concatenation width does not match its operands");
    }
    return result;
}

std::vector<Literal> TirBitBlaster::encode_casez_match(
    const lowering::TypedExpression& expression) {
    if (expression.operands.size() != 3 || expression.width != 1) {
        fail(expression, "casez_match must contain selector, pattern, mask, and one-bit result");
    }
    const auto selector = encode(expression.operands[0]);
    const auto pattern = encode(expression.operands[1]);
    const auto mask = encode(expression.operands[2]);
    if (selector.size() != pattern.size() || selector.size() != mask.size()) {
        fail(expression, "casez selector, pattern, and mask widths must match");
    }
    std::vector<Literal> constrained_bits;
    constrained_bits.reserve(selector.size());
    for (std::size_t index = 0; index < selector.size(); ++index) {
        const auto equal = static_cast<Literal>(-make_xor(selector[index], pattern[index]));
        constrained_bits.push_back(make_or(static_cast<Literal>(-mask[index]), equal));
    }
    return {reduce_and(constrained_bits)};
}

std::vector<Literal> TirBitBlaster::encode(
    const lowering::TypedExpression& expression) {
    if (expression.width == 0 || expression.width > kMaximumBitBlastWidth) {
        fail(expression, "expression width exceeds the current 64-bit CNF bit-blast subset");
    }
    if (expression.kind == "signal" || expression.kind == "history_ref") {
        return signal_bits(expression);
    }
    if (expression.kind == "literal" || expression.kind == "constant") {
        return encode_literal(expression);
    }
    if (expression.kind == "assignment_resize") {
        if (expression.operands.size() != 1) {
            fail(expression, "assignment-resize node must have one operand");
        }
        auto result = encode(expression.operands.front());
        return extend_bits(std::move(result),
            static_cast<std::size_t>(expression.width),
            expression.operands.front().is_signed);
    }
    if (expression.kind == "unary") {
        if (expression.value == "+") {
            if (expression.operands.size() != 1) {
                fail(expression, "unary node must have one operand");
            }
            auto result = encode(expression.operands.front());
            if (result.size() != expression.width) {
                fail(expression, "unary plus width mismatch");
            }
            return result;
        }
        if (expression.value == "~" && expression.width > 1) {
            if (expression.operands.size() != 1) fail(expression, "unary node must have one operand");
            auto result = encode(expression.operands.front());
            if (result.size() != expression.width) fail(expression, "bitwise-not width mismatch");
            for (auto& bit : result) bit = static_cast<Literal>(-bit);
            return result;
        }
        if (expression.value == "-") {
            if (expression.operands.size() != 1) {
                fail(expression, "unary node must have one operand");
            }
            auto operand = encode(expression.operands.front());
            if (operand.size() != expression.width) {
                fail(expression, "unary minus width mismatch");
            }
            auto carry = constant(true);
            std::vector<Literal> result;
            result.reserve(operand.size());
            for (const auto bit : operand) {
                const auto inverted = static_cast<Literal>(-bit);
                result.push_back(make_xor(inverted, carry));
                carry = make_and(inverted, carry);
            }
            return result;
        }
        return {encode_unary(expression)};
    }
    if (expression.kind == "binary") return encode_binary(expression);
    if (expression.kind == "bit_vector_function") return encode_bit_vector_function(expression);
    if (expression.kind == "conditional") return encode_conditional(expression);
    if (expression.kind == "concatenation") return encode_concatenation(expression);
    if (expression.kind == "select") {
        if (expression.operands.size() != 2) {
            fail(expression, "normalized select node must contain a vector and source bit offset");
        }
        const auto source = encode(expression.operands[0]);
        const auto& offset_expression = expression.operands[1];
        const auto offset = try_constant_value(offset_expression);
        if (!offset || (offset_expression.is_signed &&
            ((*offset >> (offset_expression.width - 1)) & 1U) != 0)) {
            fail(expression, "select source bit offset must be a nonnegative compile-time constant");
        }
        if (expression.value == "bit") {
            if (expression.width != 1 || *offset >= source.size()) {
                fail(expression, "bit-select offset or result width is invalid");
            }
            return {source[static_cast<std::size_t>(*offset)]};
        }
        if (expression.value == "part") {
            if (*offset > source.size() ||
                expression.width > source.size() - static_cast<std::size_t>(*offset)) {
                fail(expression, "part-select offset/width exceeds its packed vector");
            }
            std::vector<Literal> result;
            result.reserve(static_cast<std::size_t>(expression.width));
            for (std::uint64_t bit = 0; bit < expression.width; ++bit) {
                result.push_back(source[static_cast<std::size_t>(*offset + bit)]);
            }
            return result;
        }
        fail(expression, "unsupported select kind in normalized T-IR");
    }
    if (expression.kind == "casez_match") return encode_casez_match(expression);
    fail(expression, "T-IR expression kind is outside the current SAT bit-blast subset: " +
                     expression.kind);
}

std::vector<Literal> TirBitBlaster::encode_bits(
    const lowering::TypedExpression& expression) {
    return encode(expression);
}

std::vector<Literal> TirBitBlaster::encode_signal(
    const std::string& name, std::uint64_t width, bool is_signed,
    frontend::SourceLocation location) {
    const lowering::TypedExpression signal{
        "signal", name, width, is_signed, std::move(location), {}};
    return encode(signal);
}

Literal TirBitBlaster::encode_predicate(
    const lowering::TypedExpression& expression) {
    const auto bits = encode(expression);
    if (expression.width != 1 || bits.size() != 1) {
        fail(expression, "property predicate must be exactly one bit");
    }
    return bits.front();
}

void TirBitBlaster::require_true(const lowering::TypedExpression& expression) {
    solver_.add_clause({encode_predicate(expression)});
}

void TirBitBlaster::require_false(const lowering::TypedExpression& expression) {
    solver_.add_clause({static_cast<Literal>(-encode_predicate(expression))});
}

} // namespace q3a::sat
