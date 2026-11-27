#include "trace_capture.hpp"

#include <iomanip>
#include <map>
#include <ostream>
#include <set>
#include <stdexcept>

namespace q3a::trace {
namespace {

using Names = std::set<std::string>;
using Dependencies = std::vector<std::string>;

void inputs(const lowering::TypedExpression& expression, Dependencies& names) {
    if (expression.kind == "signal" || expression.kind == "history_ref") {
        names.push_back(expression.value);
    }
    for (const auto& operand : expression.operands) inputs(operand, names);
}

void control_inputs(const lowering::TypedExpression& expression, Dependencies& names) {
    if (expression.kind == "conditional" && expression.operands.size() == 3) {
        inputs(expression.operands.front(), names);
        control_inputs(expression.operands[1], names);
        control_inputs(expression.operands[2], names);
        return;
    }
    for (const auto& operand : expression.operands) control_inputs(operand, names);
}

void property_inputs(const lowering::TIRProperty& property, Dependencies& names) {
    const auto add_sequence = [&](const lowering::TIRSequence& sequence) {
        for (const auto& transition : sequence.automaton.transitions) inputs(transition.predicate, names);
    };
    add_sequence(property.antecedent);
    if (property.consequent) add_sequence(*property.consequent);
    for (const auto* name : {&property.clock, &lowering::antecedent_history_guard(property),
                            &lowering::consequent_history_guard(property)}) {
        if (!name->empty()) names.push_back(*name);
    }
}

Names dependency_slice(const lowering::TIRModule& model,
                       const lowering::TIRProperty& property) {
    std::map<std::string, const lowering::TypedExpression*> drivers;
    Dependencies pending = model.clocks;
    property_inputs(property, pending);
    for (const auto& assumption : model.properties) {
        if (assumption.kind == "assume") property_inputs(assumption, pending);
    }
    for (const auto& equation : model.combinational_equations) {
        drivers.emplace(equation.target, &equation.expression);
    }
    for (const auto& equation : model.next_state_equations) {
        drivers.emplace(equation.target, &equation.expression);
        control_inputs(equation.expression, pending);
    }
    Names selected;
    while (!pending.empty()) {
        auto name = std::move(pending.back());
        pending.pop_back();
        if (!selected.insert(name).second) continue;
        const auto driver = drivers.find(name);
        if (driver != drivers.end()) inputs(*driver->second, pending);
    }
    return selected;
}

} // namespace

PropertySignalIndex::PropertySignalIndex(const lowering::TIRModule& model) {
    for (const auto& signal : model.signals) {
        if (signal.role == "history_data" || signal.role == "history_valid") {
            history_.emplace(signal.name, nullptr);
        }
    }
    for (const auto& equation : model.next_state_equations) {
        const auto found = history_.find(equation.target);
        if (found != history_.end()) found->second = &equation.expression;
    }
}

PropertySignals PropertySignalIndex::for_property(const lowering::TIRProperty& property) const {
    Dependencies pending;
    property_inputs(property, pending);
    const Names modeled(pending.begin(), pending.end());
    Names visited;
    Names rtl;
    while (!pending.empty()) {
        auto name = std::move(pending.back());
        pending.pop_back();
        if (!visited.insert(name).second) continue;
        const auto generated = history_.find(name);
        if (generated == history_.end()) rtl.insert(std::move(name));
        else if (generated->second) inputs(*generated->second, pending);
    }
    return {{rtl.begin(), rtl.end()}, {modeled.begin(), modeled.end()}};
}

void write_property_signals(std::ostream& output, const PropertySignals& signals) {
    const auto array = [&](const std::vector<std::string>& names) {
        output << '[';
        for (std::size_t index = 0; index < names.size(); ++index) {
            if (index) output << ',';
            output << std::quoted(names[index]);
        }
        output << ']';
    };
    output << "{\"rtl\":";
    array(signals.rtl);
    output << ",\"model\":";
    array(signals.model);
    output << '}';
}

CaptureSignals select_capture_signals(const lowering::TIRModule& model,
                                      const lowering::TIRProperty& property,
                                      const CaptureRequest& request) {
    Names requested;
    for (const auto& name : request.extra) {
        if (!requested.insert(name).second) {
            throw std::invalid_argument("duplicate trace signal '" + name + "'");
        }
    }
    const auto slice = request.all ? Names{} : dependency_slice(model, property);
    CaptureSignals result;
    for (const auto& signal : model.signals) {
        const bool explicit_signal = requested.erase(signal.name) != 0;
        const bool top_port = signal.name.find('.') == std::string::npos &&
            (signal.role == "input" || signal.role == "output");
        if (request.all || explicit_signal || top_port || signal.role == "state" ||
            slice.count(signal.name)) {
            result.push_back(&signal);
        }
    }
    if (!requested.empty()) {
        throw std::invalid_argument("unknown trace signal '" + *requested.begin() + "'");
    }
    return result;
}

void write_capture_manifest(std::ostream& output, const std::string& property,
                            const CaptureRequest& request, const CaptureSignals& signals) {
    output << "{\"schema\":\"Q3A-WAVEFORM-CAPTURE-1\",\"property\":" << std::quoted(property)
           << ",\"all\":" << (request.all ? "true" : "false") << ",\"requested\":[";
    for (std::size_t i = 0; i < request.extra.size(); ++i) {
        if (i) output << ',';
        output << std::quoted(request.extra[i]);
    }
    output << "],\"signals\":[";
    for (std::size_t i = 0; i < signals.size(); ++i) {
        if (i) output << ',';
        const auto& signal = *signals[i];
        output << "{\"name\":" << std::quoted(signal.name) << ",\"width\":" << signal.width
               << ",\"role\":" << std::quoted(signal.role) << '}';
    }
    output << "]}\n";
}

} // namespace q3a::trace
