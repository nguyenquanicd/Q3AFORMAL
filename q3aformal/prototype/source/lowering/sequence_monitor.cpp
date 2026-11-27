#include "sequence_monitor.hpp"
#include "state_transition.hpp"
#include "../source_manager/platform_support.hpp"

#include <algorithm>
#include <map>
#include <unordered_set>

namespace q3a::lowering {
namespace {
constexpr std::size_t kMaxMonitorSignals = 8192;

std::optional<std::uint64_t> fixed_sequence_horizon(const lowering::TIRSequence& sequence) {
    const auto horizon = lowering::bounded_scalar_sequence_horizon(sequence);
    if (!horizon || lowering::sequence_paths(sequence).size() != 1 ||
        std::any_of(sequence.terms.begin(), sequence.terms.end(),
            [](const auto& term) { return term.repeat_min != term.repeat_max; })) {
        return std::nullopt;
    }
    return horizon;
}

class SequenceMonitor {
public:
    SequenceMonitor(lowering::TIRModule& model, lowering::TIRProperty& property,
                    std::size_t& generated, std::string_view sample_enable, std::string* boundary_pending)
        : model_(model), property_(property), generated_(generated), sample_enable_(sample_enable), boundary_pending_(boundary_pending) {
        for (const auto& signal : model.signals) names_.insert(signal.name);
    }

    void lower(std::uint64_t antecedent_horizon, std::uint64_t consequent_horizon) {
        const auto antecedent_guard = guard(lowering::antecedent_history_guard(property_));
        auto match = sequence_end(property_.antecedent, antecedent_guard, property_.consequent.has_value() || property_.kind == "cover");
        if (property_.consequent) {
            const auto delta = property_.implication == "nonoverlapped" ? 1U : 0U;
            auto trigger = delay(std::move(match), delta + consequent_horizon, true);
            const auto& guard_name = lowering::consequent_history_guard(property_);
            if (!guard_name.empty()) {
                trigger = binary("&&", std::move(trigger), delay(guard(guard_name), consequent_horizon));
            }
            match = sequence_end(*property_.consequent, guard(""));
            match = property_.kind != "cover"
                ? implication(std::move(trigger), std::move(match))
                : binary("&&", std::move(trigger), std::move(match));
        } else if (property_.kind != "cover") {
            match = implication(delay(antecedent_guard, antecedent_horizon, true), std::move(match));
        }
        replace_property(std::move(match));
    }

    void lower_ranges(std::uint64_t antecedent_horizon, std::uint64_t consequent_horizon) {
        const auto antecedent_guard = guard(lowering::antecedent_history_guard(property_));
        const bool obligation = property_.kind != "cover";
        if (property_.consequent) {
            const auto delta = property_.implication == "nonoverlapped" ? 1U : 0U;
            // At each sample, all antecedents ending there launch the same
            // consequent, even when they started at different samples.
            auto trigger = delay(matches(property_.antecedent, antecedent_guard, std::nullopt, true), delta, true);
            const auto& guard_name = lowering::consequent_history_guard(property_);
            if (!guard_name.empty()) {
                trigger = binary("&&", std::move(trigger), guard(guard_name));
            }
            if (obligation) {
                replace_property(implication(delay(std::move(trigger), consequent_horizon, true),
                    matches(*property_.consequent, guard(""), consequent_horizon)));
            } else {
                replace_property(matches(*property_.consequent, std::move(trigger), std::nullopt, true));
            }
        } else if (obligation) {
            replace_property(implication(delay(antecedent_guard, antecedent_horizon, true),
                matches(property_.antecedent, antecedent_guard, antecedent_horizon)));
        } else {
            replace_property(matches(property_.antecedent, antecedent_guard, std::nullopt, true));
        }
    }

private:
    void replace_property(TypedExpression match) {
        if (boundary_pending_ && !pending_terms_.empty()) {
            while (pending_terms_.size() > 1) {
                std::vector<TypedExpression> next;
                for (std::size_t i = 0; i < pending_terms_.size(); i += 2) {
                    auto left = std::move(pending_terms_[i]);
                    if (i + 1 < pending_terms_.size()) {
                        left = binary("||", std::move(left), std::move(pending_terms_[i + 1]));
                    }
                    next.push_back(std::move(left));
                }
                pending_terms_ = std::move(next);
            }
            *boundary_pending_ = share(std::move(pending_terms_.front())).value;
        }
        const auto& location = property_.location;
        if (!sample_enable_.empty()) {
            auto enable = guard(std::string(sample_enable_));
            match = property_.kind == "cover" ? binary("&&", std::move(enable), std::move(match))
                                               : implication(std::move(enable), std::move(match));
        }
        property_.antecedent = {{{0, 1, 1, match, location}},
                                {2, 0, 1, {{0, 1, 0, 1, 1, std::move(match), location}}},
                                {1}};
        property_.consequent.reset();
        property_.implication.clear();
        property_.history_guard_delay = 0;
        property_.history_guard_signal.clear();
        property_.antecedent_history_guard_delay = 0;
        property_.antecedent_history_guard_signal.clear();
        property_.consequent_history_guard_delay = 0;
        property_.consequent_history_guard_signal.clear();
    }

