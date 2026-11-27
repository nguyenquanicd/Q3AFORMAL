#pragma once

#include "lowering.hpp"

#include <array>

namespace q3a { class MemoryBudget; }

namespace q3a::lowering {

// Builds a clock-enable state equation over the current frame. Changes to
// multiple state signals commit together in the transition encoder.
TIREquation sampled_assignment(const TIRSignal& target, TypedExpression enable,
                                TypedExpression value, frontend::SourceLocation location);

struct MemoryAccess {
    TypedExpression enable;
    TypedExpression address;
    frontend::SourceLocation location;
};

struct ExactMemoryTransition {
    std::vector<TIREquation> equations;
    TypedExpression read_in_range;
    TypedExpression write_in_range;
};

// Cells are already declared T-IR state, in ascending numeric address order.
// Both addresses are unsigned bit vectors. Supply a distinct fresh input for
// an invalid enabled read. Range conditions are proof goals, never assumptions.
// Both enables must already include the local sampling event, when applicable.
ExactMemoryTransition exact_read_old_memory(
    std::uint64_t first_address, const std::vector<TIRSignal>& cells,
    const MemoryAccess& read, const MemoryAccess& write, TypedExpression write_value,
    const TIRSignal& read_target, const TIRSignal& invalid_read_value,
    const MemoryBudget* budget = nullptr);

// Builds two same-sample proof targets, preserving the access locations and
// checking the caller's property labels against the current model. The caller
// adds both targets to the same model before running any property checks.
std::array<TIRProperty, 2> memory_range_assertions(
    const TIRModule& model, const ExactMemoryTransition& transition, const std::string& clock,
    std::string read_label, std::string write_label);

inline constexpr const char* kMemoryReadRange = "__q3a_read_in_range";
inline constexpr const char* kMemoryWriteRange = "__q3a_write_in_range";

// Shared SVA lowering runs against source-visible scalar ports and helpers.
void attach_exact_memory_source_properties(TIRModule& model, const frontend::SyntaxUnit& unit,
    const frontend::ParsedModule& declaration, const elaboration::ElaboratedModule& elaborated);

// Internal source integration for one top-level memory and two independent
// enabled nonblocking accesses in one process. Scalar helpers share its clock.
// max_cells is a caller budget.
TIRModule lower_exact_memory_source(const frontend::SyntaxUnit& unit,
                                    const elaboration::ElaborationResult& design,
                                    std::uint64_t max_cells, const MemoryBudget* budget = nullptr);

} // namespace q3a::lowering
