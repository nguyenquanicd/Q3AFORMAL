#pragma once

#include "fair_cycle.hpp"
#include "../replay/property_replay.hpp"

namespace q3a { class MemoryBudget; }

namespace q3a::liveness {

inline constexpr std::size_t kMaximumVertices = 65536;
inline constexpr std::size_t kMaximumEdges = 1048576;

struct Query {
    std::string property;
    std::string request;
    std::string response;
    std::vector<std::string> justice;
    std::size_t maximum_vertices = kMaximumVertices;
    std::size_t maximum_edges = kMaximumEdges;
};

struct Sample {
    std::uint64_t packed_state;
    std::uint64_t packed_input;
    bool waiting;
    bool request;
    bool response;
};

struct SourceGraph {
    Graph graph;
    std::vector<Sample> samples;
    // First name occupies the least significant bits.
    std::vector<const lowering::TIRSignal*> state_layout;
    std::vector<const lowering::TIRSignal*> input_layout;
    std::vector<const lowering::TIREquation*> combinational;
};

// References in the returned layout remain valid while the model is alive.
// A named assertion supplies both predicates and its implication alignment.
// Direct signal mode checks the overlapped eventual-response property.
SourceGraph build_source_graph(const lowering::TIRModule& model, const Query& query,
                               const MemoryBudget& budget);

// The caller initializes the frame dictionary with all model signals.
void reconstruct_sample(const SourceGraph& source, Vertex vertex, replay::Frame& frame);

} // namespace q3a::liveness
