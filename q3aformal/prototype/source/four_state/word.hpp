#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>

namespace q3a::four_state {

enum class Logic : std::uint8_t { Zero, One, X, Z };
enum class Shift { Left, Right, ArithmeticRight };
enum class CaseMode { Exact, ZWildcard, XZWildcard };

// A sized packed value. Meta marks X/Z, and data distinguishes each pair.
// 00 = 0, 01 = 1, 10 = X, 11 = Z (meta, data).
class Word {
public:
    Word(unsigned width, std::uint64_t meta, std::uint64_t data);

    static Word parse(std::string_view bits);
    unsigned width() const noexcept { return width_; }
    std::uint64_t meta() const noexcept { return meta_; }
    std::uint64_t data() const noexcept { return data_; }
    std::uint64_t mask() const noexcept;
    std::string bits() const;

    // The caller resolves signedness and result sizing before evaluation.
    Word resized(unsigned width, bool sign_extend) const;
    Word slice(unsigned least_bit, unsigned width) const;

private:
    unsigned width_;
    std::uint64_t meta_;
    std::uint64_t data_;
};

Word concatenate(Word high, Word low);
Word bit_not(Word value);
Word bit_and(Word left, Word right);
Word bit_or(Word left, Word right);
Word bit_xor(Word left, Word right);

// Convert an integral operand to its logical truth value.
Logic truth(Word value);
Logic logical_not(Word value);
Logic logical_and(Word left, Word right);
Logic logical_or(Word left, Word right);
Logic reduce_and(Word value);
Logic reduce_or(Word value);
Logic reduce_xor(Word value);
std::optional<std::int64_t> packed_index(Word value, bool signed_index);
std::optional<std::int64_t> offset_packed_index(std::int64_t base, int delta);
std::optional<std::int64_t> offset_packed_index(Word base, bool signed_index, int delta);
int indexed_result_delta(bool descending, bool upward, unsigned width, unsigned bit);
Word shift(Word value, Word distance, Shift direction);
Word add_subtract(Word left, Word right, bool subtract);
Word multiply(Word left, Word right);
Word divide(Word left, Word right, bool signed_operands, bool take_remainder);
Logic less_than(Word left, Word right, bool signed_operands);
Logic equal(Word left, Word right);
Logic wildcard_equal(Word left, Word right);
bool case_match(Word left, Word right, CaseMode mode = CaseMode::Exact);
Word conditional(Word condition, Word when_true, Word when_false);

} // namespace q3a::four_state
