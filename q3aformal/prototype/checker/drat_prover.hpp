#pragma once

#include "drat_checker.hpp"

#include <cstdint>
#include <iosfwd>
#include <string>
#include <vector>

namespace q3a::checker {

enum class ProofStatus {
    Unsatisfiable,
    Satisfiable,
    Unknown
};

struct ProofLimits {
    std::uint64_t maximum_search_nodes = 1000000;
    std::uint64_t maximum_proof_records = 1000000;
    // Bound recursion conservatively for typical Windows process stacks.
    // A limit hit returns UNKNOWN; it can never be reported as a proof.
    std::uint32_t maximum_depth = 256;
    std::uint32_t maximum_variables = 1000000;
    CheckerLimits input_limits;
};

struct ProofResult {
    ProofStatus status = ProofStatus::Unknown;
    std::uint64_t search_nodes = 0;
    std::vector<std::vector<std::int32_t>> additions;
    std::string message;
};

// Generates a deterministic RUP-only DRAT refutation for an UNSAT DIMACS CNF.
// This simple DPLL proof search is separate from the watched-literal SAT solver.
ProofResult generate_rup_refutation(
    std::istream& cnf_input, const ProofLimits& limits = {});

void write_rup_proof(const ProofResult& result, std::ostream& output);

} // namespace q3a::checker
