#include "fair_cycle.hpp"

#include <algorithm>
#include <limits>
#include <utility>

namespace q3a::liveness {
namespace {

constexpr Vertex no_vertex = std::numeric_limits<Vertex>::max();

bool well_formed(const Graph& graph) {
    const auto in_range = [&graph](Vertex vertex) { return vertex < graph.states.size(); };
    if (!std::all_of(graph.initial.begin(), graph.initial.end(), in_range)) return false;
    for (const auto& state : graph.states) {
        if (!std::all_of(state.successors.begin(), state.successors.end(), in_range)) return false;
    }
    return true;
}

bool has_edge(const State& from, Vertex target) {
    return std::find(from.successors.begin(), from.successors.end(), target) != from.successors.end();
}

template <typename InRegion>
std::vector<Vertex> predecessors(const Graph& graph, const std::vector<Vertex>& initial,
                                 InRegion in_region, Vertex target = no_vertex) {
    std::vector<Vertex> parent(graph.states.size(), no_vertex);
    std::vector<Vertex> queue;
    for (const auto vertex : initial) {
        if (parent[vertex] == no_vertex) {
            parent[vertex] = vertex;
            queue.push_back(vertex);
        }
    }
    for (std::size_t head = 0; head < queue.size() && (target == no_vertex || parent[target] == no_vertex); ++head) {
        const auto from = queue[head];
        for (const auto to : graph.states[from].successors) {
            if (in_region(to) && parent[to] == no_vertex) {
                parent[to] = from;
                queue.push_back(to);
            }
        }
    }
    return parent;
}

std::vector<Vertex> path_to(const std::vector<Vertex>& parent, Vertex target) {
    std::vector<Vertex> path{target};
    while (parent[target] != target) {
        target = parent[target];
        path.push_back(target);
    }
    std::reverse(path.begin(), path.end());
    return path;
}

Lasso make_lasso(const Graph& graph, const std::vector<Vertex>& members,
                 const std::vector<std::size_t>& ranks, const std::vector<Vertex>& prefix) {
    const auto entry = members.front();
    const auto same_rank = [&](Vertex vertex) { return ranks[vertex] == ranks[entry]; };
    auto path = path_to(prefix, entry);
    const auto loop_start = path.size() - 1;
    const auto visit = [&](Vertex vertex) {
        if (path.back() == vertex) return;
        const auto parent = predecessors(graph, {path.back()}, same_rank, vertex);
        const auto segment = path_to(parent, vertex);
        path.insert(path.end(), segment.begin() + 1, segment.end());
    };
    auto missing = graph.required_justice & ~graph.states[entry].justice;
    for (const auto vertex : members) {
        if (missing == 0) break;
        if ((missing & graph.states[vertex].justice) != 0) {
            visit(vertex);
            missing &= ~graph.states[vertex].justice;
        }
    }
    if (path.size() == loop_start + 1) {
        // Even if the entry witnesses every condition, the loop needs an edge.
        const auto& edges = graph.states[entry].successors;
        path.push_back(*std::find_if(edges.begin(), edges.end(), same_rank));
    }
    visit(entry);
    return {std::move(path), loop_start};
}

struct CycleSearch {
    std::optional<Lasso> lasso;
    std::optional<Exclusion> exclusion;
};

CycleSearch find_cycle(const Graph& graph, const std::vector<Vertex>& prefix, bool pending_only) {
    const auto count = graph.states.size();
    const auto included = [&](Vertex vertex) {
        return prefix[vertex] != no_vertex && (!pending_only || graph.states[vertex].pending);
    };
    std::vector<std::vector<Vertex>> incoming(count);
    for (Vertex from = 0; from < count; ++from) {
        if (!included(from)) continue;
        for (const auto to : graph.states[from].successors) {
            if (included(to)) incoming[to].push_back(from);
        }
    }

    // Iterative Kosaraju traversal. The second pass numbers components in
    // topological order, so no edge between components decreases the rank.
    std::vector<bool> seen(count, false);
    std::vector<Vertex> finished;
    std::vector<std::pair<Vertex, std::size_t>> stack;
    for (Vertex start = 0; start < count; ++start) {
        if (!included(start) || seen[start]) continue;
        seen[start] = true;
        stack.emplace_back(start, 0);
        while (!stack.empty()) {
            auto& frame = stack.back();
            const auto& edges = graph.states[frame.first].successors;
            if (frame.second == edges.size()) {
                finished.push_back(frame.first);
                stack.pop_back();
                continue;
            }
            const auto to = edges[frame.second++];
            if (included(to) && !seen[to]) {
                seen[to] = true;
                stack.emplace_back(to, 0);
            }
        }
    }

    std::vector<std::size_t> ranks(count, 0);
    std::vector<Vertex> members;
    std::size_t rank = 0;
    for (auto vertex = finished.rbegin(); vertex != finished.rend(); ++vertex) {
        if (ranks[*vertex] != 0) continue;
        ++rank;
        ranks[*vertex] = rank;
        members.assign(1, *vertex);
        std::uint64_t justice = 0;
        for (std::size_t head = 0; head < members.size(); ++head) {
            const auto from = members[head];
            justice |= graph.states[from].justice;
            for (const auto to : incoming[from]) {
                if (ranks[to] == 0) {
                    ranks[to] = rank;
                    members.push_back(to);
                }
            }
        }
        const bool cyclic = members.size() > 1 || has_edge(graph.states[*vertex], *vertex);
        if (cyclic && (justice & graph.required_justice) == graph.required_justice) {
            return {make_lasso(graph, members, ranks, prefix), std::nullopt};
        }
    }
    std::vector<bool> reachable(count);
    std::transform(prefix.begin(), prefix.end(), reachable.begin(),
                   [](Vertex parent) { return parent != no_vertex; });
    return {std::nullopt, Exclusion{std::move(ranks), std::move(reachable)}};
}

bool valid_lasso(const Graph& graph, const Lasso& evidence, bool pending_only) {
    const auto& path = evidence.path;
    if (path.size() < 2 || evidence.loop_start >= path.size() - 1 ||
        path[evidence.loop_start] != path.back() ||
        std::find(graph.initial.begin(), graph.initial.end(), path.front()) == graph.initial.end()) {
        return false;
    }
    std::uint64_t justice = 0;
    for (std::size_t index = 0; index < path.size(); ++index) {
        const auto vertex = path[index];
        if (vertex >= graph.states.size()) return false;
        const auto& state = graph.states[vertex];
        if (index + 1 < path.size() && !has_edge(state, path[index + 1])) return false;
        if (index >= evidence.loop_start) {
            if (pending_only && !state.pending) return false;
            justice |= state.justice;
        }
    }
    return (justice & graph.required_justice) == graph.required_justice;
}

bool valid_exclusion(const Graph& graph, const Exclusion& evidence, bool pending_only) {
    const auto count = graph.states.size();
    if (evidence.ranks.size() != count || evidence.reachable.size() != count) return false;
    for (const auto start : graph.initial) {
        if (!evidence.reachable[start]) return false;
    }
    struct Rank {
        std::size_t size = 0;
        std::uint64_t justice = 0;
        bool self_edge = false;
    };
    std::vector<Rank> summary(count + 1);
    for (Vertex from = 0; from < count; ++from) {
        const auto rank = evidence.ranks[from];
        const auto included = evidence.reachable[from] && (!pending_only || graph.states[from].pending);
        if (rank > count || included != (rank != 0)) return false;
        if (!evidence.reachable[from]) continue;
        for (const auto to : graph.states[from].successors) {
            if (!evidence.reachable[to]) return false;
            const auto target_rank = evidence.ranks[to];
            if (rank != 0 && target_rank != 0 && target_rank < rank) return false;
        }
        if (included) {
            auto& group = summary[rank];
            ++group.size;
            group.justice |= graph.states[from].justice;
            group.self_edge |= has_edge(graph.states[from], from);
        }
    }
    for (const auto& group : summary) {
        if ((group.size > 1 || group.self_edge) &&
            (group.justice & graph.required_justice) == graph.required_justice) return false;
    }
    return true;
}

} // namespace

Result search(const Graph& graph) {
    if (!well_formed(graph)) return {};
    const auto prefix = predecessors(graph, graph.initial, [](Vertex) { return true; });
    auto pending = find_cycle(graph, prefix, true);
    if (pending.lasso) return {Status::Violation, std::move(pending.lasso), std::nullopt};
    auto environment = find_cycle(graph, prefix, false);
    if (!environment.lasso) return {Status::NoFairExecution, std::nullopt, std::move(environment.exclusion)};
    return {Status::NoViolation, std::move(environment.lasso), std::move(pending.exclusion)};
}

bool validate(const Graph& graph, const Result& result) {
    if (!well_formed(graph)) return false;
    switch (result.status) {
    case Status::Violation:
        return !result.exclusion && result.lasso && valid_lasso(graph, *result.lasso, true);
    case Status::NoViolation:
        return result.lasso && valid_lasso(graph, *result.lasso, false) &&
               result.exclusion && valid_exclusion(graph, *result.exclusion, true);
    case Status::NoFairExecution:
        return !result.lasso && result.exclusion && valid_exclusion(graph, *result.exclusion, false);
    case Status::InvalidGraph:
        return false;
    }
    return false;
}

} // namespace q3a::liveness