    TypedExpression guard(const std::string& name) const {
        if (name.empty()) return {"literal", "1'b1", 1, false, property_.location, {}};
        return {"signal", name, 1, false, property_.location, {}};
    }

    TypedExpression binary(const char* op, TypedExpression left, TypedExpression right) const {
        return {"binary", op, 1, false, property_.location, {std::move(left), std::move(right)}};
    }

    TypedExpression implication(TypedExpression trigger, TypedExpression match) const {
        TypedExpression inactive{"unary", "!", 1, false, property_.location, {std::move(trigger)}};
        return binary("||", std::move(inactive), std::move(match));
    }

    std::string new_signal(const char* role) {
        if (generated_++ >= kMaxMonitorSignals) {
            throw MemoryBudgetExceeded("PDR monitor signal limit reached");
        }
        std::string name;
        do {
            name = "__q3a_pdr_monitor_" + std::to_string(next_name_++);
        } while (!names_.insert(name).second);
        model_.signals.emplace_back(name, 1, false, role, property_.location);
        return name;
    }

    TypedExpression share(TypedExpression value) {
        const auto name = new_signal("internal");
        model_.combinational_equations.push_back({name, 1, std::move(value), property_.location});
        return guard(name);
    }

    TypedExpression delay(TypedExpression value, std::uint64_t cycles, bool track = false) {
        if (cycles == 0) return value;
        // A zero-filled delay line never invents a match before the first
        // source sample. Reuse the T-IR initializer for generated scalar state.
        const bool record_pending = boundary_pending_ && track;
        const auto sample = guard(std::string(sample_enable_));
        if (record_pending) pending_terms_.push_back(binary("&&", sample, value));
        lowering::TIRHistoryGuard initial{property_.clock, cycles, {}, {}};
        initial.state_chain.reserve(static_cast<std::size_t>(cycles));
        for (std::uint64_t cycle = 0; cycle < cycles; ++cycle) {
            const auto name = new_signal("history_valid");
            if (sample_enable_.empty()) {
                model_.next_state_equations.push_back({name, 1, std::move(value), property_.location});
            } else {
                model_.next_state_equations.push_back(sampled_assignment(model_.signals.back(),
                    guard(std::string(sample_enable_)), std::move(value), property_.location));
            }
            initial.state_chain.push_back(name);
            value = guard(name);
            if (record_pending) {
                if (cycle + 1 < cycles) pending_terms_.push_back(value);
                else {
                    TypedExpression inactive{"unary", "!", 1, false, property_.location, {sample}};
                    pending_terms_.push_back(binary("&&", std::move(inactive), value));
                }
            }
        }
        initial.valid_signal = initial.state_chain.back();
        model_.history_guards.push_back(std::move(initial));
        return value;
    }

