#include "state_transition.hpp"
#include "../source_manager/platform_support.hpp"

#include <algorithm>
#include <limits>
#include <set>

namespace q3a::lowering {
namespace {

using frontend::SourceLocation;

TypedExpression reference(const TIRSignal& signal, const SourceLocation& location) {
    return {"signal", signal.name, signal.width, signal.is_signed, location, {}};
}

TypedExpression compare_address(const TypedExpression& address, const char* operation,
                                std::uint64_t boundary, const SourceLocation& location) {
    TypedExpression constant{"constant", std::to_string(boundary), address.width, false, location, {}};
    return {"binary", operation, 1, false, location, {address, std::move(constant)}};
}

TypedExpression conjunction(TypedExpression left, TypedExpression right, const SourceLocation& location) {
    return {"binary", "&&", 1, false, location, {std::move(left), std::move(right)}};
}

TypedExpression select(TypedExpression condition, TypedExpression when_true,
                       TypedExpression when_false, const SourceLocation& location) {
    TypedExpression result{"conditional", "?:", when_true.width, when_true.is_signed, location, {}};
    result.operands.reserve(3);
    result.operands.push_back(std::move(condition));
    result.operands.push_back(std::move(when_true));
    result.operands.push_back(std::move(when_false));
    return result;
}

void check_access(const MemoryAccess& access, std::uint64_t last_address) {
    const auto width = access.address.width;
    if (access.enable.width != 1 || width == 0 || width > 64 || access.address.is_signed ||
        (width < 64 && (last_address >> width) != 0)) {
        throw LoweringError(access.location, "memory access requires a one-bit enable and an unsigned address that represents the declared range");
    }
}

TypedExpression legal_address(const MemoryAccess& access, std::uint64_t first, std::uint64_t last) {
    return conjunction(compare_address(access.address, ">=", first, access.location),
                       compare_address(access.address, "<=", last, access.location), access.location);
}

TypedExpression access_safety(const MemoryAccess& access, TypedExpression address_is_legal) {
    TypedExpression disabled{"unary", "!", 1, false, access.location, {access.enable}};
    return {"binary", "||", 1, false, access.location,
            {std::move(disabled), std::move(address_is_legal)}};
}

TypedExpression read_prestate(const std::vector<TIRSignal>& cells, std::uint64_t first_address,
                              std::size_t begin, std::size_t end, const MemoryAccess& read,
                              const MemoryBudget* budget) {
    if (end - begin == 1) {
        if (budget && begin % 256 == 0) budget->check();
        return reference(cells[begin], read.location);
    }
    const auto pivot = begin + (end - begin) / 2;
    return select(compare_address(read.address, "<", first_address + pivot, read.location),
                  read_prestate(cells, first_address, begin, pivot, read, budget),
                  read_prestate(cells, first_address, pivot, end, read, budget), read.location);
}

TIRProperty access_property(const TIRModule& model, std::string name, const std::string& clock,
                            const TypedExpression& predicate) {
    if (name.empty() || std::any_of(model.properties.begin(), model.properties.end(),
            [&](const auto& property) { return property.name == name; })) {
        throw LoweringError(predicate.location, "memory range property name is empty or already declared");
    }
    if (predicate.width != 1) {
        throw LoweringError(predicate.location, "memory range property requires a one-bit predicate");
    }
    TIRProperty property;
    property.name = std::move(name);
    property.kind = "assert";
    property.clock = clock;
    property.implication = "sequence";
    property.location = predicate.location;
    property.antecedent.terms.push_back({0, 1, 1, predicate, predicate.location});
    property.antecedent.automaton = {2, 0, 1, {{0, 1, 0, 1, 1, predicate, predicate.location}}};
    property.antecedent.path_lengths = {1};
    return property;
}

} // namespace

TIREquation sampled_assignment(const TIRSignal& target, TypedExpression enable,
                                TypedExpression value, frontend::SourceLocation location) {
    if (target.name.empty() || target.width == 0 || target.width > 64 || enable.width != 1 ||
        value.width != target.width || value.is_signed != target.is_signed ||
        (target.role != "state" && target.role != "history_data" && target.role != "history_valid")) {
        throw LoweringError(location, "sampled assignment requires typed state, a one-bit enable and a matching update");
    }
    auto next = select(std::move(enable), std::move(value), reference(target, location), location);
    return {target.name, target.width, std::move(next), std::move(location)};
}

ExactMemoryTransition exact_read_old_memory(
    std::uint64_t first_address, const std::vector<TIRSignal>& cells,
    const MemoryAccess& read, const MemoryAccess& write, TypedExpression write_value,
    const TIRSignal& read_target, const TIRSignal& invalid_read_value,
    const MemoryBudget* budget) {
    if (cells.empty() || cells.size() - 1 > std::numeric_limits<std::uint64_t>::max() - first_address) {
        throw LoweringError(read.location, "memory requires a nonempty representable address range");
    }
    const auto last_address = first_address + (cells.size() - 1);
    check_access(read, last_address);
    check_access(write, last_address);
    if (read_target.role != "state" || invalid_read_value.role != "input" || invalid_read_value.name.empty() ||
        read_target.name == invalid_read_value.name || read_target.width != write_value.width ||
        read_target.is_signed != write_value.is_signed || read_target.width != invalid_read_value.width ||
        read_target.is_signed != invalid_read_value.is_signed) {
        throw LoweringError(read.location, "memory data must match the read state and the distinct invalid-read input");
    }

    const auto read_address_valid = legal_address(read, first_address, last_address);
    ExactMemoryTransition result;
    if (cells.size() >= result.equations.max_size()) {
        throw MemoryBudgetExceeded("memory transition equation count exceeds the vector limit");
    }
    const auto equation_count = cells.size() + 1;
    if (budget) budget->check(equation_count * sizeof(TIREquation));
    result.equations.reserve(equation_count);
    result.read_in_range = access_safety(read, read_address_valid);
    result.write_in_range = access_safety(write, legal_address(write, first_address, last_address));
    std::set<std::string> names{read_target.name, invalid_read_value.name};
    for (std::size_t index = 0; index < cells.size(); ++index) {
        if (budget && index % 256 == 0) budget->check();
        const auto& cell = cells[index];
        if (!names.insert(cell.name).second || cell.role != "state") {
            throw LoweringError(write.location, "memory cells must be distinct state signals");
        }
        auto write_cell = conjunction(write.enable,
            compare_address(write.address, "==", first_address + index, write.location), write.location);
        result.equations.push_back(sampled_assignment(cell, std::move(write_cell), write_value, write.location));
    }

    auto observed = select(read_address_valid, read_prestate(cells, first_address, 0, cells.size(), read, budget),
                           reference(invalid_read_value, read.location), read.location);
    result.equations.push_back(sampled_assignment(read_target, read.enable, std::move(observed), read.location));
    return result;
}

std::array<TIRProperty, 2> memory_range_assertions(
    const TIRModule& model, const ExactMemoryTransition& transition, const std::string& clock,
    std::string read_label, std::string write_label) {
    if (model.clocks.size() != 1 || clock.empty() || model.clocks.front() != clock) {
        throw LoweringError(transition.read_in_range.location, "memory range properties require the model's single sampling clock");
    }
    if (read_label == write_label) {
        throw LoweringError(transition.write_in_range.location, "memory range properties require distinct names");
    }
    return {access_property(model, std::move(read_label), clock, transition.read_in_range),
            access_property(model, std::move(write_label), clock, transition.write_in_range)};
}

} // namespace q3a::lowering
