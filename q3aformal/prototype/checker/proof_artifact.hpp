#pragma once

#include "drat_checker.hpp"
#include "drat_prover.hpp"

#include <iosfwd>
#include <string>

namespace q3a::checker {

inline constexpr const char* kCheckerId = "q3a-drat-checker-0.2";
inline constexpr unsigned kProofArtifactSchema = 2;

struct ArtifactMetadata {
    std::string query_kind;
    std::string checker_id;
    std::string model_sha256;
    std::string query_sha256;
};

CheckResult write_drat_artifact(
    const ProofResult& proof,
    const ArtifactMetadata& metadata,
    std::ostream& output);

// Wrap a staged textual proof body. The resulting artifact still requires checking.
CheckResult write_drat_artifact(
    std::istream& records, std::uint64_t record_count,
    const ArtifactMetadata& metadata, std::ostream& output);

// The caller binds query_sha256 to the exact CNF bytes and keeps the input
// stable during verification. This function compares metadata and checks DRAT.
CheckResult verify_drat_artifact(
    std::istream& cnf_input,
    std::istream& artifact_input,
    const ArtifactMetadata& expected_metadata,
    const CheckerLimits& limits = {});

} // namespace q3a::checker
