#pragma once

#include "lexer.hpp"

#include <map>
#include <functional>
#include <optional>
#include <string>
#include <vector>

namespace q3a::frontend {

enum class MacroUse { SourceTokens, IncludeOperand };

struct MacroExpansionStep {
    std::string name;
    SourceLocation definition;
};

struct MacroExpansion {
    MacroUse use;
    SourceLocation invocation;
    std::size_t output_begin;
    std::size_t output_end;
    std::vector<MacroExpansionStep> steps;
};

struct PreprocessedUnit {
    std::vector<Token> tokens;
    // Ranges are half-open indices into tokens. Include operands emit no tokens.
    std::vector<MacroExpansion> expansions;
};

// One macro environment for ordered SystemVerilog compilation units.
class Preprocessor {
public:
    struct Include {
        std::string path;
        std::string contents;
    };
    using IncludeResolver = std::function<std::optional<Include>(const SourceLocation&, const std::string&)>;

    explicit Preprocessor(const std::map<std::string, std::string>& definitions, IncludeResolver resolver = {});
    std::vector<Token> tokenize_unit(const std::string& source, const std::string& path);
    PreprocessedUnit tokenize_unit_with_expansions(const std::string& source, const std::string& path);

private:
    using Bindings = std::map<std::string, std::vector<Token>>;
    struct Parameter {
        std::string name;
        std::vector<Token> fallback;
    };
    struct Macro {
        SourceLocation definition;
        std::optional<std::vector<Parameter>> parameters;
        std::vector<Token> replacement;
    };

    struct StepSink {
        std::vector<MacroExpansionStep>& steps;
        std::size_t& remaining;
    };
    std::vector<Token> tokenize_unit_impl(const std::string& source, const std::string& path,
                                         std::vector<MacroExpansion>* expansions);
    Token process(const std::string& source, const std::string& path,
                  std::vector<Token>& output, std::size_t depth, std::vector<MacroExpansion>* expansions,
                  std::size_t& steps_remaining);
    void expand(const Token& invocation, const std::vector<Token>& tokens, std::size_t& index,
                std::vector<std::string>& stack, std::vector<Token>& output, std::size_t depth,
                StepSink* steps) const;
    void expand_tokens(const std::vector<Token>& tokens, const SourceLocation& location,
                       std::vector<std::string>& stack, std::vector<Token>& output, std::size_t depth,
                       StepSink* steps) const;
    Token render_quoted(const Token& quoted, const SourceLocation& location,
                        std::vector<std::string>& stack, std::size_t depth,
                        StepSink* steps, const Bindings& bindings = {}) const;
    std::map<std::string, Macro> macros_;
    IncludeResolver include_resolver_;
};

} // namespace q3a::frontend
