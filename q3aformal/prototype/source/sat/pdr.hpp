#pragma once

#include "lowering.hpp"
#include "sat_solver.hpp"
#include "source_manager.hpp"

#include <cstddef>
#include <filesystem>
#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <vector>

namespace q3a::pdr {

// Literals identify one-based state bit positions in next-state equation order.
using Invariant = std::set<std::vector<sat::Literal>>;
enum class Status { InvariantFound, CounterexampleCandidate, Inconsistent, Unknown, ResourceLimited };
inline constexpr std::size_t kMaximumDepth = 128;
inline constexpr std::size_t kDefaultSearchQueries = 10000;

struct Result {
    Status status;
    std::size_t depth;
    Invariant invariant;
    std::size_t search_queries = 0;
    std::size_t search_cnf_builds = 0;
    std::size_t search_state_bits = 0;
    std::size_t full_state_bits = 0;
    std::size_t search_signal_bits = 0;
    std::size_t full_signal_bits = 0;
    std::size_t initial_zero_rejections = 0;
    std::optional<std::size_t> feasible_prefix_bound = std::nullopt;
};

// Violation of the derived assertion is exactly activation of the source
// assertion. The derived model has a different proof identity.
lowering::TIRModule activation_model(const lowering::TIRModule& model, const std::string& property);

Result search(const lowering::TIRModule& model, const std::string& property,
              std::size_t maximum_depth, std::size_t maximum_search_queries,
              const MemoryBudget& memory, std::size_t minimum_feasibility_bound = 0);

struct CertificateObligation {
    std::string kind;
    std::string query_sha256;
    std::string proof_sha256;
};

inline constexpr const char* kCertificateRunConfigurationFile = "run-configuration.json";

struct CheckedCertificate {
    std::string model_sha256;
    std::vector<CertificateObligation> obligations;
    std::string run_configuration_sha256;
};

// A certificate identity is returned only after all checks and publication succeed.
std::optional<CheckedCertificate> certify(const lowering::TIRModule& model, const std::string& property,
             const Invariant& invariant, const std::filesystem::path& directory,
             const MemoryBudget& memory, std::string_view run_configuration = {});

struct CertificateGroupEntry {
    std::string property;
    std::string folder;
    Invariant invariant;
};

// Publish all checked certificates together. Return the property whose
// certificate could not be checked, or nullopt after successful publication.
std::optional<std::string> certify_group(const lowering::TIRModule& model,
    const std::vector<CertificateGroupEntry>& entries, const std::filesystem::path& directory,
    const MemoryBudget& memory);

// Regenerates all three queries and returns the identities of the checked files.
std::optional<CheckedCertificate> verify(const lowering::TIRModule& model, const std::string& property,
            const std::filesystem::path& directory, const MemoryBudget& memory);

} // namespace q3a::pdr
