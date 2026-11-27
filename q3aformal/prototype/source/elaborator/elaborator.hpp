#pragma once

#include "../frontend/parser.hpp"
#include "../frontend/packed_select.hpp"

#include <cstdint>
#include <map>
#include <optional>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace q3a::elaboration {

struct TypedConstant {
    std::string name;
    // The signed carrier also holds the raw bits of an unsigned 64-bit value.
    // Interpret those bits using is_signed at the consumer.
    std::int64_t value = 0;
    frontend::ScalarType type = frontend::ScalarType::Untyped;
    bool is_signed = false;
    std::uint64_t width = 0;
    frontend::SourceLocation location;
    std::optional<frontend::PackedBounds> packed_bounds = std::nullopt;
};

struct TypedSignal {
    std::string name;
    std::uint64_t width = 1;
    bool is_signed = false;
    frontend::ScalarType type = frontend::ScalarType::Logic;
    frontend::PortDirection direction = frontend::PortDirection::Input;
    bool is_port = false;
    frontend::SourceLocation location;
    std::optional<std::int64_t> packed_left_index;
    std::optional<std::int64_t> packed_right_index;
};

struct TypedMemory {
    TypedSignal element;
    std::uint64_t left = 0;
    std::uint64_t right = 0;
};

struct GenerateResolution {
    std::string kind;
    std::string path;
    bool selected = true;
    std::optional<std::int64_t> iteration_value;
    std::uint64_t iteration_count = 0;
    frontend::SourceLocation location;
    std::map<std::string, std::int64_t> genvar_values;
    std::string scope_path;
    std::string local_name;
    std::optional<TypedSignal> declared_signal;
    std::optional<TypedConstant> declared_constant;
    std::map<std::string, TypedConstant> scoped_constants;

    GenerateResolution() = default;
    GenerateResolution(std::string resolution_kind,
                       std::string resolution_path,
                       bool resolution_selected,
                       std::optional<std::int64_t> resolution_iteration_value,
                       std::uint64_t resolution_iteration_count,
                       frontend::SourceLocation resolution_location,
                       std::map<std::string, std::int64_t> resolution_genvar_values,
                       std::string resolution_scope_path = {},
                       std::string resolution_local_name = {},
                       std::optional<TypedSignal> resolution_signal = std::nullopt)
        : kind(std::move(resolution_kind)), path(std::move(resolution_path)),
          selected(resolution_selected),
          iteration_value(resolution_iteration_value),
          iteration_count(resolution_iteration_count),
          location(std::move(resolution_location)),
          genvar_values(std::move(resolution_genvar_values)),
          scope_path(std::move(resolution_scope_path)),
          local_name(std::move(resolution_local_name)),
          declared_signal(std::move(resolution_signal)) {}
};

struct ElaboratedConnection {
    std::string formal_port;
    std::string actual_expression;
    std::uint64_t formal_width = 0;
    std::uint64_t actual_width = 0;
    frontend::PortDirection direction = frontend::PortDirection::Input;
};

struct BindOrigin {
    std::size_t source_unit;
    std::size_t directive;
};

struct ElaboratedInstance {
    std::string module_type;
    std::string instance_name;
    frontend::SourceLocation location;
    std::map<std::string, std::int64_t> generate_variables;
    std::map<std::string, TypedConstant> scoped_constants;
    std::vector<TypedConstant> parameters;
    std::vector<TypedConstant> localparams;
    std::vector<TypedSignal> ports;
    std::vector<TypedSignal> signals;
    std::vector<GenerateResolution> generate_scopes;
    std::vector<ElaboratedConnection> connections;
    std::vector<ElaboratedInstance> child_instances;
    std::optional<BindOrigin> binding;
};

struct ElaboratedModule {
    std::string name;
    std::vector<TypedMemory> memories;
    std::vector<TypedConstant> parameters;
    std::vector<TypedConstant> localparams;
    std::vector<TypedSignal> ports;
    std::vector<TypedSignal> signals;
    std::vector<GenerateResolution> generate_scopes;
    std::vector<ElaboratedInstance> instances;
};

struct ElaborationResult {
    std::string profile_id;
    std::string input_hash;
    ElaboratedModule top;
};

class ElaborationError : public std::runtime_error {
public:
    ElaborationError(frontend::SourceLocation location,
                     const std::string& message);
    const frontend::SourceLocation& location() const noexcept {
        return location_;
    }

private:
    frontend::SourceLocation location_;
};

ElaborationResult elaborate_top(
    const std::vector<frontend::SyntaxUnit>& source_units,
    const std::string& top_module,
    const std::map<std::string, std::string>& parameter_overrides,
    const std::string& profile_id,
    const std::string& input_hash);

const char* scalar_type_name(frontend::ScalarType type) noexcept;

inline std::string integral_value_text(std::int64_t value, bool is_signed) {
    if (is_signed) return std::to_string(value);
    return std::to_string(static_cast<std::uint64_t>(value));
}

} // namespace q3a::elaboration
