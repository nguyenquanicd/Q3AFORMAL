#include "../source/sat/sat_solver.hpp"
#include "../source/sat/tir_bit_blaster.hpp"

#include <algorithm>
#include <cstdint>
#include <functional>
#include <iostream>
#include <optional>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

using q3a::frontend::SourceLocation;
using q3a::lowering::TypedExpression;
using q3a::sat::Literal;
using q3a::sat::Solver;
using q3a::sat::Status;

std::uint64_t mask(std::uint64_t width) {
    return width >= 64 ? ~std::uint64_t{0}
        : width == 0 ? 0 : (std::uint64_t{1} << width) - 1;
}

std::vector<Literal> value_assumptions(
    const std::vector<Literal>& bits, std::uint64_t value) {
    std::vector<Literal> assumptions;
    assumptions.reserve(bits.size());
    for (std::size_t bit = 0; bit < bits.size(); ++bit) {
        assumptions.push_back(((value >> bit) & 1U) != 0
            ? bits[bit] : static_cast<Literal>(-bits[bit]));
    }
    return assumptions;
}

void check_vector_relation(
    const TypedExpression& expression,
    const std::vector<std::string>& signal_names,
    const std::vector<std::uint64_t>& signal_widths,
    const std::function<std::uint64_t(const std::vector<std::uint64_t>&)>& oracle) {
    Solver solver;
    q3a::sat::TirBitBlaster bit_blaster(solver);
    const auto output = bit_blaster.encode_bits(expression);
    std::vector<std::vector<Literal>> inputs;
    for (const auto& name : signal_names) {
        inputs.push_back(bit_blaster.signal_variables().at(name));
    }

    std::vector<std::uint64_t> values(signal_names.size(), 0);
    std::function<void(std::size_t, std::vector<Literal>&)> enumerate;
    enumerate = [&](std::size_t index, std::vector<Literal>& assumptions) {
        if (index == inputs.size()) {
            const auto expected = oracle(values) & mask(output.size());
            auto complete = assumptions;
            const auto expected_bits = value_assumptions(output, expected);
            complete.insert(complete.end(), expected_bits.begin(), expected_bits.end());
            if (solver.solve({}, complete).status != Status::Satisfiable) {
                throw std::runtime_error("expected bit-vector output was UNSAT");
            }
            for (std::size_t bit = 0; bit < output.size(); ++bit) {
                auto opposite = assumptions;
                for (std::size_t out_bit = 0; out_bit < output.size(); ++out_bit) {
                    const bool expected_value = ((expected >> out_bit) & 1U) != 0;
                    opposite.push_back(out_bit == bit
                        ? (expected_value ? static_cast<Literal>(-output[out_bit])
                                          : output[out_bit])
                        : (expected_value ? output[out_bit]
                                          : static_cast<Literal>(-output[out_bit])));
                }
                if (solver.solve({}, opposite).status != Status::Unsatisfiable) {
                    throw std::runtime_error("opposite bit-vector output was not UNSAT");
                }
            }
            return;
        }
        const auto count = std::uint64_t{1} << signal_widths[index];
        for (std::uint64_t value = 0; value < count; ++value) {
            values[index] = value;
            const auto added = value_assumptions(inputs[index], value);
            assumptions.insert(assumptions.end(), added.begin(), added.end());
            enumerate(index + 1, assumptions);
            assumptions.resize(assumptions.size() - added.size());
        }
    };
    std::vector<Literal> assumptions;
    enumerate(0, assumptions);
}

std::uint64_t extend_operand(std::uint64_t value,
                             std::uint64_t source_width,
                             std::uint64_t result_width,
                             bool sign_extend) {
    value &= mask(source_width);
    if (sign_extend && source_width < result_width &&
        ((value >> (source_width - 1)) & 1U) != 0) {
        value |= ~mask(source_width);
    }
    return value & mask(result_width);
}

TypedExpression signal(const std::string& name, std::uint64_t width,
                       bool is_signed = false) {
    return TypedExpression{"signal", name, width, is_signed,
        SourceLocation{"arithmetic_shift_vectors.sv", 1, 1, 0}, {}};
}

