#pragma once

#include "source.hpp"

#include <filesystem>
#include <optional>

namespace q3a { class MemoryBudget; }
namespace q3a::replay { class ReplayTiming; }

namespace q3a::four_state {

struct Claim {
    std::string signal;
    std::optional<Word> expected;
    std::optional<std::size_t> sample;
};

enum class ProofOutcome { Proven, Revalidated, Counterexample, CoverHit, Inconsistent, Unknown };

struct ProofResult {
    ProofOutcome outcome;
    std::string proof_model_sha256;
    std::string query_sha256;
    std::string proof_sha256;
    std::vector<Frame> trace;
    std::optional<std::size_t> attempt_sample = std::nullopt;
    std::optional<std::size_t> failure_sample = std::nullopt;
    std::optional<std::size_t> antecedent_end_sample = std::nullopt;
    bool assumption_boundary_open = false;
    std::optional<std::size_t> match_sample = std::nullopt;
    bool cover = false;
    std::string witness_sha256{};
    bool witness_revalidated = false;
};

ProofResult check_exact(const lowering::TIRModule& model, const Claim& claim,
    std::string_view model_identity, const std::filesystem::path& evidence,
    const MemoryBudget& budget, bool reopen, bool save_counterexample,
    const replay::ReplayTiming* timing = nullptr);

std::string save_waveform(const std::filesystem::path& path, const lowering::TIRModule& model,
                          const ProofResult& result, const MemoryBudget& budget);

} // namespace q3a::four_state
