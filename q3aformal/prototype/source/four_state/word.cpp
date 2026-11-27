#include "word.hpp"

#include <limits>
#include <stdexcept>

namespace q3a::four_state {
namespace {

std::uint64_t width_mask(unsigned width) {
    if (width == 0 || width > 64) throw std::invalid_argument("four-state width must be 1..64");
    return std::numeric_limits<std::uint64_t>::max() >> (64 - width);
}

std::uint64_t known_one(Word value) {
    return value.data() & ~value.meta();
}

std::uint64_t known_zero(Word value) {
    return value.mask() & ~(value.data() | value.meta());
}

unsigned common_width(Word left, Word right) {
    if (left.width() != right.width()) throw std::invalid_argument("four-state operand widths differ");
    return left.width();
}

Logic invert(Logic value) {
    if (value == Logic::Zero) return Logic::One;
    if (value == Logic::One) return Logic::Zero;
    return Logic::X;
}

} // namespace

Word::Word(unsigned width, std::uint64_t meta, std::uint64_t data)
    : width_(width), meta_(meta & width_mask(width)), data_(data & width_mask(width)) {}

Word Word::parse(std::string_view bits) {
    if (bits.empty() || bits.size() > 64) throw std::invalid_argument("four-state word must have 1..64 digits");
    std::uint64_t meta = 0;
    std::uint64_t data = 0;
    for (char bit : bits) {
        meta <<= 1;
        data <<= 1;
        switch (bit) {
        case '0': break;
        case '1': data |= 1; break;
        case 'X': case 'x': meta |= 1; break;
        case 'Z': case 'z': meta |= 1; data |= 1; break;
        default: throw std::invalid_argument("invalid four-state digit");
        }
    }
    return Word(static_cast<unsigned>(bits.size()), meta, data);
}

std::uint64_t Word::mask() const noexcept {
    return std::numeric_limits<std::uint64_t>::max() >> (64 - width_);
}

std::string Word::bits() const {
    std::string result(width_, '0');
    for (unsigned bit = 0; bit < width_; ++bit) {
        const auto code = (((meta_ >> bit) & 1) << 1) | ((data_ >> bit) & 1);
        result[width_ - 1 - bit] = "01xz"[code];
    }
    return result;
}

Word Word::resized(unsigned width, bool sign_extend) const {
    const auto extension = width_mask(width) & ~mask();
    if (!sign_extend || extension == 0) return Word(width, meta_, data_);
    const auto sign = std::uint64_t{1} << (width_ - 1);
    return Word(width, meta_ | ((meta_ & sign) == 0 ? 0 : extension),
                data_ | ((data_ & sign) == 0 ? 0 : extension));
}

Word Word::slice(unsigned least_bit, unsigned width) const {
    if (width == 0 || least_bit >= width_ || width > width_ - least_bit)
        throw std::invalid_argument("four-state select is outside the word");
    return Word(width, meta_ >> least_bit, data_ >> least_bit);
}

Word concatenate(Word high, Word low) {
    const auto width = high.width() + low.width();
    if (width > 64) throw std::invalid_argument("four-state concatenation exceeds 64 bits");
    return Word(width, (high.meta() << low.width()) | low.meta(),
                (high.data() << low.width()) | low.data());
}

Word bit_not(Word value) {
    return Word(value.width(), value.meta(), known_zero(value));
}

Word bit_and(Word left, Word right) {
    const auto width = common_width(left, right);
    const auto ones = known_one(left) & known_one(right);
    const auto zeros = known_zero(left) | known_zero(right);
    return Word(width, ~(ones | zeros), ones);
}

Word bit_or(Word left, Word right) {
    const auto width = common_width(left, right);
    const auto ones = known_one(left) | known_one(right);
    const auto zeros = known_zero(left) & known_zero(right);
    return Word(width, ~(ones | zeros), ones);
}

Word bit_xor(Word left, Word right) {
    const auto width = common_width(left, right);
    const auto meta = left.meta() | right.meta();
    return Word(width, meta, (left.data() ^ right.data()) & ~meta);
}

Logic truth(Word value) {
    if (known_one(value) != 0) return Logic::One;
    return value.meta() != 0 ? Logic::X : Logic::Zero;
}

Logic logical_not(Word value) { return invert(truth(value)); }

Logic logical_and(Word left, Word right) {
    const auto a = truth(left);
    const auto b = truth(right);
    if (a == Logic::Zero || b == Logic::Zero) return Logic::Zero;
    return a == Logic::One && b == Logic::One ? Logic::One : Logic::X;
}

Logic logical_or(Word left, Word right) {
    const auto a = truth(left);
    const auto b = truth(right);
    if (a == Logic::One || b == Logic::One) return Logic::One;
    return a == Logic::Zero && b == Logic::Zero ? Logic::Zero : Logic::X;
}

Logic reduce_and(Word value) {
    if (known_zero(value) != 0) return Logic::Zero;
    return value.meta() != 0 ? Logic::X : Logic::One;
}

Logic reduce_or(Word value) { return truth(value); }

Logic reduce_xor(Word value) {
    if (value.meta() != 0) return Logic::X;
    auto bits = value.data();
    bool odd = false;
    while (bits != 0) {
        bits &= bits - 1;
        odd = !odd;
    }
    return odd ? Logic::One : Logic::Zero;
}

std::optional<std::int64_t> packed_index(Word value, bool signed_index) {
    if (value.meta() != 0) return std::nullopt;
    const auto raw = value.data();
    if (signed_index && (raw >> (value.width() - 1)) != 0) {
        return -1 - static_cast<std::int64_t>(value.mask() & ~raw);
    }
    if (raw > static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max())) return std::nullopt;
    return static_cast<std::int64_t>(raw);
}

