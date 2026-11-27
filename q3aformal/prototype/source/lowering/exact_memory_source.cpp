#include "state_transition.hpp"
#include "../source_manager/platform_support.hpp"

#include <algorithm>
#include <iterator>
#include <map>
#include <set>

namespace q3a::lowering {
namespace {

using frontend::ExpressionSpan;
using frontend::SourceLocation;
using frontend::StatementKind;
using frontend::StatementSyntax;
using frontend::SyntaxUnit;
using frontend::Token;

[[noreturn]] void reject(const SourceLocation& location, const char* message) {
    throw LoweringError(location, message, frontend::InputDiagnosticKind::Unsupported);
}

const Token& bare_name(const SyntaxUnit& unit, ExpressionSpan span) {
    const auto& token = unit.tokens.at(span.first_token);
    if (span.after_last_token - span.first_token != 1 || token.kind != frontend::TokenKind::Identifier) {
        reject(token.location, "development memory access requires a bare signal name");
    }
    return token;
}

const Token& subscript(const SyntaxUnit& unit, ExpressionSpan span, const std::string& memory) {
    const auto& token = unit.tokens.at(span.first_token);
    if (span.after_last_token - span.first_token != 4 || token.text != memory ||
        unit.tokens.at(span.first_token + 1).text != "[" || unit.tokens.at(span.first_token + 3).text != "]") {
        reject(token.location, "development memory access requires one indexed memory element");
    }
    return bare_name(unit, {span.first_token + 2, span.first_token + 3});
}

const StatementSyntax& enabled_assignment(const StatementSyntax& branch) {
    if (branch.kind != StatementKind::If || !branch.expression || branch.body.size() != 1 ||
        !branch.else_body.empty()) {
        reject(branch.location, "development memory requires independent read and write guards");
    }
    const auto* assignment = &branch.body.front();
    if (assignment->kind == StatementKind::Block && assignment->body.size() == 1) {
        assignment = &assignment->body.front();
    }
    if (assignment->kind != StatementKind::Assignment || !assignment->lvalue ||
        !assignment->assignment || !assignment->nonblocking) {
        reject(assignment->location, "development memory requires one nonblocking assignment per guard");
    }
    return *assignment;
}

template <typename Value>
void reserve_additional(std::vector<Value>& values, std::uint64_t added, const MemoryBudget* budget) {
    if (added > values.max_size() - values.size()) {
        throw MemoryBudgetExceeded("memory model vector exceeds its size limit");
    }
    const auto capacity = values.size() + static_cast<std::size_t>(added);
    if (capacity <= values.capacity()) return;
    if (budget) budget->check(capacity * sizeof(Value));
    values.reserve(capacity);
}

TIRSignal convert_signal(const elaboration::TypedSignal& signal, std::string role) {
    return {signal.name, signal.width, signal.is_signed, std::move(role), signal.location,
            signal.packed_left_index, signal.packed_right_index};
}

bool references_memory(const SyntaxUnit& unit, const StatementSyntax& statement, const std::string& memory) {
    const auto contains = [&](const std::optional<ExpressionSpan>& span) {
        return span && std::any_of(unit.tokens.begin() + span->first_token,
                                  unit.tokens.begin() + span->after_last_token,
            [&](const Token& token) { return token.kind == frontend::TokenKind::Identifier && token.text == memory; });
    };
    const auto nested = [&](const StatementSyntax& item) { return references_memory(unit, item, memory); };
    if (contains(statement.expression) || contains(statement.lvalue) || contains(statement.assignment) ||
        std::any_of(statement.body.begin(), statement.body.end(), nested) ||
        std::any_of(statement.else_body.begin(), statement.else_body.end(), nested)) return true;
    return std::any_of(statement.case_items.begin(), statement.case_items.end(), [&](const auto& item) {
        return std::any_of(item.labels.begin(), item.labels.end(), contains) ||
            std::any_of(item.statements.begin(), item.statements.end(), nested);
    });
}

TypedExpression memory_operand(const std::map<std::string, const TIRSignal*>& driven,
                               const Token& name, const std::string& clock) {
    const auto found = driven.find(name.text);
    if (found == driven.end() || name.text == clock) {
        reject(name.location, "development memory operand requires a driven scalar or packed signal");
    }
    return {"signal", name.text, found->second->width, found->second->is_signed, name.location, {}};
}

} // namespace

TIRModule lower_exact_memory_source(const SyntaxUnit& unit, const elaboration::ElaborationResult& design,
                                    std::uint64_t max_cells, const MemoryBudget* budget) {
    const auto selected = std::find_if(unit.modules.begin(), unit.modules.end(),
        [&](const auto& module) { return module.name == design.top.name; });
    if (selected == unit.modules.end()) {
        throw std::invalid_argument("development memory source does not contain the elaborated top");
    }
    if (design.top.memories.size() != 1 || selected->memories.size() != 1 ||
        selected->memories.front().element.name != design.top.memories.front().element.name ||
        !selected->generate_items.empty() || !selected->instances.empty() || !unit.binds.empty() ||
        !unit.standalone_declarations.empty() || !unit.standalone_checks.empty()) {
        reject(selected->location, "development memory lowering requires one flat module with one memory");
    }
    const auto& memory = design.top.memories.front();
    const auto first = std::min(memory.left, memory.right);
    const auto last = std::max(memory.left, memory.right);
    if (last - first >= max_cells) {
        reject(memory.element.location, "development memory exceeds the caller's cell budget");
    }

    const auto uses_memory = [&](const auto& candidate) {
        return references_memory(unit, candidate.body, memory.element.name);
    };
    const auto selected_process = std::find_if(selected->processes.begin(), selected->processes.end(), uses_memory);
    if (selected_process == selected->processes.end() ||
        std::any_of(std::next(selected_process), selected->processes.end(), uses_memory)) {
        reject(memory.element.location, "development memory requires exactly one process with memory accesses");
    }
    const auto& process = *selected_process;
    if (process.kind != frontend::ProcessKind::AlwaysFF || !process.clock ||
        process.body.kind != StatementKind::Block || process.body.body.size() != 2) {
        reject(process.location, "development memory requires one clocked process with two accesses");
    }
    const auto& clock = *process.clock;
    std::map<std::string, const elaboration::TypedSignal*> ports;
    for (const auto& port : design.top.ports) ports.emplace(port.name, &port);
    const auto clock_port = ports.find(clock);
    if (clock_port == ports.end() || clock_port->second->width != 1 ||
        clock_port->second->direction != frontend::PortDirection::Input) {
        reject(process.location, "development memory clock must be a one-bit input");
    }

    const auto& a = process.body.body[0];
    const auto& b = process.body.body[1];
    const auto& assignment_a = enabled_assignment(a);
    const auto& assignment_b = enabled_assignment(b);
    const bool write_first = unit.tokens.at(assignment_a.lvalue->first_token).text == memory.element.name;
    const auto& write_branch = write_first ? a : b;
    const auto& read_branch = write_first ? b : a;
    const auto& write = write_first ? assignment_a : assignment_b;
    const auto& read = write_first ? assignment_b : assignment_a;

    const auto& read_output = bare_name(unit, *read.lvalue);
    const auto output = ports.find(read_output.text);
    if (output == ports.end() || output->second->direction != frontend::PortDirection::Output) {
        reject(read_output.location, "development memory read target must be a declared output");
    }
    const auto read_target = convert_signal(*output->second, "state");
    // Lower the ordinary RTL with the memory read target as a temporary input.
    // Its original role and exact registered equation are restored below.
    auto scalar_source = unit;
    auto& scalar_module = scalar_source.modules.at(selected - unit.modules.begin());
    scalar_module.memories.clear();
    scalar_module.processes.erase(scalar_module.processes.begin() +
        (selected_process - selected->processes.begin()));
    scalar_module.property_declarations.clear();
    scalar_module.property_checks.clear();
    auto scalar_design = design;
    scalar_design.top.memories.clear();
    std::find_if(scalar_design.top.ports.begin(), scalar_design.top.ports.end(),
        [&](const auto& port) { return port.name == read_target.name; })->direction = frontend::PortDirection::Input;
    std::vector<SyntaxUnit> scalar_units;
    scalar_units.push_back(std::move(scalar_source));
    auto model = lower_continuous_assignments(scalar_units, scalar_design);
    if (std::any_of(model.clocks.begin(), model.clocks.end(), [&](const auto& other) { return other != clock; })) {
        reject(process.location, "development memory and scalar helper state must use the same positive-edge clock");
    }
    model.clocks.assign(1, clock);

    std::set<std::string> driven_targets;
    for (const auto& equation : model.combinational_equations) driven_targets.insert(equation.target);
    for (const auto& equation : model.next_state_equations) driven_targets.insert(equation.target);
    std::map<std::string, const TIRSignal*> driven;
    for (auto& signal : model.signals) {
        if (signal.name == read_target.name) signal = read_target;
        if (signal.name == read_target.name || signal.role == "input" || driven_targets.count(signal.name)) {
            driven.emplace(signal.name, &signal);
        } else {
            reject(signal.location, "development memory scalar helper signal has no driver");
        }
    }
    const auto read_address = subscript(unit, *read.assignment, memory.element.name);
    const auto write_address = subscript(unit, *write.lvalue, memory.element.name);
    const MemoryAccess read_access{memory_operand(driven, bare_name(unit, *read_branch.expression), clock),
        memory_operand(driven, read_address, clock), read.location};
    const MemoryAccess write_access{memory_operand(driven, bare_name(unit, *write_branch.expression), clock),
        memory_operand(driven, write_address, clock), write.location};
    auto write_value = memory_operand(driven, bare_name(unit, *write.assignment), clock);

    std::vector<TIRSignal> cells;
    const auto count = last - first + 1;
    reserve_additional(cells, count, budget);
    for (std::uint64_t offset = 0; offset < count; ++offset) {
        if (budget && offset % 256 == 0) budget->check();
        auto cell = convert_signal(memory.element, "state");
        cell.name += "[" + std::to_string(first + offset) + "]";
        cells.push_back(std::move(cell));
    }
    auto invalid = convert_signal(memory.element, "input");
    invalid.name = "__q3a_invalid_read_" + memory.element.name;
    if (driven.count(invalid.name) != 0) {
        reject(memory.element.location, "development memory invalid-read input name collides with a port");
    }
    auto transition = exact_read_old_memory(first, cells, read_access, write_access,
                                            std::move(write_value), read_target, invalid, budget);
    reserve_additional(model.signals, count + 1, budget);
    model.signals.insert(model.signals.end(), std::make_move_iterator(cells.begin()),
        std::make_move_iterator(cells.end()));
    model.signals.push_back(std::move(invalid));
    const auto properties = memory_range_assertions(model, transition, clock,
        kMemoryReadRange, kMemoryWriteRange);
    if (model.next_state_equations.empty()) {
        model.next_state_equations = std::move(transition.equations);
    } else {
        reserve_additional(model.next_state_equations, transition.equations.size(), budget);
        model.next_state_equations.insert(model.next_state_equations.end(),
            std::make_move_iterator(transition.equations.begin()), std::make_move_iterator(transition.equations.end()));
    }
    model.properties.insert(model.properties.end(), properties.begin(), properties.end());
    attach_exact_memory_source_properties(model, unit, *selected, design.top);
    return model;
}

} // namespace q3a::lowering
