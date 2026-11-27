#include "encode.hpp"

#include <map>
#include <stdexcept>

namespace q3a::four_state {
namespace {

using sat::Literal;

void require_width(std::size_t width) {
    if (width == 0 || width > 64) throw std::invalid_argument("encoded four-state width must be 1..64");
}

void require_equal(const EncodedWord& a, const EncodedWord& b) {
    require_width(a.size());
    if (a.size() != b.size()) throw std::invalid_argument("encoded four-state widths differ");
}

} // namespace

Encoder::Encoder(sat::Solver& solver) : solver_(solver), true_(variable()) {
    solver_.add_clause({true_});
}

Literal Encoder::variable() { return static_cast<Literal>(solver_.new_variable()); }

Literal Encoder::conjunction(Literal a, Literal b) {
    if (a == b || b == true_) return a;
    if (a == true_) return b;
    if (a == -b || a == -true_ || b == -true_) return -true_;
    const auto value = variable();
    solver_.add_clause({-value, a});
    solver_.add_clause({-value, b});
    solver_.add_clause({value, -a, -b});
    return value;
}

Literal Encoder::disjunction(Literal a, Literal b) { return -conjunction(-a, -b); }

Literal Encoder::exclusive_or(Literal a, Literal b) {
    return disjunction(conjunction(a, -b), conjunction(-a, b));
}

Literal Encoder::choose(Literal control, Literal on, Literal off) {
    if (on == off) return on;
    return disjunction(conjunction(control, on), conjunction(-control, off));
}

Literal Encoder::known_one(EncodedBit bit) { return conjunction(-bit.meta, bit.data); }
Literal Encoder::known_zero(EncodedBit bit) { return conjunction(-bit.meta, -bit.data); }

EncodedWord Encoder::fresh(unsigned width) {
    require_width(width);
    EncodedWord result;
    result.reserve(width);
    for (unsigned index = 0; index < width; ++index) result.push_back({variable(), variable()});
    return result;
}

EncodedWord Encoder::constant(Word value) {
    EncodedWord result;
    result.reserve(value.width());
    for (unsigned bit = 0; bit < value.width(); ++bit) {
        const auto one = std::uint64_t{1} << bit;
        result.push_back({(value.meta() & one) ? true_ : -true_,
                          (value.data() & one) ? true_ : -true_});
    }
    return result;
}

EncodedWord Encoder::bit_not(const EncodedWord& value) {
    require_width(value.size());
    EncodedWord result;
    result.reserve(value.size());
    for (const auto bit : value) result.push_back({bit.meta, known_zero(bit)});
    return result;
}

EncodedBit Encoder::truth(const EncodedWord& value) {
    require_width(value.size());
    auto any_one = -true_;
    auto any_unknown = -true_;
    for (const auto bit : value) {
        any_one = disjunction(any_one, known_one(bit));
        any_unknown = disjunction(any_unknown, bit.meta);
    }
    return {conjunction(-any_one, any_unknown), any_one};
}

EncodedBit Encoder::procedural_true(const EncodedWord& value) {
    return {-true_, truth(value).data};
}

EncodedBit Encoder::logical_not(const EncodedWord& value) {
    const auto predicate = truth(value);
    return {predicate.meta, known_zero(predicate)};
}

EncodedBit Encoder::reduce(Binary operation, const EncodedWord& value) {
    require_width(value.size());
    if (operation == Binary::Or) return truth(value);
    if (operation == Binary::And) {
        auto all_one = true_;
        auto any_zero = -true_;
        for (const auto bit : value) {
            all_one = conjunction(all_one, known_one(bit));
            any_zero = disjunction(any_zero, known_zero(bit));
        }
        return {-disjunction(all_one, any_zero), all_one};
    }
    auto meta = -true_;
    auto parity = -true_;
    for (const auto bit : value) {
        meta = disjunction(meta, bit.meta);
        parity = exclusive_or(parity, bit.data);
    }
    return {meta, conjunction(-meta, parity)};
}

EncodedBit Encoder::logical_binary(Binary operation, const EncodedWord& left, const EncodedWord& right) {
    return bitwise(operation, {truth(left)}, {truth(right)}).front();
}

EncodedWord Encoder::bitwise(Binary operation, const EncodedWord& left, const EncodedWord& right) {
    require_equal(left, right);
    EncodedWord result;
    result.reserve(left.size());
    for (std::size_t index = 0; index < left.size(); ++index) {
        const auto a = left[index];
        const auto b = right[index];
        if (operation == Binary::Xor) {
            const auto meta = disjunction(a.meta, b.meta);
            result.push_back({meta, conjunction(-meta, exclusive_or(a.data, b.data))});
            continue;
        }
        const bool and_op = operation == Binary::And;
        const auto a_one = known_one(a);
        const auto b_one = known_one(b);
        const auto a_zero = known_zero(a);
        const auto b_zero = known_zero(b);
        const auto one = and_op ? conjunction(a_one, b_one) : disjunction(a_one, b_one);
        const auto zero = and_op ? disjunction(a_zero, b_zero) : conjunction(a_zero, b_zero);
        result.push_back({-disjunction(one, zero), one});
    }
    return result;
}

EncodedWord Encoder::indexed_read(const EncodedWord& value, const EncodedWord& index,
                                  bool signed_index, std::int64_t left, std::int64_t right,
                                  unsigned width, bool upward) {
    require_width(value.size());
    require_width(index.size());
    require_width(width);
    const bool descending = left >= right;
    const auto l = static_cast<std::uint64_t>(left);
    const auto r = static_cast<std::uint64_t>(right);
    if ((descending ? l - r : r - l) != value.size() - 1) {
        throw std::invalid_argument("invalid packed bit-select bounds");
    }
    auto unknown = -true_;
    for (const auto bit : index) unknown = disjunction(unknown, bit.meta);

    std::map<std::uint64_t, Literal> decoded_bases;
    const auto decoder = [&](std::uint64_t raw_base) {
        auto [entry, inserted] = decoded_bases.emplace(raw_base, true_);
        if (inserted) {
            for (std::size_t bit = 0; bit < index.size(); ++bit) {
                const bool one = ((raw_base >> bit) & 1U) != 0;
                entry->second = conjunction(entry->second, one ? index[bit].data : -index[bit].data);
            }
        }
        return entry->second;
    };

    EncodedWord result;
    result.reserve(width);
    for (unsigned bit = 0; bit < width; ++bit) {
        const int delta = indexed_result_delta(descending, upward, width, bit);
        auto valid = -true_;
        auto selected_meta = -true_;
        auto selected_data = -true_;
        for (std::size_t offset = 0; offset < value.size(); ++offset) {
            const auto position = static_cast<std::int64_t>(offset);
            const auto bound = descending ? right + position : right - position;
            const auto base = offset_packed_index(bound, -delta);
            const auto raw = static_cast<std::uint64_t>(bound) - static_cast<std::uint64_t>(delta);
            const auto candidate = Word(static_cast<unsigned>(index.size()), 0, raw);
            if (signed_index ? !base || packed_index(candidate, true) != base :
                    ((!base && delta >= 0) || (base && *base < 0) || candidate.data() != raw)) {
                continue;
            }
            const auto matches = decoder(raw & candidate.mask());
            valid = disjunction(valid, matches);
            selected_meta = disjunction(selected_meta, conjunction(matches, value[offset].meta));
            selected_data = disjunction(selected_data, conjunction(matches, value[offset].data));
        }
        result.push_back({disjunction(unknown, disjunction(-valid, selected_meta)), conjunction(-unknown, selected_data)});
    }
    return result;
}

EncodedWord Encoder::shift(const EncodedWord& value, const EncodedWord& distance, Shift direction) {
    require_width(value.size());
    require_width(distance.size());
    const EncodedBit fill = direction == Shift::ArithmeticRight ? value.back() : EncodedBit{-true_, -true_};

    auto result = value;
    auto unknown = -true_;
    for (const auto bit : distance) unknown = disjunction(unknown, bit.meta);
    auto overshift = -true_;
    for (std::size_t stage = 0; stage < distance.size(); ++stage) {
        const auto step = std::uint64_t{1} << stage;
        const auto enabled = distance[stage].data;
        if (step >= value.size()) {
            overshift = disjunction(overshift, enabled);
            continue;
        }
        if (enabled == -true_) continue;
        auto next = result;
        for (std::size_t bit = 0; bit < result.size(); ++bit) {
            auto moved = fill;
            if (direction == Shift::Left) {
                if (bit >= step) moved = result[bit - step];
            } else if (bit + step < result.size()) {
                moved = result[bit + step];
            }
            next[bit] = {choose(enabled, moved.meta, result[bit].meta),
                         choose(enabled, moved.data, result[bit].data)};
        }
        result = std::move(next);
    }
    for (auto& bit : result) {
        bit = {disjunction(unknown, choose(overshift, fill.meta, bit.meta)),
               conjunction(-unknown, choose(overshift, fill.data, bit.data))};
    }
    return result;
}

EncodedWord Encoder::add_subtract(const EncodedWord& left, const EncodedWord& right, bool subtract) {
    require_equal(left, right);
    auto meta = -true_;
    for (std::size_t bit = 0; bit < left.size(); ++bit) {
        meta = disjunction(meta, disjunction(left[bit].meta, right[bit].meta));
    }

    EncodedWord result;
    result.reserve(left.size());
    auto carry = subtract ? true_ : -true_;
    for (std::size_t bit = 0; bit < left.size(); ++bit) {
        const auto a = left[bit].data;
        const auto b = subtract ? -right[bit].data : right[bit].data;
        const auto parity = exclusive_or(a, b);
        result.push_back({meta, conjunction(-meta, exclusive_or(parity, carry))});
        if (bit + 1 < left.size()) {
            carry = disjunction(conjunction(a, b), conjunction(parity, carry));
        }
    }
    return result;
}

EncodedWord Encoder::multiply(const EncodedWord& left, const EncodedWord& right) {
    require_equal(left, right);
    auto unknown = -true_;
    for (std::size_t bit = 0; bit < left.size(); ++bit) {
        unknown = disjunction(unknown, disjunction(left[bit].meta, right[bit].meta));
    }

    // Accumulate only columns kept at the context width. The operands already
    // have the correct sign extension, so the low product bits use one circuit.
    std::vector<Literal> product(left.size(), -true_);
    for (std::size_t shift = 0; shift < right.size(); ++shift) {
        if (right[shift].data == -true_) continue;
        auto carry = -true_;
        for (auto bit = shift; bit < product.size(); ++bit) {
            const auto partial = conjunction(left[bit - shift].data, right[shift].data);
            const auto sum = product[bit];
            const auto parity = exclusive_or(sum, partial);
            product[bit] = exclusive_or(parity, carry);
            if (bit + 1 < product.size()) {
                carry = disjunction(conjunction(sum, partial), conjunction(parity, carry));
            }
        }
    }

    EncodedWord result;
    result.reserve(product.size());
    for (const auto bit : product) result.push_back({unknown, conjunction(-unknown, bit)});
    return result;
}

EncodedWord Encoder::divide(const EncodedWord& left, const EncodedWord& right, bool signed_operands,
                            bool take_remainder) {
    require_equal(left, right);
    auto uncertain = -true_;
    auto divisor_nonzero = -true_;
    const EncodedBit zero{-true_, -true_};
    EncodedWord dividend(left.size(), zero), divisor(left.size(), zero);
    for (std::size_t bit = 0; bit < left.size(); ++bit) {
        uncertain = disjunction(uncertain, disjunction(left[bit].meta, right[bit].meta));
        divisor_nonzero = disjunction(divisor_nonzero, right[bit].data);
        dividend[bit].data = left[bit].data;
        divisor[bit].data = right[bit].data;
    }
    const auto invalid = disjunction(uncertain, -divisor_nonzero);
    if (invalid == true_) return EncodedWord(left.size(), {true_, -true_});

    const auto left_sign = signed_operands ? dividend.back().data : -true_;
    const auto right_sign = signed_operands ? divisor.back().data : -true_;
    const EncodedWord zeros(left.size(), zero);
    const auto negate_if = [&](EncodedWord& word, Literal sign) {
        if (sign == -true_) return;
        const auto negated = add_subtract(zeros, word, true);
        for (std::size_t bit = 0; bit < word.size(); ++bit) {
            word[bit].data = choose(sign, negated[bit].data, word[bit].data);
        }
    };
    negate_if(dividend, left_sign);
    negate_if(divisor, right_sign);

    // Restoring unsigned division processes successive prefixes of the
    // dividend; the shifted remainder cannot exceed the current prefix.
    EncodedWord quotient = zeros;
    EncodedWord remainder = zeros;
    for (std::size_t bit = dividend.size(); bit-- > 0;) {
        for (auto index = remainder.size() - 1; index > 0; --index) {
            remainder[index] = remainder[index - 1];
        }
        remainder.front() = dividend[bit];
        const auto subtract = -less_than(remainder, divisor, false).data;
        quotient[bit].data = subtract;
        const auto reduced = add_subtract(remainder, divisor, true);
        for (std::size_t index = 0; index < remainder.size(); ++index) {
            remainder[index].data = choose(subtract, reduced[index].data, remainder[index].data);
        }
    }
    auto result = take_remainder ? std::move(remainder) : std::move(quotient);
    negate_if(result, take_remainder ? left_sign : exclusive_or(left_sign, right_sign));
    for (auto& bit : result) bit = {invalid, conjunction(-invalid, bit.data)};
    return result;
}

EncodedBit Encoder::less_than(const EncodedWord& left, const EncodedWord& right, bool signed_operands) {
    require_equal(left, right);
    auto meta = -true_;
    auto less = -true_;
    for (std::size_t bit = 0; bit < left.size(); ++bit) {
        const bool signed_bit = signed_operands && bit + 1 == left.size();
        const auto a = signed_bit ? -left[bit].data : left[bit].data;
        const auto b = signed_bit ? -right[bit].data : right[bit].data;
        meta = disjunction(meta, disjunction(left[bit].meta, right[bit].meta));
        less = disjunction(conjunction(-a, b), conjunction(-exclusive_or(a, b), less));
    }
    return {meta, conjunction(-meta, less)};
}

EncodedBit Encoder::wildcard_case(const EncodedWord& left, const EncodedWord& right, bool ignore_x) {
    require_equal(left, right);
    auto matches = true_;
    for (std::size_t bit = 0; bit < left.size(); ++bit) {
        const auto a = left[bit];
        const auto b = right[bit];
        const auto wildcard = ignore_x ? disjunction(a.meta, b.meta)
            : disjunction(conjunction(a.meta, a.data), conjunction(b.meta, b.data));
        const auto differs = ignore_x ? exclusive_or(a.data, b.data)
            : disjunction(exclusive_or(a.meta, b.meta), exclusive_or(a.data, b.data));
        matches = conjunction(matches, disjunction(wildcard, -differs));
    }
    return {-true_, matches};
}

EncodedBit Encoder::equality(const EncodedWord& left, const EncodedWord& right, bool exact) {
    require_equal(left, right);
    auto mismatch = -true_;
    auto unknown = -true_;
    for (std::size_t index = 0; index < left.size(); ++index) {
        const auto a = left[index];
        const auto b = right[index];
        const auto different_data = exclusive_or(a.data, b.data);
        if (exact) {
            const auto different_rails = disjunction(different_data, exclusive_or(a.meta, b.meta));
            mismatch = disjunction(mismatch, different_rails);
        } else {
            const auto either_unknown = disjunction(a.meta, b.meta);
            unknown = disjunction(unknown, either_unknown);
            mismatch = disjunction(mismatch, conjunction(different_data, -either_unknown));
        }
    }
    return {conjunction(-mismatch, unknown), conjunction(-mismatch, -unknown)};
}

EncodedBit Encoder::wildcard_equality(const EncodedWord& left, const EncodedWord& right) {
    require_equal(left, right);
    auto failed = -true_;
    auto unresolved = -true_;
    for (std::size_t i = 0; i < left.size(); ++i) {
        const auto required = -right[i].meta;
        unresolved = disjunction(unresolved, conjunction(required, left[i].meta));
        const auto known = conjunction(required, -left[i].meta);
        failed = disjunction(failed,
            conjunction(known, exclusive_or(left[i].data, right[i].data)));
    }
    return {conjunction(-failed, unresolved), conjunction(-failed, -unresolved)};
}

EncodedWord Encoder::select(const EncodedWord& condition,
                            const EncodedWord& when_true, const EncodedWord& when_false) {
    require_width(condition.size());
    require_equal(when_true, when_false);
    auto take_true = -true_;
    auto take_false = true_;
    for (const auto bit : condition) {
        take_true = disjunction(take_true, known_one(bit));
        take_false = conjunction(take_false, known_zero(bit));
    }
    const auto ambiguous = conjunction(-take_true, -take_false);
    EncodedWord result;
    result.reserve(when_true.size());
    for (std::size_t index = 0; index < when_true.size(); ++index) {
        const auto a = when_true[index];
        const auto b = when_false[index];
        const auto one = conjunction(known_one(a), known_one(b));
        const auto zero = conjunction(known_zero(a), known_zero(b));
        const auto combine = [&](Literal a_rail, Literal b_rail, Literal merged) {
            return disjunction(disjunction(conjunction(take_true, a_rail),
                conjunction(take_false, b_rail)), conjunction(ambiguous, merged));
        };
        result.push_back({combine(a.meta, b.meta, -disjunction(one, zero)),
                          combine(a.data, b.data, one)});
    }
    return result;
}

} // namespace q3a::four_state