    TypedExpression sequence_end(const lowering::TIRSequence& sequence, TypedExpression active, bool track = false) {
        for (const auto& term : sequence.terms) {
            active = binary("&&", delay(std::move(active), term.delay_from_previous, track), term.predicate);
            for (std::uint64_t repeat = 1; repeat < term.repeat_min; ++repeat) {
                active = binary("&&", delay(std::move(active), 1, track), term.predicate);
            }
        }
        return active;
    }

    TypedExpression matches(const lowering::TIRSequence& sequence, const TypedExpression& active,
                            std::optional<std::uint64_t> decision_offset, bool track = false) {
        std::optional<TypedExpression> any_match;
        for (const auto& path : lowering::sequence_paths(sequence)) {
            std::map<std::uint64_t, TypedExpression> endpoints{{0, active}};
            for (auto index = path.begin; index < path.end; ++index) {
                const auto& term = sequence.terms[index];
                std::map<std::uint64_t, TypedExpression> next;
                for (auto& [offset, partial] : endpoints) {
                    auto match = delay(std::move(partial), term.delay_from_previous, track);
                    for (std::uint64_t repeat = 1; repeat <= term.repeat_max; ++repeat) {
                        match = share(binary("&&", std::move(match), term.predicate));
                        if (repeat >= term.repeat_min) {
                            const auto end = offset + term.delay_from_previous + repeat - 1;
                            auto [slot, inserted] = next.try_emplace(end, match);
                            if (!inserted) slot->second = share(binary("||", std::move(slot->second), match));
                        }
                        if (repeat < term.repeat_max) match = delay(std::move(match), 1, track);
                    }
                }
                endpoints = std::move(next);
            }
            for (auto& [offset, match] : endpoints) {
                // Assertions decide after the longest alternative. A cover
                // can report each hit at its actual end sample.
                if (decision_offset) match = delay(std::move(match), *decision_offset - offset);
                any_match = any_match
                    ? share(binary("||", std::move(*any_match), std::move(match)))
                    : std::move(match);
            }
        }
        if (!any_match) throw std::logic_error("PDR monitor has no sequence endpoints");
        return std::move(*any_match);
    }

    lowering::TIRModule& model_;
    lowering::TIRProperty& property_;
    std::unordered_set<std::string> names_;
    std::size_t next_name_ = 0;
    std::size_t& generated_;
    std::string_view sample_enable_;
    std::string* boundary_pending_;
    std::vector<TypedExpression> pending_terms_;
};

} // namespace

std::uint64_t lower_sequence_monitor(TIRModule& model, TIRProperty& property,
    std::size_t& generated_signals, std::uint64_t maximum_offset, std::string_view sample_enable, std::string* boundary_pending) {
    const auto antecedent = lowering::bounded_scalar_sequence_horizon(property.antecedent);
    const auto consequent = property.consequent
        ? lowering::bounded_scalar_sequence_horizon(*property.consequent) : std::optional<std::uint64_t>(0);
    const auto delta = property.implication == "nonoverlapped" ? 1U : 0U;
    const bool valid_implication = property.consequent
        ? property.implication == "overlapped" || property.implication == "nonoverlapped"
        : property.implication.empty() || property.implication == "sequence";
    if (!antecedent || !consequent || !valid_implication ||
        *antecedent + *consequent + delta > maximum_offset ||
        (!property.split_history_guards && !property.history_guard_signal.empty())) {
        throw lowering::LoweringError(property.location,
            "PDR requires a finite sequence goal or assumption with a final sample offset of at most " +
                std::to_string(maximum_offset) + ": " + property.name,
            frontend::InputDiagnosticKind::Unsupported);
    }
    SequenceMonitor monitor(model, property, generated_signals, sample_enable, boundary_pending);
    const bool cover_with_trigger = boundary_pending && property.kind == "cover" && property.consequent;
    if (!cover_with_trigger && fixed_sequence_horizon(property.antecedent) &&
        (!property.consequent || fixed_sequence_horizon(*property.consequent))) {
        monitor.lower(*antecedent, *consequent);
    } else {
        monitor.lower_ranges(*antecedent, *consequent);
    }
    return *antecedent + *consequent + delta;
}

} // namespace q3a::lowering
