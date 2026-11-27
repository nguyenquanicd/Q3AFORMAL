#include "fair_cycle.hpp"

#include <array>
#include <cstdlib>
#include <iostream>
#include <stdexcept>
#include <vector>

using namespace q3a::liveness;

namespace {

void check(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}

// Independent oracle for three-state graphs. Enumerate walks using the product
// of the vertex and the accumulating set of justice bits, without SCCs or ranks.
bool oracle_loop(const Graph& graph, unsigned reachable, bool pending_only) {
    const auto allowed = [&](Vertex vertex) { return !pending_only || graph.states[vertex].pending; };
    for (Vertex entry = 0; entry < 3; ++entry) {
        if ((reachable & (1u << entry)) == 0 || !allowed(entry)) continue;
        std::array<bool, 12> visited{};
        std::array<unsigned, 12> queue{};
        std::size_t tail = 0;
        const auto extend = [&](Vertex from, unsigned mask) {
            for (const auto to : graph.states[from].successors) {
                if (!allowed(to)) continue;
                const auto combined = mask | static_cast<unsigned>(graph.states[to].justice);
                const auto position = static_cast<unsigned>(to) * 4 + combined;
                if (!visited[position]) {
                    visited[position] = true;
                    queue[tail++] = position;
                }
            }
        };
        extend(entry, static_cast<unsigned>(graph.states[entry].justice));
        for (std::size_t cursor = 0; cursor < tail; ++cursor) {
            const auto vertex = queue[cursor] / 4;
            const auto bits = queue[cursor] % 4;
            if (vertex == entry && (bits & graph.required_justice) == graph.required_justice) return true;
            extend(vertex, bits);
        }
    }
    return false;
}

void exhaustive() {
    std::array<std::size_t, 4> totals{};
    for (unsigned edges = 0; edges < 512; ++edges) {
        Graph graph{std::vector<State>(3), {0}, 0};
        for (Vertex from = 0; from < 3; ++from) {
            for (Vertex to = 0; to < 3; ++to) {
                if ((edges & (1u << (from * 3 + to))) != 0) graph.states[from].successors.push_back(to);
            }
        }
        unsigned reachable = 1;
        for (unsigned step = 0; step < 3; ++step) {
            for (Vertex from = 0; from < 3; ++from) {
                if ((reachable & (1u << from)) == 0) continue;
                for (const auto to : graph.states[from].successors) reachable |= 1u << to;
            }
        }
        for (unsigned marks = 0; marks < 512; ++marks) {
            for (Vertex vertex = 0; vertex < 3; ++vertex) {
                const auto label = (marks >> (3 * vertex)) & 7;
                graph.states[vertex].pending = (label & 4) != 0;
                graph.states[vertex].justice = label & 3;
            }
            for (unsigned required = 0; required < 4; ++required) {
                graph.required_justice = required;
                const auto expected = oracle_loop(graph, reachable, true) ? Status::Violation :
                    (oracle_loop(graph, reachable, false) ? Status::NoViolation : Status::NoFairExecution);
                const auto actual = search(graph);
                check(expected == actual.status, "Oracle disagrees with fair-cycle status.");
                check(validate(graph, actual), "Generated evidence failed validation.");
                ++totals[static_cast<std::size_t>(expected)];
            }
        }
    }
    check(totals[1] + totals[2] + totals[3] == 1048576, "Incomplete exhaustive test.");
    check(totals[1] && totals[2] && totals[3], "Missing a conclusive outcome.");
    std::cout << "exhaustive_graph_cases=1048576\nno_fair_execution=" << totals[1]
              << "\nno_violation=" << totals[2] << "\nviolation=" << totals[3] << '\n';
}

void adversarial() {
    const std::uint64_t high = std::uint64_t{1} << 63;
    // The fair closed walk must revisit the hub between disjoint justice leaves.
    const Graph split{{
        {false, 0, {1}},
        {true, 0, {2, 3}},
        {true, 1, {1}},
        {true, high, {1}},
    }, {0}, 1 | high};
    const auto violation = search(split);
    check(violation.status == Status::Violation && validate(split, violation), "Missing multiset fair lasso.");
    auto forged = violation;
    forged.lasso->path = {0, 1, 2, 1};
    forged.lasso->loop_start = 1;
    check(!validate(split, forged), "Accepted loop missing the highest justice bit.");
    forged = violation;
    forged.lasso->loop_start = forged.lasso->path.size() - 1;
    check(!validate(split, forged), "Accepted empty loop.");
    forged = violation;
    forged.lasso->path[1] = 3;
    check(!validate(split, forged), "Accepted a nonexistent transition.");

    // The two pending rank classes cannot close a fair cycle through each other.
    Graph ordered{{
        {true, 1, {0, 1}},
        {true, high, {1, 2}},
        {false, 1 | high, {2}},
    }, {0, 0}, 1 | high};
    const auto safe = search(ordered);
    check(safe.status == Status::NoViolation && validate(ordered, safe), "Expected feasible fair environment.");
    forged = safe;
    forged.exclusion->reachable[1] = false;
    forged.exclusion->ranks[1] = 0;
    check(!validate(ordered, forged), "Accepted nonclosed reachable set.");
    forged = safe;
    forged.exclusion->ranks[0] = forged.exclusion->ranks[1];
    check(!validate(ordered, forged), "Accepted rank containing all justice conditions.");
    forged = safe;
    forged.exclusion->ranks[0] = ordered.states.size() + 1;
    check(!validate(ordered, forged), "Accepted rank beyond the model bounds.");
    ordered.states[1].successors.push_back(0);
    check(!validate(ordered, safe), "Accepted old proof after adding a fair pending cycle.");

    const Graph fair_dead_end{{{true, 1, {1}}, {true, high, {}}}, {0}, 1 | high};
    const auto infeasible = search(fair_dead_end);
    check(infeasible.status == Status::NoFairExecution && validate(fair_dead_end, infeasible),
          "A finite path was treated as a fair execution.");
    check(!validate(split, infeasible), "Accepted exclusion with a different graph size.");

    const Graph separate_initials{{{false, 0, {}}, {true, 0, {1}}}, {0, 1}, 0};
    const auto second = search(separate_initials);
    check(second.status == Status::Violation && second.lasso->path.front() == 1 &&
          validate(separate_initials, second), "Ignored an alternative initial state.");

    const Graph unreachable_cycle{{{false, 0, {0}}, {true, 0, {1}}}, {0}, 0};
    const auto unreachable = search(unreachable_cycle);
    check(unreachable.status == Status::NoViolation && validate(unreachable_cycle, unreachable),
          "Reported a cycle from an unreachable vertex.");
    const Graph empty{{{true, 0, {0}}}, {}, 0};
    const auto no_initial = search(empty);
    check(no_initial.status == Status::NoFairExecution && validate(empty, no_initial),
          "Invented a starting state.");
    const Graph malformed_edge{{{true, 0, {1}}}, {0}, 0};
    const Graph malformed_initial{{{true, 0, {0}}}, {1}, 0};
    for (const auto& graph : {malformed_edge, malformed_initial}) {
        check(search(graph).status == Status::InvalidGraph && !validate(graph, violation),
              "Accepted a graph with an out-of-range vertex.");
    }
    std::cout << "adversarial_checks=16\n";
}

void deep_graph() {
    constexpr Vertex count = 100001;
    Graph graph{std::vector<State>(count), {0}, 0};
    for (Vertex index = 0; index + 1 < count; ++index) {
        graph.states[index] = {true, 0, {index + 1}};
    }
    graph.states.back() = {true, 0, {count - 1}};
    const auto violation = search(graph);
    check(violation.status == Status::Violation && violation.lasso->loop_start == count - 1 &&
          violation.lasso->path.size() == count + 1 && validate(graph, violation), "Long prefix lasso failed.");
    graph.states.back().successors.clear();
    const auto infeasible = search(graph);
    check(infeasible.status == Status::NoFairExecution && validate(graph, infeasible), "Long acyclic proof failed.");
    std::cout << "deep_graph_vertices=100001\n";
}

} // namespace

int main() {
    try {
        exhaustive();
        adversarial();
        deep_graph();
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return EXIT_FAILURE;
    }
}
