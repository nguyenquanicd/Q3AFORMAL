#pragma once

#include "source_graph.hpp"

#include <filesystem>

namespace q3a::liveness {

struct EvidenceIdentity {
    std::string model_sha256;
    std::string manifest_sha256;
    std::string build_id;
};

struct SavedEvidence {
    Result result;
    std::string sha256;
};

// Publish a new artifact without replacing an existing path.
std::string save_evidence(const std::filesystem::path& path, const EvidenceIdentity& identity,
    const Query& query, const Graph& graph, const Result& result, const MemoryBudget& budget);

// The caller regenerates the graph from source. This function validates the
// supplied evidence and never runs the liveness search.
SavedEvidence reopen_evidence(const std::filesystem::path& path, const EvidenceIdentity& identity,
    const Query& query, const Graph& graph, const MemoryBudget& budget);

// Export the prefix and exactly one loop traversal from revalidated evidence.
std::string save_lasso_vcd(const std::filesystem::path& path, const lowering::TIRModule& model,
    const SourceGraph& graph, const Lasso& lasso, const MemoryBudget& budget);

} // namespace q3a::liveness
