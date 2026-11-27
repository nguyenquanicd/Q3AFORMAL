#include "encode.hpp"

#include <iostream>
#include <stdexcept>

using namespace q3a::four_state;

namespace {

Word digits(unsigned code) {
    return Word::parse({std::string{"01xz"[code / 4], "01xz"[code % 4]}});
}

void append_rails(std::vector<q3a::sat::Literal>& pinned, const EncodedWord& rails, Word value, bool invert = false) {
    for (unsigned bit = 0; bit < value.width(); ++bit) {
        const auto mark = ((value.meta() >> bit) & 1) != 0;
        const auto data = ((value.data() >> bit) & 1) != 0;
        pinned.push_back(mark != invert ? rails.at(bit).meta : -rails.at(bit).meta);
        pinned.push_back(data != invert ? rails.at(bit).data : -rails.at(bit).data);
    }
}

Word scalar(Logic logic) {
    const auto code = static_cast<unsigned>(logic);
    return Word(1, code >> 1, code & 1);
}

void check() {
    q3a::sat::Solver solver;
    Encoder encoder(solver);
    const auto condition = encoder.fresh(2);
    const auto a = encoder.fresh(2);
    const auto b = encoder.fresh(2);
    const auto out_and = encoder.bitwise(Binary::And, a, b);
    const auto out_or = encoder.bitwise(Binary::Or, a, b);
    const auto out_xor = encoder.bitwise(Binary::Xor, a, b);
    const EncodedWord out_equal{encoder.equality(a, b, false)};
    const EncodedWord out_case_equal{encoder.equality(a, b, true)};
    const auto out_mux = encoder.select(condition, a, b);
    std::size_t cases = 0;
    for (unsigned c = 0; c < 16; ++c) {
        for (unsigned x = 0; x < 16; ++x) {
            for (unsigned y = 0; y < 16; ++y) {
                const auto select = digits(c);
                const auto left = digits(x);
                const auto right = digits(y);
                std::vector<q3a::sat::Literal> input;
                append_rails(input, condition, select);
                append_rails(input, a, left);
                append_rails(input, b, right);

                // Existence first, then require at least one unexpected rail.
                // A single satisfying assignment alone could hide extra solutions.
                if (solver.solve({}, input).status != q3a::sat::Status::Satisfiable) {
                    throw std::runtime_error("legal four-state input is infeasible");
                }
                q3a::sat::Solver miter = solver;
                std::vector<q3a::sat::Literal> mismatch;
                append_rails(mismatch, out_and, bit_and(left, right), true);
                append_rails(mismatch, out_or, bit_or(left, right), true);
                append_rails(mismatch, out_xor, bit_xor(left, right), true);
                append_rails(mismatch, out_equal, scalar(equal(left, right)), true);
                append_rails(mismatch, out_case_equal, Word(1, 0, case_match(left, right)), true);
                append_rails(mismatch, out_mux, conditional(select, left, right), true);
                miter.add_clause(mismatch);
                if (miter.solve({}, input).status != q3a::sat::Status::Unsatisfiable) {
                    throw std::runtime_error("encoded output disagrees with four-state evaluation");
                }
                ++cases;
            }
        }
    }
    std::cout << "input_triples=" << cases << "\nchecked_output_vectors=" << (cases * 6) << '\n';
}

void check_arithmetic() {
    q3a::sat::Solver solver;
    Encoder encoder(solver);
    const auto left_rails = encoder.fresh(2);
    const auto right_rails = encoder.fresh(2);
    const auto sum = encoder.add_subtract(left_rails, right_rails, false);
    const auto difference = encoder.add_subtract(left_rails, right_rails, true);
    const EncodedWord unsigned_less{encoder.less_than(left_rails, right_rails, false)};
    const EncodedWord signed_less{encoder.less_than(left_rails, right_rails, true)};
    std::size_t cases = 0;
    for (unsigned a = 0; a < 16; ++a) {
        for (unsigned b = 0; b < 16; ++b) {
            const auto left = digits(a);
            const auto right = digits(b);
            const bool unknown = left.meta() != 0 || right.meta() != 0;
            const int x = static_cast<int>(left.data());
            const int y = static_cast<int>(right.data());
            const int signed_x = x >= 2 ? x - 4 : x;
            const int signed_y = y >= 2 ? y - 4 : y;
            const auto expected_sum = unknown ? Word::parse("xx") : Word(2, 0, (x + y) % 4);
            const auto expected_diff = unknown ? Word::parse("xx") : Word(2, 0, (x - y + 4) % 4);
            const auto expected_unsigned = unknown ? Logic::X : x < y ? Logic::One : Logic::Zero;
            const auto expected_signed = unknown ? Logic::X : signed_x < signed_y ? Logic::One : Logic::Zero;
            if (!case_match(add_subtract(left, right, false), expected_sum) ||
                !case_match(add_subtract(left, right, true), expected_diff) ||
                less_than(left, right, false) != expected_unsigned || less_than(left, right, true) != expected_signed) {
                throw std::runtime_error("concrete arithmetic disagrees with the direct oracle");
            }
            std::vector<q3a::sat::Literal> input;
            append_rails(input, left_rails, left);
            append_rails(input, right_rails, right);
            if (solver.solve({}, input).status != q3a::sat::Status::Satisfiable) {
                throw std::runtime_error("a legal arithmetic input is infeasible");
            }
            auto miter = solver;
            std::vector<q3a::sat::Literal> mismatch;
            append_rails(mismatch, sum, expected_sum, true);
            append_rails(mismatch, difference, expected_diff, true);
            append_rails(mismatch, unsigned_less, scalar(expected_unsigned), true);
            append_rails(mismatch, signed_less, scalar(expected_signed), true);
            miter.add_clause(mismatch);
            if (miter.solve({}, input).status != q3a::sat::Status::Unsatisfiable) {
                throw std::runtime_error("symbolic arithmetic disagrees with the direct oracle");
            }
            ++cases;
        }
    }
    std::cout << "arithmetic_pairs=" << cases << "\nchecked_arithmetic_vectors=" << (cases * 4) << '\n';
}

void check_shifts() {
    q3a::sat::Solver solver;
    Encoder encoder(solver);
    const auto data = encoder.fresh(3);
    const auto count = encoder.fresh(2);
    const std::vector directions{Shift::Left, Shift::Right, Shift::ArithmeticRight};
    std::vector<EncodedWord> result;
    for (const auto direction : directions) result.push_back(encoder.shift(data, count, direction));
    std::size_t cases = 0;
    for (unsigned value = 0; value < 64; ++value) {
        const std::string bits{"01xz"[value / 16], "01xz"[(value / 4) % 4], "01xz"[value % 4]};
        for (unsigned amount = 0; amount < 16; ++amount) {
            const std::string steps{"01xz"[amount / 4], "01xz"[amount % 4]};
            const auto input_value = Word::parse(bits);
            const auto input_distance = Word::parse(steps);
            std::vector<q3a::sat::Literal> inputs;
            append_rails(inputs, data, input_value);
            append_rails(inputs, count, input_distance);
            if (solver.solve({}, inputs).status != q3a::sat::Status::Satisfiable) {
                throw std::runtime_error("a legal shift input is infeasible");
            }
            std::vector<q3a::sat::Literal> mismatch;
            for (std::size_t index = 0; index < directions.size(); ++index) {
                const auto direction = directions[index];
                std::string expected(3, 'x');
                if (steps.find_first_of("xz") == std::string::npos) {
                    const int distance = 2 * (steps[0] - '0') + (steps[1] - '0');
                    for (int bit = 0; bit < 3; ++bit) {
                        const int original = direction == Shift::Left ? bit + distance : bit - distance;
                        expected[bit] = original >= 0 && original < 3 ? bits[original] :
                            direction == Shift::ArithmeticRight ? bits.front() : '0';
                    }
                }
                const auto oracle = Word::parse(expected);
                if (!case_match(shift(input_value, input_distance, direction), oracle)) {
                    throw std::runtime_error("concrete shift disagrees with the bit-position oracle");
                }
                append_rails(mismatch, result[index], oracle, true);
            }
            auto miter = solver;
            miter.add_clause(mismatch);
            if (miter.solve({}, inputs).status != q3a::sat::Status::Unsatisfiable) {
                throw std::runtime_error("symbolic shift disagrees with the bit-position oracle");
            }
            ++cases;
        }
    }
    std::cout << "shift_pairs=" << cases << "\nchecked_shift_vectors=" << (cases * 3) << '\n';
}

} // namespace

int main() {
    try {
        check();
        check_arithmetic();
        check_shifts();
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
