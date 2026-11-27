#pragma once

#include "word.hpp"
#include "../sat/sat_solver.hpp"

namespace q3a::four_state {

struct EncodedBit {
    sat::Literal meta;
    sat::Literal data;
};
using EncodedWord = std::vector<EncodedBit>; // Least significant bit first.

enum class Binary { And, Or, Xor };

// Combinational encoding for already sized operands. All four rail pairs are
// valid. Each returned pair is fully constrained by its operands.
class Encoder {
public:
    explicit Encoder(sat::Solver& solver);
    EncodedWord fresh(unsigned width);
    EncodedWord constant(Word value);
    EncodedWord bit_not(const EncodedWord& value);
    sat::Literal conjunction(sat::Literal a, sat::Literal b);
    sat::Literal disjunction(sat::Literal a, sat::Literal b);
    EncodedBit procedural_true(const EncodedWord& value);
    EncodedBit logical_not(const EncodedWord& value);
    EncodedBit reduce(Binary operation, const EncodedWord& value);
    EncodedBit logical_binary(Binary operation, const EncodedWord& left, const EncodedWord& right);
    EncodedWord bitwise(Binary operation, const EncodedWord& left, const EncodedWord& right);
    EncodedWord indexed_read(const EncodedWord& value, const EncodedWord& index, bool signed_index,
                             std::int64_t left, std::int64_t right, unsigned width, bool upward);
    EncodedWord shift(const EncodedWord& value, const EncodedWord& distance, Shift direction);
    EncodedWord add_subtract(const EncodedWord& left, const EncodedWord& right, bool subtract);
    EncodedWord multiply(const EncodedWord& left, const EncodedWord& right);
    EncodedWord divide(const EncodedWord& left, const EncodedWord& right, bool signed_operands,
                       bool take_remainder);
    EncodedBit less_than(const EncodedWord& left, const EncodedWord& right, bool signed_operands);
    EncodedBit wildcard_case(const EncodedWord& left, const EncodedWord& right, bool ignore_x);
    EncodedBit equality(const EncodedWord& left, const EncodedWord& right, bool exact);
    EncodedBit wildcard_equality(const EncodedWord& left, const EncodedWord& right);
    EncodedWord select(const EncodedWord& condition,
                       const EncodedWord& when_true, const EncodedWord& when_false);

private:
    sat::Literal variable();

    sat::Literal exclusive_or(sat::Literal a, sat::Literal b);
    sat::Literal choose(sat::Literal control, sat::Literal on, sat::Literal off);
    sat::Literal known_one(EncodedBit bit);
    sat::Literal known_zero(EncodedBit bit);
    EncodedBit truth(const EncodedWord& word);

    sat::Solver& solver_;
    sat::Literal true_;
};

} // namespace q3a::four_state
