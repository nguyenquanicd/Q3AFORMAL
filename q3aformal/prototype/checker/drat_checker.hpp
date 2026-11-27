#pragma once

#include <cstdint>
#include <functional>
#include <iosfwd>
#include <optional>
#include <string>

namespace q3a::checker {

inline constexpr std::uint32_t kMaximumCheckerVariables = 1000000;
inline constexpr std::uint64_t kMaximumCheckerCnfClauses = 1000000;
inline constexpr std::uint64_t kMaximumCheckerProofRecords = 1000000;
inline constexpr std::uint64_t kMaximumCheckerLiterals = 10000000;
inline constexpr std::uint64_t kMaximumCheckerLineBytes = 64 * 1024 * 1024;

struct CheckerLimits {
    std::uint32_t maximum_variables = kMaximumCheckerVariables;
    std::uint64_t maximum_cnf_clauses = kMaximumCheckerCnfClauses;
    std::uint64_t maximum_proof_records = kMaximumCheckerProofRecords;
    std::uint64_t maximum_cnf_literals = kMaximumCheckerLiterals;
    std::uint64_t maximum_proof_literals = kMaximumCheckerLiterals;
    // Optional host policy. Throw to stop before a proposed allocation.
    std::function<void(std::uint64_t pending_bytes)> check_memory;
    std::uint64_t maximum_line_bytes = kMaximumCheckerLineBytes;
};

struct CheckResult {
    bool accepted = false;
    std::uint64_t proof_records = 0;
    std::string message;
    bool resource_limited = false;
};

// Checks a DIMACS CNF and a textual DRAT proof independently of the SAT solver.
CheckResult verify_drat(std::istream& cnf_input, std::istream& proof_input,
                        const CheckerLimits& limits = {});

using ProofLineReader = std::function<bool(std::string&)>;
// A reader returns false at a valid end of proof and throws on framing or I/O errors.
CheckResult verify_drat_records(std::istream& cnf_input,
                                const ProofLineReader& next_line,
                                const CheckerLimits& limits,
                                std::optional<std::uint64_t> declared_records = std::nullopt);

} // namespace q3a::checker