std::optional<std::int64_t> offset_packed_index(std::int64_t base, int delta) {
    using Limits = std::numeric_limits<std::int64_t>;
    if ((delta > 0 && base > Limits::max() - delta) || (delta < 0 && base < Limits::min() - delta)) {
        return std::nullopt;
    }
    return base + delta;
}

std::optional<std::int64_t> offset_packed_index(Word base, bool signed_index, int delta) {
    if (const auto signed_base = packed_index(base, signed_index)) return offset_packed_index(*signed_base, delta);
    if (base.meta() != 0 || signed_index || delta >= 0) return std::nullopt;
    constexpr auto maximum = static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max());
    const auto reduced = base.data() - static_cast<std::uint64_t>(-delta);
    if (reduced > maximum) return std::nullopt;
    return static_cast<std::int64_t>(reduced);
}

int indexed_result_delta(bool descending, bool upward, unsigned width, unsigned bit) {
    const int position = static_cast<int>(bit);
    const int span = static_cast<int>(width - 1);
    if (descending) return upward ? position : position - span;
    return upward ? span - position : -position;
}

Word shift(Word value, Word distance, Shift direction) {
    const auto width = value.width();
    if (distance.meta() != 0) return Word(width, value.mask(), 0);
    const auto count = distance.data();
    const bool extend = direction == Shift::ArithmeticRight;
    if (count >= width) return extend ? value.slice(width - 1, 1).resized(width, true) : Word(width, 0, 0);
    if (direction == Shift::Left) return Word(width, value.meta() << count, value.data() << count);
    return value.slice(static_cast<unsigned>(count), width - static_cast<unsigned>(count)).resized(width, extend);
}

Word add_subtract(Word left, Word right, bool subtract) {
    const auto width = common_width(left, right);
    if (left.meta() != 0 || right.meta() != 0) return Word(width, left.mask(), 0);
    const auto data = subtract ? left.data() - right.data() : left.data() + right.data();
    return Word(width, 0, data);
}

Word multiply(Word left, Word right) {
    const auto width = common_width(left, right);
    if (left.meta() != 0 || right.meta() != 0) return Word(width, left.mask(), 0);
    return Word(width, 0, left.data() * right.data());
}

Word divide(Word left, Word right, bool signed_operands, bool take_remainder) {
    const auto width = common_width(left, right);
    if (left.meta() != 0 || right.meta() != 0 || right.data() == 0) {
        return Word(width, left.mask(), 0);
    }
    const auto sign = signed_operands ? std::uint64_t{1} << (width - 1) : 0;
    const bool left_negative = (left.data() & sign) != 0;
    const bool right_negative = (right.data() & sign) != 0;
    const auto dividend = left_negative ? (-left.data() & left.mask()) : left.data();
    const auto divisor = right_negative ? (-right.data() & right.mask()) : right.data();
    const auto result = take_remainder ? dividend % divisor : dividend / divisor;
    const bool negate = take_remainder ? left_negative : left_negative != right_negative;
    return Word(width, 0, negate ? -result : result);
}

Logic less_than(Word left, Word right, bool signed_operands) {
    const auto width = common_width(left, right);
    if (left.meta() != 0 || right.meta() != 0) return Logic::X;
    const auto bias = signed_operands ? std::uint64_t{1} << (width - 1) : 0;
    return (left.data() ^ bias) < (right.data() ^ bias) ? Logic::One : Logic::Zero;
}

Logic equal(Word left, Word right) {
    common_width(left, right);
    const auto uncertain = left.meta() | right.meta();
    if (((left.data() ^ right.data()) & ~uncertain) != 0) return Logic::Zero;
    return uncertain == 0 ? Logic::One : Logic::X;
}

Logic wildcard_equal(Word left, Word right) {
    common_width(left, right);
    const auto required = right.mask() & ~right.meta();
    const auto differing = left.data() ^ right.data();
    if ((required & ~left.meta() & differing) != 0) return Logic::Zero;
    return (required & left.meta()) != 0 ? Logic::X : Logic::One;
}

bool case_match(Word left, Word right, CaseMode mode) {
    common_width(left, right);
    const auto diff = (left.meta() ^ right.meta()) | (left.data() ^ right.data());
    std::uint64_t ignored = 0;
    switch (mode) {
    case CaseMode::Exact: break;
    case CaseMode::ZWildcard:
        ignored = (left.meta() & left.data()) | (right.meta() & right.data());
        break;
    case CaseMode::XZWildcard: ignored = left.meta() | right.meta(); break;
    }
    return (diff & ~ignored) == 0;
}

Word conditional(Word condition, Word when_true, Word when_false) {
    const auto width = common_width(when_true, when_false);
    switch (truth(condition)) {
    case Logic::Zero: return when_false;
    case Logic::One: return when_true;
    default:
        const auto ones = known_one(when_true) & known_one(when_false);
        const auto zeros = known_zero(when_true) & known_zero(when_false);
        return Word(width, ~(ones | zeros), ones);
    }
}

} // namespace q3a::four_state