void check_arithmetic_widths_and_signedness() {
    const SourceLocation location{"arithmetic_shift_vectors.sv", 2, 1, 30};
    for (const bool left_signed : {false, true}) {
        for (const bool right_signed : {false, true}) {
            const TypedExpression lhs = signal("lhs", 3, left_signed);
            const TypedExpression rhs = signal("rhs", 2, right_signed);
            const bool signed_operation = left_signed && right_signed;
            for (const auto* op : {"+", "-"}) {
                const TypedExpression expression{"binary", op, 3, signed_operation,
                    location, {lhs, rhs}};
                check_vector_relation(expression, {"lhs", "rhs"}, {3, 2},
                    [=](const std::vector<std::uint64_t>& values) {
                        const auto left = extend_operand(values[0], 3, 3,
                                                         signed_operation);
                        const auto right = extend_operand(values[1], 2, 3,
                                                          signed_operation);
                        return op[0] == '+' ? left + right : left - right;
                    });
            }
        }
    }
}

void check_unary_minus() {
    const SourceLocation location{"arithmetic_shift_vectors.sv", 3, 1, 45};
    const TypedExpression operand = signal("value", 4, true);
    const TypedExpression expression{"unary", "-", 4, true, location, {operand}};
    check_vector_relation(expression, {"value"}, {4},
        [](const std::vector<std::uint64_t>& values) {
            return std::uint64_t{0} - values[0];
        });
}

void check_constant_shifts() {
    const SourceLocation location{"arithmetic_shift_vectors.sv", 4, 1, 60};
    const TypedExpression lhs = signal("value", 4);
    for (const auto* op : {"<<", ">>"}) {
        for (std::uint64_t amount = 0; amount <= 7; ++amount) {
            const TypedExpression rhs{"literal", "3'd" + std::to_string(amount),
                3, false, location, {}};
            const TypedExpression expression{"binary", op, 4, false,
                location, {lhs, rhs}};
            check_vector_relation(expression, {"value"}, {4},
                [=](const std::vector<std::uint64_t>& values) {
                    if (amount >= 4) return std::uint64_t{0};
                    return op[0] == '<' ? (values[0] << amount)
                                        : (values[0] >> amount);
                });
        }
    }
}

void check_arithmetic_right_shifts() {
    const SourceLocation location{"arithmetic_shift_vectors.sv", 5, 1, 75};
    for (const bool operand_signed : {false, true}) {
        const TypedExpression lhs = signal("value", 4, operand_signed);
        for (const auto* op : {">>", ">>>"}) {
            for (std::uint64_t amount = 0; amount <= 7; ++amount) {
                const TypedExpression rhs{"literal", "3'd" + std::to_string(amount),
                    3, false, location, {}};
                const TypedExpression expression{"binary", op, 4,
                    operand_signed, location, {lhs, rhs}};
                check_vector_relation(expression, {"value"}, {4},
                    [=](const std::vector<std::uint64_t>& values) -> std::uint64_t {
                        const auto value = values[0] & 15U;
                        const bool sign_fill = std::string(op) == ">>>" &&
                            operand_signed && ((value >> 3U) & 1U) != 0;
                        if (amount >= 4) return sign_fill ? 15U : 0U;
                        auto result = value >> amount;
                        if (sign_fill && amount != 0) {
                            result |= 15U & ~mask(4U - amount);
                        }
                        return result;
                    });
            }
        }
    }
}

void check_shift_width_boundaries() {
    const SourceLocation location{"shift_width_boundaries.sv", 1, 1, 0};
    for (const auto width : {1U, 4U, 8U, 16U, 32U, 64U}) {
        std::vector<std::uint64_t> amounts{
            0, 1, width / 2, width - 1, width, width + 1};
        std::sort(amounts.begin(), amounts.end());
        amounts.erase(std::unique(amounts.begin(), amounts.end()), amounts.end());

        for (const bool is_signed : {false, true}) {
            const auto lhs = signal("value", width, is_signed);
            for (const auto* op : {"<<", ">>", ">>>"}) {
                for (const auto amount : amounts) {
                    Solver solver;
                    q3a::sat::TirBitBlaster bit_blaster(solver);
                    const TypedExpression rhs{"literal",
                        "32'd" + std::to_string(amount), 32, true, location, {}};
                    const TypedExpression expression{"binary", op, width,
                        is_signed, location, {lhs, rhs}};
                    const auto output = bit_blaster.encode_bits(expression);
                    const auto& input = bit_blaster.signal_variables().at("value");

                    for (std::uint64_t bit = 0; bit < width; ++bit) {
                        std::optional<Literal> reference;
                        if (std::string(op) == "<<") {
                            if (amount < width && bit >= amount) {
                                reference = input[bit - amount];
                            }
                        } else if (std::string(op) == ">>") {
                            if (amount < width && bit + amount < width) {
                                reference = input[bit + amount];
                            }
                        } else if (amount < width && bit + amount < width) {
                            reference = input[bit + amount];
                        } else if (is_signed) {
                            reference = input.back();
                        }

                        const auto output_bit = output[bit];
                        if (reference) {
                            const std::vector<Literal> ref_zero_mismatch{
                                static_cast<Literal>(-*reference), output_bit};
                            if (solver.solve({}, ref_zero_mismatch).status !=
                                Status::Unsatisfiable) {
                                throw std::runtime_error(
                                    "shift output differs from reference for ref=0, op=" +
                                    std::string(op) + ", width=" +
                                    std::to_string(width) + ", amount=" +
                                    std::to_string(amount));
                            }
                            const std::vector<Literal> ref_one_mismatch{
                                *reference, static_cast<Literal>(-output_bit)};
                            if (solver.solve({}, ref_one_mismatch).status !=
                                Status::Unsatisfiable) {
                                throw std::runtime_error(
                                    "shift output differs from reference for ref=1, op=" +
                                    std::string(op) + ", width=" +
                                    std::to_string(width) + ", amount=" +
                                    std::to_string(amount));
                            }
                        } else if (solver.solve({}, {output_bit}).status !=
                                   Status::Unsatisfiable) {
                            throw std::runtime_error(
                                "zero-fill shift boundary produced a one bit, op=" +
                                std::string(op) + ", width=" +
                                std::to_string(width) + ", amount=" +
                                std::to_string(amount));
                        }
                    }
                }
            }
        }
    }
}

