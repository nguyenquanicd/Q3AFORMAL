#pragma once

#include "sat_solver.hpp"
#include "../lowering/lowering.hpp"

#include <map>
#include <stdexcept>
#include <string>
#include <vector>

namespace q3a::sat {

class BitBlastError : public std::runtime_error {
public:
    BitBlastError(frontend::SourceLocation location, const std::string& message,
                  bool unsupported = false);
    const frontend::SourceLocation& location() const noexcept { return location_; }
    bool unsupported() const noexcept { return unsupported_; }

private:
    frontend::SourceLocation location_;
    bool unsupported_;
};

// Bit vectors are stored least-significant bit first. Signal variables are
// allocated on first reference, in deterministic expression traversal order.
class TirBitBlaster {
public:
    explicit TirBitBlaster(Solver& solver) : solver_(solver) {}

    std::vector<Literal> encode_signal(const std::string& name,
                                       std::uint64_t width,
                                       bool is_signed,
                                       frontend::SourceLocation location = {});
    std::vector<Literal> encode_bits(const lowering::TypedExpression& expression);
    Literal encode_predicate(const lowering::TypedExpression& expression);
    void require_true(const lowering::TypedExpression& expression);
    void require_false(const lowering::TypedExpression& expression);

    const std::map<std::string, std::vector<Literal>>& signal_variables() const noexcept {
        return signal_variables_;
    }

private:
    std::vector<Literal> encode(const lowering::TypedExpression& expression);
    std::vector<Literal> encode_literal(const lowering::TypedExpression& expression);
    Literal encode_unary(const lowering::TypedExpression& expression);
    std::vector<Literal> encode_binary(const lowering::TypedExpression& expression);
    std::vector<Literal> encode_bit_vector_function(const lowering::TypedExpression& expression);
    std::vector<Literal> add_equal_width(const std::vector<Literal>& left,
                                         const std::vector<Literal>& right, bool subtract);
    std::vector<Literal> encode_conditional(const lowering::TypedExpression& expression);
    std::vector<Literal> encode_concatenation(
        const lowering::TypedExpression& expression);
    std::vector<Literal> encode_casez_match(
        const lowering::TypedExpression& expression);
    std::vector<Literal> extend_bits(std::vector<Literal> bits,
                                     std::size_t width,
                                     bool sign_extend);

    Literal constant(bool value);
    Literal make_and(Literal left, Literal right);
    Literal make_or(Literal left, Literal right);
    Literal make_xor(Literal left, Literal right);
    Literal make_mux(Literal select, Literal when_true, Literal when_false);
    Literal compare_less(const std::vector<Literal>& left,
                         const std::vector<Literal>& right,
                         bool signed_comparison);
    Literal reduce_or(const std::vector<Literal>& bits);
    Literal reduce_and(const std::vector<Literal>& bits);
    std::vector<Literal>& signal_bits(const lowering::TypedExpression& expression);
    [[noreturn]] void fail(const lowering::TypedExpression& expression,
                           const std::string& message) const;

    Solver& solver_;
    std::map<std::string, std::vector<Literal>> signal_variables_;
    Literal true_literal_ = 0;
    Literal false_literal_ = 0;
};

} // namespace q3a::sat
