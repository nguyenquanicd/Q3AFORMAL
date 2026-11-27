#pragma once

#include "lexer.hpp"

#include <map>
#include <stdexcept>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace q3a::frontend {

struct ExpressionSpan {
    std::size_t first_token = 0;
    std::size_t after_last_token = 0;
};

struct PackedRangeSyntax {
    ExpressionSpan left;
    ExpressionSpan right;
};

enum class ScalarType { Untyped, Integer, Logic, Bit };
enum class PortDirection { Input, Output };

struct ParameterSyntax {
    std::string name;
    SourceLocation location;
    ScalarType type = ScalarType::Untyped;
    bool is_signed = false;
    std::optional<ExpressionSpan> initializer;
    bool is_localparam = false;
    std::optional<PackedRangeSyntax> packed_range;
};

struct PortSyntax {
    std::string name;
    SourceLocation location;
    PortDirection direction = PortDirection::Input;
    ScalarType type = ScalarType::Logic;
    bool is_signed = false;
    std::optional<PackedRangeSyntax> packed_range;
};

struct SignalSyntax {
    std::string name;
    SourceLocation location;
    ScalarType type = ScalarType::Logic;
    bool is_signed = false;
    std::optional<PackedRangeSyntax> packed_range;
};

struct MemorySyntax {
    SignalSyntax element;
    PackedRangeSyntax index_range;
};

struct ParameterOverrideSyntax {
    std::optional<std::string> name;
    ExpressionSpan value;
    SourceLocation location;
};

struct PortConnectionSyntax {
    std::optional<std::string> formal_name;
    ExpressionSpan actual;
    SourceLocation location;
};

struct InstanceSyntax {
    std::string module_type;
    std::string instance_name;
    SourceLocation location;
    std::vector<ParameterOverrideSyntax> parameter_overrides;
    std::vector<PortConnectionSyntax> port_connections;
};

struct BindSyntax {
    std::string target;
    bool hierarchical = false;
    SourceLocation location;
    InstanceSyntax instance;
};

struct ContinuousAssignmentSyntax {
    ExpressionSpan lvalue;
    ExpressionSpan expression;
    SourceLocation location;
    bool nonblocking = false;
};

enum class StatementKind { Block, If, Case, CaseZ, Assignment, CaseX };

struct StatementSyntax;

struct CaseItemSyntax {
    bool is_default = false;
    SourceLocation location;
    std::vector<ExpressionSpan> labels;
    std::vector<StatementSyntax> statements;
};

struct StatementSyntax {
    StatementKind kind = StatementKind::Block;
    SourceLocation location;
    std::optional<ExpressionSpan> expression;
    std::optional<ExpressionSpan> lvalue;
    std::optional<ExpressionSpan> assignment;
    bool nonblocking = false;
    std::vector<StatementSyntax> body;
    std::vector<StatementSyntax> else_body;
    std::vector<CaseItemSyntax> case_items;
};

enum class ProcessKind { AlwaysComb, AlwaysFF };

struct ProcessSyntax {
    ProcessKind kind = ProcessKind::AlwaysComb;
    SourceLocation location;
    std::optional<std::string> clock;
    StatementSyntax body;
};

enum class PropertyCheckKind { Assert, Assume, Cover };

struct SequenceDeclarationSyntax {
    std::string name;
    SourceLocation location;
    ExpressionSpan body;
};

struct PropertyDeclarationSyntax {
    std::string name;
    SourceLocation location;
    std::string clock;
    ExpressionSpan sequence;
};

struct PropertyCheckSyntax {
    PropertyCheckKind kind = PropertyCheckKind::Assert;
    SourceLocation location;
    std::optional<std::string> clock;
    std::optional<ExpressionSpan> sequence;
    std::optional<std::string> property_reference;
    std::optional<std::string> label;
};

enum class GenerateKind { Block, Conditional, Loop, Instance, Other };

