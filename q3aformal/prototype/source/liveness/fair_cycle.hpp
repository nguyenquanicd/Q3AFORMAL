#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>
#include <vector>

namespace q3a::liveness {

using Vertex = std::size_t;

struct State {
    bool pending = false;
    std::uint64_t justice = 0;
    std::vector<Vertex> successors;
};

// Vertices represent complete states of the design and obligation monitor.
// Each required bit must occur infinitely often on an admissible execution.
struct Graph {
    std::vector<State> states;
    std::vector<Vertex> initial;
    std::uint64_t required_justice = 0;
};

struct Lasso {
    std::vector<Vertex> path;
    std::size_t loop_start = 0; // The last vertex repeats path[loop_start].
};

struct Exclusion {
    // One-based ranks cover the cycle search region. Zero marks excluded vertices.
    std::vector<std::size_t> ranks;
    std::vector<bool> reachable;
};

enum class Status { InvalidGraph, NoFairExecution, NoViolation, Violation };

struct Result {
    Status status = Status::InvalidGraph;
    std::optional<Lasso> lasso;
    std::optional<Exclusion> exclusion;
};

// Violation requires an infinite fair suffix entirely inside the pending region.
// NoViolation includes both a fair execution and exclusion of every bad suffix.
// NoFairExecution excludes fair executions from the complete reachable graph.
Result search(const Graph& graph);

// Check evidence against the graph without rerunning the component search.
bool validate(const Graph& graph, const Result& result);

} // namespace q3a::liveness
