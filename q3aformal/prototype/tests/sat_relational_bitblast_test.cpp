#include "../source/sat/sat_solver.hpp"
#include "../source/sat/tir_bit_blaster.hpp"

#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

using q3a::frontend::SourceLocation;
using q3a::lowering::TypedExpression;
using q3a::sat::Literal;

int decode_value(std::uint32_t value, bool is_signed) {
    if (is_signed && (value & 2U) != 0) return static_cast<int>(value) - 4;
    return static_cast<int>(value);
}

bool evaluate(const std::string& op, int left, int right) {
    if (op == "<") return left < right;
    if (op == "<=") return left <= right;
    if (op == ">") return left > right;
    if (op == ">=") return left >= right;
    throw std::logic_error("unexpected comparison operator");
}

void check_operator(const std::string& op, bool left_signed, bool right_signed) {
    const SourceLocation location{"sat_relational_vectors.sv", 1, 1, 0};
    const TypedExpression left{"signal", "lhs", 2, left_signed, location, {}};
    const TypedExpression right{"signal", "rhs", 2, right_signed, location, {}};
    const TypedExpression predicate{"binary", op, 1, false, location, {left, right}};

    q3a::sat::Solver solver;
    q3a::sat::TirBitBlaster bit_blaster(solver);
    const auto output = bit_blaster.encode_predicate(predicate);
    const auto lhs_bits = bit_blaster.signal_variables().at("lhs");
    const auto rhs_bits = bit_blaster.signal_variables().at("rhs");
    const bool signed_comparison = left_signed && right_signed;

    for (std::uint32_t lhs = 0; lhs < 4; ++lhs) {
        for (std::uint32_t rhs = 0; rhs < 4; ++rhs) {
            std::vector<Literal> inputs;
            for (std::size_t bit = 0; bit < lhs_bits.size(); ++bit) {
                inputs.push_back((lhs & (1U << bit)) != 0
                    ? lhs_bits[bit] : static_cast<Literal>(-lhs_bits[bit]));
                inputs.push_back((rhs & (1U << bit)) != 0
                    ? rhs_bits[bit] : static_cast<Literal>(-rhs_bits[bit]));
            }
            const auto left_value = decode_value(lhs, signed_comparison);
            const auto right_value = decode_value(rhs, signed_comparison);
            const bool expected = evaluate(op, left_value, right_value);

            auto satisfying_inputs = inputs;
            satisfying_inputs.push_back(expected ? output : static_cast<Literal>(-output));
            if (solver.solve({}, satisfying_inputs).status !=
                q3a::sat::Status::Satisfiable) {
                throw std::runtime_error("expected result was not satisfiable: op=" + op +
                    " lhs=" + std::to_string(lhs) + " rhs=" + std::to_string(rhs) +
                    " signed=" + std::to_string(signed_comparison));
            }

            auto violating_inputs = inputs;
            violating_inputs.push_back(expected ? static_cast<Literal>(-output) : output);
            if (solver.solve({}, violating_inputs).status !=
                q3a::sat::Status::Unsatisfiable) {
                throw std::runtime_error("opposite result remained satisfiable: op=" + op +
                    " lhs=" + std::to_string(lhs) + " rhs=" + std::to_string(rhs) +
                    " signed=" + std::to_string(signed_comparison));
            }
        }
    }
}