struct GenerateSyntax {
    GenerateKind kind = GenerateKind::Other;
    std::string label;
    std::string variable;
    std::string update_variable;
    SourceLocation location;
    std::optional<ExpressionSpan> condition;
    std::optional<ExpressionSpan> initial_value;
    std::optional<ExpressionSpan> update_value;
    std::optional<InstanceSyntax> instance;
    std::optional<ContinuousAssignmentSyntax> assignment;
    std::vector<SignalSyntax> declarations;
    std::vector<ParameterSyntax> constants;
    std::size_t first_token = 0;
    std::size_t after_last_token = 0;
    std::vector<GenerateSyntax> body;
    std::vector<GenerateSyntax> else_body;
};

struct ParsedModule {
    std::string name;
    SourceLocation location;
    std::size_t first_token = 0;
    std::size_t after_last_token = 0;
    std::vector<ParameterSyntax> parameters;
    std::vector<ParameterSyntax> localparams;
    std::vector<PortSyntax> ports;
    std::vector<SignalSyntax> signals;
    std::vector<MemorySyntax> memories;
    std::vector<ContinuousAssignmentSyntax> continuous_assignments;
    std::vector<ProcessSyntax> processes;
    std::vector<SequenceDeclarationSyntax> sequence_declarations;
    std::vector<PropertyDeclarationSyntax> property_declarations;
    std::vector<PropertyCheckSyntax> property_checks;
    std::vector<GenerateSyntax> generate_items;
    std::vector<InstanceSyntax> instances;
};

struct SyntaxUnit {
    std::vector<Token> tokens;
    std::vector<ParsedModule> modules;
    std::vector<BindSyntax> binds;
    std::vector<PropertyDeclarationSyntax> standalone_declarations;
    std::vector<PropertyCheckSyntax> standalone_checks;
    // Qualified operand spans remain in the original token coordinates.
    std::map<std::size_t, std::pair<std::size_t, std::string>> hierarchical_operands;
};

class ParseError : public std::runtime_error {
public:
    ParseError(SourceLocation location, const std::string& message,
               InputDiagnosticKind kind = InputDiagnosticKind::Invalid);
    const SourceLocation& location() const noexcept { return location_; }
    InputDiagnosticKind kind() const noexcept { return kind_; }

private:
    SourceLocation location_;
    InputDiagnosticKind kind_;
};

enum class SyntaxProfile { Released, ExactMemoryDevelopment, SampledValueDevelopment, LivenessDevelopment, FourStateDevelopment };
inline constexpr std::string_view kFourStateProfile = "Q3A-FOUR-STATE-DEVELOPMENT";
inline constexpr std::string_view kLivenessProfile = "Q3A-LIVENESS-DEVELOPMENT";
inline constexpr std::string_view kSampledValueProfile = "Q3A-SAMPLED-VALUE-DEVELOPMENT";

inline bool is_sampled_value_function(std::string_view name) noexcept {
    return name == "$stable" || name == "$changed" || name == "$rose" || name == "$fell";
}

inline bool is_bit_vector_assertion_function(std::string_view name) noexcept {
    return name == "$onehot" || name == "$onehot0" || name == "$countones";
}

inline std::optional<SyntaxProfile> project_syntax_profile(std::string_view name) noexcept {
    if (name == "Q3A-P0-R0.9.1") return SyntaxProfile::Released;
#ifdef Q3A_ENABLE_DEVELOPMENT_SAMPLED_VALUES
    if (name == kSampledValueProfile) return SyntaxProfile::SampledValueDevelopment;
#endif
#ifdef Q3A_ENABLE_DEVELOPMENT_LIVENESS
    if (name == kLivenessProfile) return SyntaxProfile::LivenessDevelopment;
#endif
#ifdef Q3A_ENABLE_DEVELOPMENT_FOUR_STATE
    if (name == kFourStateProfile) return SyntaxProfile::FourStateDevelopment;
#endif
    return std::nullopt;
}
SyntaxUnit parse_source(std::vector<Token> tokens, bool allow_empty = false,
                        SyntaxProfile profile = SyntaxProfile::Released);

} // namespace q3a::frontend
