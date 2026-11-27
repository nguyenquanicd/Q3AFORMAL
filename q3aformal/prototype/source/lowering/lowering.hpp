#pragma once

#include "../elaborator/elaborator.hpp"

#include <cstdint>
#include <optional>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace q3a::lowering {

struct TypedExpression {
    std::string kind;
    std::string value;
    std::uint64_t width = 0;
    bool is_signed = false;
    frontend::SourceLocation location;
    std::vector<TypedExpression> operands;
};

// Stable recursive key used to compare typed expression structures in T-IR.
std::string expression_semantic_key(const TypedExpression& expression);

struct TIRSignal {
    std::string name;
    std::uint64_t width = 0;
    bool is_signed = false;
    std::string role;
    frontend::SourceLocation location;
    std::optional<std::int64_t> packed_left_index;
    std::optional<std::int64_t> packed_right_index;

    TIRSignal() = default;
    TIRSignal(std::string signal_name,
              std::uint64_t signal_width,
              bool signal_is_signed,
              std::string signal_role,
              frontend::SourceLocation signal_location,
              std::optional<std::int64_t> packed_left = std::nullopt,
              std::optional<std::int64_t> packed_right = std::nullopt)
        : name(std::move(signal_name)), width(signal_width),
          is_signed(signal_is_signed), role(std::move(signal_role)),
          location(std::move(signal_location)),
          packed_left_index(packed_left), packed_right_index(packed_right) {}
};

struct TIRConstant {
    std::string name;
    std::string kind;
    std::int64_t value = 0;
    std::uint64_t width = 0;
    bool is_signed = false;
    frontend::SourceLocation location;
    std::optional<frontend::PackedBounds> packed_bounds = std::nullopt;
};

struct TIREquation {
    std::string target;
    std::uint64_t target_width = 0;
    TypedExpression expression;
    frontend::SourceLocation location;
};

struct TIRSequenceTerm {
    std::uint64_t delay_from_previous = 0;
    std::uint64_t repeat_min = 1;
    std::uint64_t repeat_max = 1;
    TypedExpression predicate;
    frontend::SourceLocation location;
};

struct TIRSequenceTransition {
    std::uint64_t source_state = 0;
    std::uint64_t target_state = 0;
    std::uint64_t delay_cycles = 0;
    std::uint64_t repeat_min = 1;
    std::uint64_t repeat_max = 1;
    TypedExpression predicate;
    frontend::SourceLocation location;
};

struct TIRSequenceAutomaton {
    std::uint64_t state_count = 0;
    std::uint64_t start_state = 0;
    std::uint64_t accepting_state = 0;
    std::vector<TIRSequenceTransition> transitions;
};

struct TIRSequence {
    std::vector<TIRSequenceTerm> terms;
    TIRSequenceAutomaton automaton;
    // Construction metadata. Serialized automata encode the same boundaries.
    std::vector<std::size_t> path_lengths;
};

struct TIRSequencePath {
    std::size_t begin;
    std::size_t end;
};

// The automaton serializes disjoint nonempty paths with shared start/accept.
std::vector<TIRSequencePath> sequence_paths(const TIRSequence& sequence);
std::uint64_t sequence_maximum_offset(const TIRSequence& sequence,
    std::optional<std::uint64_t> maximum_paths = 4096);

// Returns the maximum sample offset for a one-bit linear sequence with
// constant or finite bounded delay ranges and positive bounded repetition,
// limited to 4096 paths and a total offset within the transition encoder's
// 10000-frame limit.
std::optional<std::uint64_t> bounded_scalar_sequence_horizon(
    const TIRSequence& sequence);
bool is_same_sample_sequence(const TIRSequence& sequence);

struct TIRProperty {
    std::string name;
    std::string kind;
    std::string clock;
    std::string implication;
    std::uint64_t history_guard_delay = 0;
    std::string history_guard_signal;
    // T-IR 0.4 tracks history validity independently for each implication
    // operand. The legacy property-wide fields above remain for bundle
    // compatibility and diagnostics.
    bool split_history_guards = false;
    std::uint64_t antecedent_history_guard_delay = 0;
    std::string antecedent_history_guard_signal;
    std::uint64_t consequent_history_guard_delay = 0;
    std::string consequent_history_guard_signal;
    TIRSequence antecedent;
    std::optional<TIRSequence> consequent;
    frontend::SourceLocation location;
};

inline bool is_eventual_response(const TIRProperty& property) {
    return property.implication == "overlapped-eventual" || property.implication == "nonoverlapped-eventual";
}

// Select operand-specific history guards when present; older hand-built or
// serialized T-IR properties use the legacy property-wide guard.
const std::string& antecedent_history_guard(const TIRProperty& property) noexcept;
const std::string& consequent_history_guard(const TIRProperty& property) noexcept;

// Returns the maximum sample offset used by an induction-supported property.
// Assertion and assumption sequences may use fixed delays and positive
// bounded repetition. T-IR 0.4 applies separate history guards at each
// implication operand's sequence start; legacy guarded delayed properties
// remain unsupported because their property-wide guard loses that alignment.
std::optional<std::uint64_t> bounded_induction_property_horizon(
    const TIRProperty& property);

struct TIRHistoryGuard {
    std::string clock;
    std::uint64_t delay = 0;
    std::string valid_signal;
    std::vector<std::string> state_chain;
};

struct TIRModule {
    std::string schema_version = "Q3A-TIR-0.4";
    std::string semantic_profile;
    std::string input_hash;
    std::string name;
    std::vector<TIRSignal> signals;
    std::vector<TIRConstant> parameters;
    std::vector<std::string> clocks;
    std::vector<TIRHistoryGuard> history_guards;
    std::vector<TIRProperty> properties;
    std::vector<TIREquation> combinational_equations;
    std::vector<TIREquation> next_state_equations;
};

class LoweringError : public std::runtime_error {
public:
    LoweringError(frontend::SourceLocation location, const std::string& message,
                  frontend::InputDiagnosticKind kind = frontend::InputDiagnosticKind::Invalid);
    const frontend::SourceLocation& location() const noexcept { return location_; }
    frontend::InputDiagnosticKind kind() const noexcept { return kind_; }

private:
    frontend::SourceLocation location_;
    frontend::InputDiagnosticKind kind_;
};

TIRModule lower_continuous_assignments(
    const std::vector<frontend::SyntaxUnit>& source_units,
    const elaboration::ElaborationResult& elaborated);

std::string serialize_tir(const TIRModule& module);

} // namespace q3a::lowering
