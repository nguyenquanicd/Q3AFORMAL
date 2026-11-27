#include "event_mask_source.hpp"
#include "state_transition.hpp"
#include "sequence_monitor.hpp"

#include <algorithm>
#include <set>

namespace q3a::lowering {
namespace {

void reject_sampled_clock_data(const TypedExpression& expression, const std::set<std::string>& clocks) {
    if (expression.kind == "signal" && clocks.count(expression.value)) {
        throw LoweringError(expression.location, "event-mask clock cannot also be read as data: " + expression.value,
            frontend::InputDiagnosticKind::Unsupported);
    }
    for (const auto& operand : expression.operands) reject_sampled_clock_data(operand, clocks);
}

} // namespace

EventMaskModel lower_free_event_mask(const std::vector<frontend::SyntaxUnit>& units,
                                    const elaboration::ElaborationResult& design) {
    EventMaskModel result;
    auto& model = result.transition;
    model = lower_event_domain_equations(units, design, result.state_domains);
    if (model.clocks.empty() || model.next_state_equations.size() != result.state_domains.size()) {
        throw std::invalid_argument("event-mask RTL needs clocked state with a unique owner per equation");
    }
    const std::set<std::string> clocks(model.clocks.begin(), model.clocks.end());
    for (const auto* equations : {&model.combinational_equations, &model.next_state_equations}) {
        for (const auto& equation : *equations) reject_sampled_clock_data(equation.expression, clocks);
    }

    std::map<std::string, TIRSignal> signals;
    for (const auto& signal : model.signals) signals.emplace(signal.name, signal);
    if (signals.count(kGlobalEventStep)) {
        throw std::invalid_argument("the global event step name conflicts with an RTL signal");
    }
    model.signals.erase(std::remove_if(model.signals.begin(), model.signals.end(),
        [&](const auto& signal) { return clocks.count(signal.name) != 0; }), model.signals.end());

    // Retain source clock identity in the mapping and in each input name.
    for (const auto& domain : model.clocks) {
        const auto& clock = signals.at(domain);
        auto edge_name = "__q3a_event_" + domain;
        if (signals.count(edge_name)) {
            throw LoweringError(clock.location, "event input name conflicts with an RTL signal: " + edge_name);
        }
        result.edge_inputs.emplace(domain, edge_name);
        model.signals.emplace_back(std::move(edge_name), 1, false, "input", clock.location);
    }
    for (auto& equation : model.next_state_equations) {
        const auto& domain = result.state_domains.at(equation.target);
        TypedExpression enable{"signal", result.edge_inputs.at(domain), 1, false,
            signals.at(domain).location, {}};
        equation = sampled_assignment(signals.at(equation.target), std::move(enable),
                                      std::move(equation.expression), equation.location);
    }
    std::size_t monitor_signals = 0;
    for (auto& property : model.properties) {
        const auto domain = property.clock;
        result.property_domains.emplace(property.name, domain);
        auto& sequence = property.antecedent;
        if (property.consequent || !is_same_sample_sequence(sequence)) {
            for (const auto& term : sequence.terms) reject_sampled_clock_data(term.predicate, clocks);
            if (property.consequent) {
                for (const auto& term : property.consequent->terms) reject_sampled_clock_data(term.predicate, clocks);
            }
            property.clock = kGlobalEventStep;
            const auto start = model.next_state_equations.size();
            std::string pending;
            lower_sequence_monitor(model, property, monitor_signals, 128, result.edge_inputs.at(domain), &pending);
            if (!pending.empty()) result.pending_at_boundary.emplace(property.name, std::move(pending));
            for (std::size_t i = start; i < model.next_state_equations.size(); ++i) {
                result.state_domains.emplace(model.next_state_equations[i].target, domain);
            }
            continue;
        }
        auto predicate = std::move(sequence.terms.front().predicate);
        reject_sampled_clock_data(predicate, clocks);
        for (std::size_t index = 1; index < sequence.terms.size(); ++index) {
            auto term = std::move(sequence.terms[index].predicate);
            reject_sampled_clock_data(term, clocks);
            predicate = {"binary", "&&", 1, false, property.location, {std::move(predicate), std::move(term)}};
        }
        TypedExpression event{"signal", result.edge_inputs.at(property.clock), 1, false, property.location, {}};
        const char* operation = "&&";
        if (property.kind != "cover") {
            event = {"unary", "!", 1, false, property.location, {std::move(event)}};
            operation = "||";
        }
        predicate = {"binary", operation, 1, false, property.location, {std::move(event), std::move(predicate)}};
        sequence.terms = {{0, 1, 1, predicate, property.location}};
        sequence.automaton = {2, 0, 1, {{0, 1, 0, 1, 1, std::move(predicate), property.location}}};
        sequence.path_lengths = {1};
        property.clock = kGlobalEventStep;
    }
    for (auto& guard : model.history_guards) guard.clock = kGlobalEventStep;
    model.semantic_profile = kFreeEventMaskProfile;
    model.clocks.assign(1, kGlobalEventStep);
    return result;
}

} // namespace q3a::lowering