void check_mixed_width_extension() {
    const SourceLocation location{"sat_relational_vectors.sv", 2, 1, 24};
    for (const bool left_signed : {false, true}) {
        for (const bool right_signed : {false, true}) {
            const bool signed_operation = left_signed && right_signed;
            for (const auto* op : {"<", "<=", ">", ">=", "==", "!=",
                                   "&", "|", "^", "~^", "^~"}) {
                const TypedExpression left{"signal", "lhs", 3, left_signed,
                                           location, {}};
                const TypedExpression right{"signal", "rhs", 2, right_signed,
                                            location, {}};
                const bool predicate_op = std::string(op) == "<" ||
                    std::string(op) == "<=" || std::string(op) == ">" ||
                    std::string(op) == ">=" || std::string(op) == "==" ||
                    std::string(op) == "!=";
                const TypedExpression expression{"binary", op,
                    predicate_op ? 1U : 3U, false, location, {left, right}};
                q3a::sat::Solver solver;
                q3a::sat::TirBitBlaster bit_blaster(solver);
                const auto output = bit_blaster.encode_bits(expression);
                const auto lhs_bits = bit_blaster.signal_variables().at("lhs");
                const auto rhs_bits = bit_blaster.signal_variables().at("rhs");

                for (std::uint32_t lhs = 0; lhs < 8; ++lhs) {
                    for (std::uint32_t rhs = 0; rhs < 4; ++rhs) {
                        std::vector<Literal> inputs;
                        for (std::size_t bit = 0; bit < lhs_bits.size(); ++bit) {
                            inputs.push_back((lhs & (1U << bit)) != 0
                                ? lhs_bits[bit] : static_cast<Literal>(-lhs_bits[bit]));
                        }
                        for (std::size_t bit = 0; bit < rhs_bits.size(); ++bit) {
                            inputs.push_back((rhs & (1U << bit)) != 0
                                ? rhs_bits[bit] : static_cast<Literal>(-rhs_bits[bit]));
                        }
                        auto extended_left = lhs;
                        auto extended_right = rhs;
                        if (signed_operation && (rhs & 2U) != 0) {
                            extended_right |= 4U;
                        }
                        const auto signed_left = (extended_left & 4U) != 0
                            ? static_cast<int>(extended_left) - 8
                            : static_cast<int>(extended_left);
                        const auto signed_right = (extended_right & 4U) != 0
                            ? static_cast<int>(extended_right) - 8
                            : static_cast<int>(extended_right);
                        bool expected_predicate = false;
                        std::uint32_t expected_vector = 0;
                        if (std::string(op) == "<") expected_predicate = signed_operation
                            ? signed_left < signed_right : extended_left < extended_right;
                        else if (std::string(op) == "<=") expected_predicate = signed_operation
                            ? signed_left <= signed_right : extended_left <= extended_right;
                        else if (std::string(op) == ">") expected_predicate = signed_operation
                            ? signed_left > signed_right : extended_left > extended_right;
                        else if (std::string(op) == ">=") expected_predicate = signed_operation
                            ? signed_left >= signed_right : extended_left >= extended_right;
                        else if (std::string(op) == "==") expected_predicate = extended_left == extended_right;
                        else if (std::string(op) == "!=") expected_predicate = extended_left != extended_right;
                        else if (std::string(op) == "&") expected_vector = extended_left & extended_right;
                        else if (std::string(op) == "|") expected_vector = extended_left | extended_right;
                        else if (std::string(op) == "^") expected_vector = extended_left ^ extended_right;
                        else expected_vector = (~(extended_left ^ extended_right)) & 7U;
                        const auto expected = predicate_op
                            ? static_cast<std::uint64_t>(expected_predicate)
                            : static_cast<std::uint64_t>(expected_vector);
                        for (std::size_t bit = 0; bit < output.size(); ++bit) {
                            auto correct = inputs;
                            const bool expected_bit = ((expected >> bit) & 1U) != 0;
                            correct.push_back(expected_bit ? output[bit]
                                : static_cast<Literal>(-output[bit]));
                            if (solver.solve({}, correct).status !=
                                q3a::sat::Status::Satisfiable) {
                                throw std::runtime_error("expected extended-width output was UNSAT");
                            }
                            auto opposite = inputs;
                            opposite.push_back(expected_bit
                                ? static_cast<Literal>(-output[bit]) : output[bit]);
                            if (solver.solve({}, opposite).status !=
                                q3a::sat::Status::Unsatisfiable) {
                                throw std::runtime_error("opposite extended-width output remained SAT");
                            }
                        }
                    }
                }
            }
        }
    }
}

} // namespace

int main() {
    try {
        for (const auto* op : {"<", "<=", ">", ">="}) {
            for (const bool left_signed : {false, true}) {
                for (const bool right_signed : {false, true}) {
                    check_operator(op, left_signed, right_signed);
                }
            }
        }
        check_mixed_width_extension();
        std::cout << "PASS: relational/equality/bitwise bit-blasting matches exhaustive signedness and mixed-width extension vectors.\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
}
