#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>
#include <iosfwd>
#include <utility>
#include <vector>

namespace q3a::sat {

// Literals use the DIMACS convention: +n is variable n and -n is its negation.
using Literal = std::int32_t;

enum class Status {
    Satisfiable,
    Unsatisfiable,
    Unknown
};

struct Limits {
    // A zero limit means unlimited. Limits are checked deterministically.
    std::uint64_t decisions = 0;
    std::uint64_t propagations = 0;
    // Record a RUP proof for a standalone CNF query. This rejects assumptions,
    // which must instead be encoded as clauses in the proof input.
    bool record_drat_proof = false;
    // A zero proof-record limit means unlimited.
    std::uint64_t proof_records = 0;
    // A sink receives records during search. Discard its output unless the
    // result is UNSAT with a nonzero proof_record_count.
    std::function<void(const std::vector<Literal>&)> proof_sink = {};
};

struct Result {
    Status status = Status::Unknown;
    // Index zero is unused; values are -1 (unassigned), 0 (false), or 1 (true).
    std::vector<std::int8_t> assignment;
    std::uint64_t decisions = 0;
    std::uint64_t propagations = 0;
    std::uint64_t conflicts = 0;
    std::uint64_t learned_clauses = 0;
    std::size_t reused_clauses = 0;
    std::uint64_t backjumps = 0;
    std::uint64_t nonchronological_backjumps = 0;
    // Complete only when status is UNSAT, recording was requested, and the
    // final entry is the empty clause. Assumption queries are not logged.
    std::vector<std::vector<Literal>> drat_additions;
    std::uint64_t proof_record_count = 0;
};

class Solver {
public:
    Solver() = default;
    explicit Solver(std::function<void(std::uint64_t)> memory_check)
        : memory_check_(std::move(memory_check)) {}

    std::uint32_t new_variable();
    void add_clause(const std::vector<Literal>& literals);
    // Assumptions are temporary unit literals for this solve call only.
    Result solve(const Limits& limits = {},
                 const std::vector<Literal>& assumptions = {}) const;
    // Reuse learned consequences across permanent clause additions only.
    // Standalone proof and temporary-clause queries use the original CNF.
    Result solve_incremental();

    // Apply one temporary disjunction without making a copy of the base CNF.
    Result solve_with_temporary_clause(const std::vector<Literal>& literals);

    std::uint32_t variable_count() const noexcept { return variable_count_; }
    std::size_t clause_count() const noexcept {
        return clause_offsets_.size() + (contains_empty_clause_ ? 1U : 0U);
    }
    void write_dimacs(std::ostream& output) const;

private:
    Result solve_internal(const Limits& limits, const std::vector<Literal>& assumptions,
                          std::vector<std::vector<Literal>>* retained) const;
    void poll_memory(std::uint64_t pending_bytes = 0) const;
    std::uint32_t variable_count_ = 0;
    bool contains_empty_clause_ = false;
    // Each offset starts a nonempty range. Empty clauses are tracked separately.
    std::vector<std::size_t> clause_offsets_;
    std::vector<Literal> clause_literals_;
    std::vector<std::vector<Literal>> retained_clauses_;
    std::function<void(std::uint64_t)> memory_check_;
    mutable std::uint32_t memory_operations_ = 0;
};

const char* status_name(Status status) noexcept;

} // namespace q3a::sat
