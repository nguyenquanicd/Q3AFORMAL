#pragma once

#include "../sat/pdr.hpp"

namespace q3a::memory_proof {

enum class Outcome { Proven, RangeUnproved, PropertyUnproved, Inconsistent };
enum class ActivationStatus { Activated, PendingAssumption, NotFoundWithinBound, Unknown, Inconsistent };

struct ActivationCheck {
    ActivationStatus status;
    std::size_t bound;
    std::optional<std::size_t> frame = std::nullopt;
};

struct InvalidAccess {
    std::string property;
    frontend::SourceLocation location;
    std::string address_signal;
    std::uint64_t address;
    std::uint64_t first;
    std::uint64_t last;
    std::string enable_signal;
};

struct RangeWitness {
    std::size_t frame;
    bool boundary_incomplete;
    std::vector<InvalidAccess> accesses;
};

struct Result {
    Outcome outcome;
    std::string property;
    std::optional<RangeWitness> range_witness = std::nullopt;
    std::optional<std::size_t> inconsistent_bound = std::nullopt;
    std::optional<ActivationCheck> activation = std::nullopt;
};

// Internal contract for an exact-memory model lowered from source. The supplied
// claim and the generated access assertions must belong to the same T-IR.
// Accept a primary safety certificate only after both access certificates have
// been checked against that model. Incomplete evidence cannot return Proven.
Result check(const lowering::TIRModule& model, const std::string& property,
             const std::filesystem::path& evidence, bool reopen,
             std::size_t maximum_depth, std::size_t maximum_search_queries,
             const MemoryBudget& memory, bool diagnose_range = false,
             const std::filesystem::path& range_trace = {},
             std::optional<std::size_t> activation_bound = std::nullopt);

RangeWitness reopen_range_trace(const lowering::TIRModule& model, const std::string& property,
                               const std::filesystem::path& input, const MemoryBudget& memory);
RangeWitness reopen_range_trace(const lowering::TIRModule& model, const std::string& property,
                               std::istream& input, const MemoryBudget& memory);

} // namespace q3a::memory_proof
