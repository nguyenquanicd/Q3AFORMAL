#include "source_graph.hpp"

#include "../replay/property_replay.hpp"
#include "../source_manager/platform_support.hpp"

#include <algorithm>
#include <limits>
#include <map>
#include <set>
#include <stdexcept>

namespace q3a::liveness {
namespace {

using replay::Frame;
using lowering::TIREquation;
using lowering::TypedExpression;

bool inputs_ready(const TypedExpression& expression, const std::set<std::string>& available) {
    if (expression.kind == "signal") return available.count(expression.value) != 0;
    for (const auto& operand : expression.operands) {
        if (!inputs_ready(operand, available)) return false;
    }
    return true;
}

std::vector<const TIREquation*> sorted_combinational(const lowering::TIRModule& model,
                                                    std::set<std::string> available) {
    std::vector<const TIREquation*> result;
    while (result.size() < model.combinational_equations.size()) {
        const auto before = result.size();
        for (const auto& equation : model.combinational_equations) {
            if (available.count(equation.target) == 0 && inputs_ready(equation.expression, available)) {
                result.push_back(&equation);
                available.insert(equation.target);
            }
        }
        if (before == result.size()) throw std::invalid_argument("unresolved combinational equation in liveness model");
    }
    return result;
}

using Layout = std::vector<const lowering::TIRSignal*>;

std::size_t bit_count(const Layout& layout) {
    std::size_t count = 0;
    for (const auto* signal : layout) {
        if (signal->width == 0 || signal->width > 64) throw std::invalid_argument("invalid liveness signal width");
        // Reject before shifting or overflowing the finite enumeration.
        if (signal->width > 30 - count) throw MemoryBudgetExceeded("liveness sample width exceeds enumeration capacity");
        count += static_cast<std::size_t>(signal->width);
    }
    return count;
}

void decode(Frame& frame, const Layout& layout, std::uint64_t packed) {
    for (const auto* signal : layout) {
        frame.at(signal->name) = packed & ((std::uint64_t{1} << signal->width) - 1);
        packed >>= signal->width;
    }
}

bool allowed_sample(const std::vector<const lowering::TIRProperty*>& assumptions, const Frame& frame) {
    for (const auto* property : assumptions) {
        const auto& guard = lowering::antecedent_history_guard(*property);
        if (!guard.empty() && frame.at(guard) == 0) continue;
        for (const auto& term : property->antecedent.terms) {
            if (replay::evaluate_word(term.predicate, frame) == 0) return false;
        }
    }
    return true;
}

} // namespace

SourceGraph build_source_graph(const lowering::TIRModule& model, const Query& query, const MemoryBudget& budget) {
    if (model.clocks.size() > 1 || query.maximum_vertices == 0 || query.maximum_edges == 0 ||
        query.maximum_vertices > kMaximumVertices || query.maximum_edges > kMaximumEdges || query.justice.size() > 64) {
        throw std::invalid_argument("invalid clock profile or liveness limits");
    }
    std::map<std::string, const TIREquation*> next;
    std::set<std::string> driven;
    for (const auto& equation : model.combinational_equations) driven.insert(equation.target);
    for (const auto& equation : model.next_state_equations) next.emplace(equation.target, &equation);
    SourceGraph result;
    Frame frame;
    std::set<std::string> available;
    for (const auto& signal : model.signals) {
        frame.emplace(signal.name, 0);
        if (next.count(signal.name) != 0) {
            result.state_layout.push_back(&signal);
        } else if (driven.count(signal.name) == 0) {
            result.input_layout.push_back(&signal);
        } else {
            continue;
        }
        available.insert(signal.name);
    }

    const auto require_predicate = [&](const std::string& name) {
        for (const auto& signal : model.signals) {
            if (signal.name == name && signal.width == 1) return;
        }
        throw std::invalid_argument("liveness predicate must name a one-bit model signal: " + name);
    };
    const TypedExpression* request = nullptr;
    const TypedExpression* response = nullptr;
    bool nonoverlapped = false;
    if (query.property.empty()) {
        require_predicate(query.request);
        require_predicate(query.response);
    } else {
        if (!query.request.empty() || !query.response.empty()) {
            throw std::invalid_argument("named liveness assertions and direct predicates are mutually exclusive");
        }
        const auto property = std::find_if(model.properties.begin(), model.properties.end(),
            [&](const auto& candidate) { return candidate.name == query.property; });
        if (property == model.properties.end() || property->kind != "assert" ||
            !lowering::is_eventual_response(*property) || !property->consequent ||
            property->antecedent.terms.size() != 1 || property->consequent->terms.size() != 1) {
            throw std::invalid_argument("expected a supported s_eventually assertion: " + query.property);
        }
        request = &property->antecedent.terms.front().predicate;
        response = &property->consequent->terms.front().predicate;
        nonoverlapped = property->implication == "nonoverlapped-eventual";
    }
    std::set<std::string> distinct;
    for (const auto& name : query.justice) {
        require_predicate(name);
        if (!distinct.insert(name).second) throw std::invalid_argument("liveness justice signal is repeated");
    }
    result.graph.required_justice = query.justice.size() == 64 ? std::numeric_limits<std::uint64_t>::max() :
        (std::uint64_t{1} << query.justice.size()) - 1;

    std::vector<const lowering::TIRProperty*> assumptions;
    for (const auto& property : model.properties) {
        if (property.kind != "assume") continue;
        if (property.consequent || (!property.implication.empty() && property.implication != "sequence") ||
            !lowering::is_same_sample_sequence(property.antecedent)) {
            throw std::invalid_argument("liveness requires same-sample scalar assumptions: " + property.name);
        }
        assumptions.push_back(&property);
    }
    result.combinational = sorted_combinational(model, std::move(available));
    const auto state_bits = bit_count(result.state_layout);
    const auto input_bits = bit_count(result.input_layout);
    const auto state_count = std::size_t{1} << state_bits;
    const auto input_count = std::size_t{1} << input_bits;
    if (query.maximum_vertices / 2 / state_count < input_count) {
        throw MemoryBudgetExceeded("liveness sample enumeration exceeds the vertex limit");
    }
    std::vector<const TIREquation*> ordered_next;
    std::set<std::string> initially_zero;
    for (const auto& guard : model.history_guards) {
        initially_zero.insert(guard.state_chain.begin(), guard.state_chain.end());
    }
    std::uint64_t initial_mask = 0;
    std::size_t offset = 0;
    for (const auto* signal : result.state_layout) {
        ordered_next.push_back(next.at(signal->name));
        if (initially_zero.count(signal->name) != 0) {
            initial_mask |= ((std::uint64_t{1} << signal->width) - 1) << offset;
        }
        offset += static_cast<std::size_t>(signal->width);
    }

    struct Group { Vertex first = 0; Vertex end = 0; };
    const auto maximum_samples = 2 * state_count * input_count;
    budget.check(maximum_samples * (sizeof(State) + sizeof(Sample) + 2 * sizeof(Vertex)) +
                 state_count * 2 * sizeof(Group));
    std::vector<Group> groups(2 * state_count);
    std::vector<std::size_t> destination;
    for (std::size_t state = 0; state < state_count; ++state) {
        auto& idle = groups[2 * state];
        auto& waiting = groups[2 * state + 1];
        idle.first = result.samples.size();
        decode(frame, result.state_layout, state);
        for (std::size_t input = 0; input < input_count; ++input) {
            if (input % 256 == 0) budget.check();
            decode(frame, result.input_layout, input);
            for (const auto* equation : result.combinational) {
                frame.at(equation->target) = replay::evaluate_word(equation->expression, frame);
            }
            if (!allowed_sample(assumptions, frame)) continue;
            std::uint64_t following = 0;
            offset = 0;
            for (const auto* equation : ordered_next) {
                following |= replay::evaluate_word(equation->expression, frame) << offset;
                offset += static_cast<std::size_t>(equation->target_width);
            }
            std::uint64_t justice = 0;
            for (std::size_t bit = 0; bit < query.justice.size(); ++bit) {
                justice |= frame.at(query.justice[bit]) << bit;
            }
            const auto vertex = result.samples.size();
            if ((state & initial_mask) == 0) result.graph.initial.push_back(vertex);
            result.graph.states.push_back({false, justice, {}});
            const bool requested = request ? replay::evaluate_word(*request, frame) != 0 :
                frame.at(query.request) != 0;
            const bool unanswered = response ? replay::evaluate_word(*response, frame) == 0 :
                frame.at(query.response) == 0;
            result.samples.push_back({state, input, false, requested, !unanswered});
            const bool wait = requested && (nonoverlapped || unanswered);
            destination.push_back(2 * following + wait);
        }
        idle.end = result.samples.size();
        waiting.first = idle.end;
        for (auto vertex = idle.first; vertex < idle.end; ++vertex) {
            auto sample = result.samples[vertex];
            auto pending = result.graph.states[vertex];
            pending.pending = !sample.response;
            const auto target = destination[vertex] | static_cast<std::size_t>(pending.pending);
            sample.waiting = true;
            result.samples.push_back(sample);
            result.graph.states.push_back(std::move(pending));
            destination.push_back(target);
        }
        waiting.end = result.samples.size();
    }

    std::size_t edges = 0;
    for (const auto group : destination) {
        const auto span = groups.at(group).end - groups.at(group).first;
        if (span > query.maximum_edges - edges) throw MemoryBudgetExceeded("liveness graph exceeds the edge limit");
        edges += span;
    }
    // Both the graph and the search's reverse adjacency can hold all edges.
    budget.check(edges * 3 * sizeof(Vertex));
    for (Vertex vertex = 0; vertex < destination.size(); ++vertex) {
        if (vertex % 256 == 0) budget.check();
        const auto group = groups[destination[vertex]];
        auto& successors = result.graph.states[vertex].successors;
        successors.reserve(group.end - group.first);
        for (auto target = group.first; target < group.end; ++target) successors.push_back(target);
    }
    return result;
}

void reconstruct_sample(const SourceGraph& source, Vertex vertex, replay::Frame& frame) {
    const auto& sample = source.samples.at(vertex);
    decode(frame, source.state_layout, sample.packed_state);
    decode(frame, source.input_layout, sample.packed_input);
    for (const auto* equation : source.combinational) {
        frame.at(equation->target) = replay::evaluate_word(equation->expression, frame);
    }
}

} // namespace q3a::liveness
