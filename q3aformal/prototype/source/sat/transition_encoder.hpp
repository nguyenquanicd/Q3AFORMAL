#pragma once

#include "tir_bit_blaster.hpp"

#include <cstdint>
#include <map>
#include <memory>
#include <string>
#include <vector>

namespace q3a::sat {

// Encodes the bounded, synchronous transition relation in a lowered Q3A TIR
// module. Frame zero has unconstrained state, matching the Phase 0 contract.
class TransitionCnfEncoder {
public:
    struct AssertionQuery {
        std::vector<Literal> violation_literals;
        std::vector<std::size_t> violation_frames;
        std::vector<Literal> activation_literals;
        bool always_active = false;
        bool boundary_incomplete = false;
    };

    struct CoverQuery {
        std::vector<Literal> hit_literals;
        std::vector<std::size_t> hit_frames;
        bool boundary_limited = false;
    };

    TransitionCnfEncoder(Solver& solver, const lowering::TIRModule& module);

    void encode(std::uint64_t transition_count,
                bool initialize_history_validity = true);
    void constrain_assumptions();
    // Induction limits temporal assumptions to complete obligations inside
    // its proof window; the BMC overload retains boundary-incomplete checks.
    void constrain_assumptions(std::size_t last_relevant_frame);
    bool assumptions_boundary_incomplete() const noexcept {
        return assumptions_boundary_incomplete_;
    }
    bool boundary_incomplete(const AssertionQuery& query) const noexcept {
        return assumptions_boundary_incomplete_ || query.boundary_incomplete;
    }
    bool boundary_incomplete(const CoverQuery& query) const noexcept {
        return assumptions_boundary_incomplete_ || query.boundary_limited;
    }
    // Builds bounded violation goals for scalar and standalone linear
    // sequence assertions, plus linear implication assertions. Sequence
    // starts without a complete horizon are reported as boundary-incomplete.
    AssertionQuery add_assertion_violation(
        const std::string& property_name);
    // The assignment must be a SAT witness for the encoded model and assumptions.
    // A witness satisfying any activation literal makes another solve unnecessary.
    Status assertion_activity(const AssertionQuery& query,
                              const std::vector<std::int8_t>& feasible_assignment);
    // Encodes scalar and linear sequence assertions plus linear implications
    // with fixed delays, finite bounded delay ranges, and bounded repetition.
    // Assumptions use the same supported linear sequence profile.
    // A guarded $past property is represented as !history_valid || predicate
    // where that guard is supported.
    Literal encode_induction_assertion_at_frame(
        const std::string& property_name, std::size_t frame);
    std::vector<Literal> encode_induction_obligation(
        const lowering::TIRProperty& property, std::uint64_t depth, bool base);
    CoverQuery add_cover_hit(const std::string& property_name);

    const std::vector<std::map<std::string, std::vector<Literal>>>& frames() const {
        return frames_;
    }

private:
    void constrain_assumptions(
        std::size_t last_relevant_frame,
        bool truncate_open_temporal_tail);

    struct SequenceMatch {
        std::size_t end_frame = 0;
        Literal match_literal = 0;
    };

    void validate() const;
    void validate_property_clock_and_guard(
        const lowering::TIRProperty& property) const;
    void validate_property_expression(
        const lowering::TypedExpression& expression) const;
    std::uint64_t sequence_max_offset(
        const lowering::TIRSequence& sequence) const;
    std::vector<SequenceMatch> sequence_matches(
        const lowering::TIRSequence& sequence,
        std::size_t start_frame,
        std::uint64_t& predicate_budget);
    Literal make_and(Literal left, Literal right);
    Literal make_or(Literal left, Literal right);
    void equate(const std::vector<Literal>& left,
                const std::vector<Literal>& right,
                const lowering::TIREquation& equation);

    Solver& solver_;
    const lowering::TIRModule& module_;
    std::vector<std::unique_ptr<TirBitBlaster>> bitblasters_;
    std::vector<std::map<std::string, std::vector<Literal>>> frames_;
    bool assumptions_boundary_incomplete_ = false;
};

} // namespace q3a::sat
