#pragma once

#include "../../checker/proof_artifact.hpp"

#include <cstdint>
#include <filesystem>
#include <string>

namespace q3a::cache {

struct ProofIdentity {
    std::string profile_id;
    std::string input_sha256;
    std::string manifest_sha256;
    std::string model_sha256;
    std::string model_schema;
    std::string build_id;
    std::string checker_fingerprint;
    std::string algorithm;
    std::string property;
    std::string obligation;
    std::string solver_options;
    std::uint64_t depth = 0;
};

enum class LookupState {
    Miss,
    Hit,
    Rejected,
    ResourceLimited
};

struct LookupResult {
    LookupState state = LookupState::Miss;
    std::string key;
    std::uint64_t proof_records = 0;
    std::string message;
    std::string artifact_sha256;
};

struct StoreResult {
    bool stored = false;
    std::string message;
};

// Cache keys bind a checked proof to all run identity fields and exact CNF bytes.
std::string proof_cache_key(
    const ProofIdentity& identity,
    const std::string& cnf,
    const checker::ArtifactMetadata& metadata);

// A hit is returned only after the current DRAT checker accepts the exact CNF
// and artifact. Invalid entries are rejected and never treated as evidence.
LookupResult lookup_checked_proof(
    const std::filesystem::path& cache_directory,
    const ProofIdentity& identity,
    const std::filesystem::path& cnf_path,
    const checker::ArtifactMetadata& metadata,
    const checker::CheckerLimits& limits = {},
    const std::filesystem::path& checked_proof_output = {});

// Publishes an already checker-accepted artifact with an atomic directory rename.
StoreResult store_checked_proof(
    const std::filesystem::path& cache_directory,
    const ProofIdentity& identity,
    const std::filesystem::path& cnf_path,
    const std::filesystem::path& artifact_path,
    const checker::ArtifactMetadata& metadata,
    const checker::CheckerLimits& limits = {});

} // namespace q3a::cache