void check_static_selects() {
    const SourceLocation location{"arithmetic_shift_vectors.sv", 6, 1, 90};
    const auto source = signal("source", 8);
    for (const std::uint64_t offset : {0U, 3U, 7U}) {
        const TypedExpression source_offset{"constant", std::to_string(offset),
            32, false, location, {}};
        const TypedExpression bit_select{"select", "bit", 1, false,
            location, {source, source_offset}};
        check_vector_relation(bit_select, {"source"}, {8},
            [=](const std::vector<std::uint64_t>& values) {
                return (values[0] >> offset) & 1U;
            });
    }
    for (const std::uint64_t offset : {0U, 4U}) {
        const TypedExpression source_offset{"constant", std::to_string(offset),
            32, false, location, {}};
        const TypedExpression part_select{"select", "part", 4, false,
            location, {source, source_offset}};
        check_vector_relation(part_select, {"source"}, {8},
            [=](const std::vector<std::uint64_t>& values) {
                return (values[0] >> offset) & 15U;
            });
    }
}

void check_conditional_branch_extension() {
    const SourceLocation location{"arithmetic_shift_vectors.sv", 7, 1, 105};
    for (const bool true_signed : {false, true}) {
        for (const bool false_signed : {false, true}) {
            const bool sign_extend = true_signed && false_signed;
            const auto condition = signal("condition", 1);
            const auto when_true = signal("when_true", 3, true_signed);
            const auto when_false = signal("when_false", 2, false_signed);
            const TypedExpression expression{"conditional", "?:", 3,
                sign_extend, location, {condition, when_true, when_false}};
            check_vector_relation(expression,
                {"condition", "when_true", "when_false"}, {1, 3, 2},
                [=](const std::vector<std::uint64_t>& values) {
                    const auto true_value = extend_operand(values[1], 3, 3,
                                                           sign_extend);
                    const auto false_value = extend_operand(values[2], 2, 3,
                                                            sign_extend);
                    return values[0] != 0 ? true_value : false_value;
                });
        }
    }
}

void check_rejected_dynamic_and_negative_shifts() {
    const SourceLocation location{"arithmetic_shift_vectors.sv", 5, 1, 75};
    const auto lhs = signal("lhs", 4);
    const auto dynamic = signal("amount", 3);
    for (const auto& rhs : {dynamic, TypedExpression{"unary", "-", 4, true,
             location, {TypedExpression{"literal", "4'sd1", 4, true,
                 location, {}}}}}) {
        const TypedExpression expression{"binary", "<<", 4, false,
            location, {lhs, rhs}};
        Solver solver;
        q3a::sat::TirBitBlaster bit_blaster(solver);
        try {
            (void)bit_blaster.encode_bits(expression);
        } catch (const q3a::sat::BitBlastError&) {
            continue;
        }
        throw std::runtime_error("unsupported shift amount was not rejected");
    }
}

} // namespace

int main() {
    try {
        check_arithmetic_widths_and_signedness();
        check_unary_minus();
        check_constant_shifts();
        check_arithmetic_right_shifts();
        check_shift_width_boundaries();
        check_static_selects();
        check_conditional_branch_extension();
        check_rejected_dynamic_and_negative_shifts();
        std::cout << "PASS: exhaustive arithmetic, constant-shift, and normalized-select bit-blasting matches independent vector oracles.\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
}
