#include "event_window.hpp"

#include <algorithm>

namespace q3a::sat {
namespace {

bool holds(Literal literal, const std::vector<std::int8_t>& assignment) {
    const auto index = static_cast<std::size_t>(literal < 0 ? -literal : literal);
    const auto value = assignment.at(index);
    return literal > 0 ? value == 1 : value == 0;
}

} // namespace

EventWindowResult classify_event_window(const lowering::EventMaskModel& model,
    const std::string& property, TransitionCnfEncoder& encoder, Solver& solver) {
    const auto& properties = model.transition.properties;
    const auto target = std::find_if(properties.begin(), properties.end(),
        [&](const auto& check) { return check.name == property; });
    if (target == properties.end() || (target->kind != "assert" && target->kind != "cover") ||
        model.transition.semantic_profile != lowering::kFreeEventMaskProfile || encoder.frames().empty()) {
        throw std::invalid_argument("event window requires an encoded source-bound assertion or cover");
    }

    EventWindowResult result;
    const auto feasible = solver.solve().status;
    if (feasible != Status::Satisfiable) {
        if (feasible == Status::Unsatisfiable) result.outcome = EventWindowOutcome::Inconsistent;
        return result;
    }
    std::vector<Literal> candidates;
    std::vector<std::size_t> candidate_frames;
    if (target->kind == "cover") {
        auto query = encoder.add_cover_hit(property);
        candidates = std::move(query.hit_literals);
        candidate_frames = std::move(query.hit_frames);
    } else {
        auto query = encoder.add_assertion_violation(property);
        candidates = std::move(query.violation_literals);
        candidate_frames = std::move(query.violation_frames);
    }
    std::vector<Literal> pending_assumptions;
    const auto& last = encoder.frames().back();
    for (const auto& check : properties) {
        if (check.kind != "assume") continue;
        const auto pending = model.pending_at_boundary.find(check.name);
        if (pending != model.pending_at_boundary.end()) {
            pending_assumptions.push_back(last.at(pending->second).at(0));
        }
    }
    if (!candidates.empty()) {
        auto answer = solver.solve_with_temporary_clause(candidates);
        if (answer.status == Status::Unknown) return result;
        if (answer.status == Status::Satisfiable) {
            const auto first = std::find_if(candidates.begin(), candidates.end(),
                [&](const auto candidate) { return holds(candidate, answer.assignment); });
            if (first == candidates.end()) throw std::runtime_error("event window witness lacks a candidate");
            result.outcome = EventWindowOutcome::Witness;
            result.witness_frame = candidate_frames.at(static_cast<std::size_t>(first - candidates.begin()));
            result.witness_has_open_assumption = std::any_of(pending_assumptions.begin(), pending_assumptions.end(),
                [&](const auto pending) { return holds(pending, answer.assignment); });
            result.assignment = std::move(answer.assignment);
            return result;
        }
    }
    auto pending = model.pending_at_boundary.find(property);
    if (pending != model.pending_at_boundary.end()) pending_assumptions.push_back(last.at(pending->second).at(0));
    if (pending_assumptions.empty()) {
        result.outcome = EventWindowOutcome::Complete;
    } else {
        const auto boundary = solver.solve_with_temporary_clause(pending_assumptions).status;
        if (boundary == Status::Satisfiable) result.outcome = EventWindowOutcome::Incomplete;
        if (boundary == Status::Unsatisfiable) result.outcome = EventWindowOutcome::Complete;
    }
    return result;
}

} // namespace q3a::sat
