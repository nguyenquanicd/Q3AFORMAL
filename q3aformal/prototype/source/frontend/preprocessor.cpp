#include "preprocessor.hpp"

#include "parser.hpp"

#include <algorithm>
#include <cctype>
#include <set>
#include <string_view>

namespace q3a::frontend {
namespace {

constexpr std::size_t kMaxMacroDepth = 32;
constexpr std::size_t kMaxExpandedTokens = 1000000;
constexpr std::size_t kMaxIncludeDepth = 32;
constexpr std::string_view kTokenPaste = "``";

bool macro_name(const Token& token) {
    return token.kind == TokenKind::Identifier && !token.text.empty() && token.text.front() != '$';
}

bool adjacent(const Token& first, const Token& second) {
    return first.location.byte_offset + first.text.size() == second.location.byte_offset;
}

void require_name(const std::vector<Token>& tokens, std::size_t start, std::size_t end,
                  const SourceLocation& at) {
    if (start >= end || !macro_name(tokens[start])) throw ParseError(at, "expected a macro name");
}

void append_token(std::vector<Token>& output, Token token) {
    if (output.size() == kMaxExpandedTokens) {
        throw ParseError(token.location, "preprocessed unit exceeds the expanded token limit");
    }
    output.push_back(std::move(token));
}

void append_substitution(std::vector<Token>& output, const Token& formal,
                         const std::vector<Token>& actuals) {
    for (std::size_t index = 0; index < actuals.size(); ++index) {
        auto token = actuals[index];
        if (index == 0) {
            token.location = formal.location;
            token.leading_space = formal.leading_space;
        }
        append_token(output, std::move(token));
    }
}

std::vector<Token> quote_body(const Token& quoted, const SourceLocation& location) {
    try {
        return tokenize_macro_text(quoted.text.substr(2, quoted.text.size() - 4), location.file);
    } catch (const LexError&) {
        throw ParseError(location, "invalid macro quotation body");
    }
}

std::vector<Token> paste_tokens(const std::vector<Token>& input, const SourceLocation& location) {
    std::vector<Token> result;
    for (std::size_t index = 0; index < input.size(); ++index) {
        if (input[index].text != kTokenPaste) {
            append_token(result, input[index]);
            continue;
        }
        if (result.empty()) {
            throw ParseError(location, "macro token paste requires operands on both sides");
        }
        if (result.back().kind == TokenKind::String) {
            throw ParseError(location, "macro token paste cannot join string literals");
        }
        auto joined = result.back().text;
        do {
            if (index + 1 == input.size() || input[index + 1].text == kTokenPaste) {
                throw ParseError(location, "macro token paste requires operands on both sides");
            }
            const auto& right = input[++index];
            if (right.kind == TokenKind::String) {
                throw ParseError(location, "macro token paste cannot join string literals");
            }
            joined += right.text;
            if (index + 1 == input.size() || input[index + 1].text != kTokenPaste) break;
            ++index;
        } while (true);
        std::vector<Token> lexed;
        try {
            lexed = tokenize(joined, location.file);
        } catch (const LexError&) {
            throw ParseError(location, "macro token paste did not form a single token: " + joined);
        }
        if (lexed.size() != 2 || lexed.front().text != joined ||
            lexed.front().text == "`" || lexed.front().text == kTokenPaste) {
            throw ParseError(location, "macro token paste did not form a single token: " + joined);
        }
        lexed.front().location = result.back().location;
        lexed.front().leading_space = result.back().leading_space;
        result.back() = std::move(lexed.front());
    }
    return result;
}

bool continues_definition(std::string_view source, const Token& token) {
    if (token.kind != TokenKind::Symbol || token.text != "\\") return false;
    const auto after_slash = source.substr(token.location.byte_offset + 1);
    return after_slash.substr(0, 1) == "\n" || after_slash.substr(0, 2) == "\r\n";
}

std::vector<Token> read_definition(std::string_view source, const std::vector<Token>& tokens,
    std::size_t& index, std::size_t line, bool active) {
    std::vector<Token> definition;
    while (index + 1 < tokens.size() && tokens[index].location.line == line) {
        const auto& token = tokens[index++];
        if (continues_definition(source, token)) {
            ++line;
        } else if (active) {
            if (token.kind == TokenKind::Symbol && token.text == "\\") {
                throw ParseError(token.location, "macro continuation requires a backslash immediately before the newline");
            }
            append_token(definition, token);
        }
    }
    return definition;
}

std::vector<std::vector<Token>> read_arguments(const std::vector<Token>& tokens,
    std::size_t& index, std::size_t end, const SourceLocation& location) {
    if (index >= end || tokens[index].text != "(") {
        throw ParseError(location, "function-like macro requires a parenthesized argument list");
    }
    ++index;
    const auto first = index;
    auto start = index;
    std::vector<std::string_view> closing;
    std::vector<std::vector<Token>> arguments;
    for (; index < end && tokens[index].kind != TokenKind::End; ++index) {
        const auto& text = tokens[index].text;
        if (closing.empty() && (text == "," || text == ")")) {
            if (text == "," || index != first) {
                arguments.emplace_back(tokens.begin() + start, tokens.begin() + index);
            }
            if (text == ")") {
                ++index;
                return arguments;
            }
            start = index + 1;
        } else if (text == "(" || text == "[" || text == "[*" || text == "{") {
            closing.push_back(text == "(" ? ")" : text == "{" ? "}" : "]");
        } else if (text == ")" || text == "]" || text == "}") {
            if (closing.empty() || closing.back() != text) {
                throw ParseError(location, "mismatched delimiter in macro argument list");
            }
            closing.pop_back();
        }
    }
    throw ParseError(location, "unterminated macro argument list");
}

struct Conditional {
    SourceLocation location;
    bool parent_active;
    bool chosen;
    bool active;
    bool seen_else = false;
};

} // namespace

Preprocessor::Preprocessor(const std::map<std::string, std::string>& definitions, IncludeResolver resolver)
    : include_resolver_(std::move(resolver)) {
    for (const auto& [name, value] : definitions) {
        auto identifier = tokenize(name, "<manifest macro>");
        if (identifier.size() != 2 || !macro_name(identifier.front()) || identifier.front().text != name) {
            throw ParseError(identifier.front().location, "invalid manifest macro name");
        }
        auto replacement = tokenize(value, "<manifest macro " + name + ">");
        replacement.pop_back();
        macros_.emplace(name, Macro{identifier.front().location, std::nullopt, std::move(replacement)});
    }
}

void Preprocessor::expand(const Token& invocation, const std::vector<Token>& tokens,
    std::size_t& index, std::vector<std::string>& stack, std::vector<Token>& output, std::size_t depth,
    StepSink* steps) const {
    const auto found = macros_.find(invocation.text);
    if (found == macros_.end()) throw ParseError(invocation.location, "undefined macro: " + invocation.text);
    if (depth >= kMaxMacroDepth || std::find(stack.begin(), stack.end(), invocation.text) != stack.end()) {
        throw ParseError(invocation.location, "recursive or excessively nested macro: " + invocation.text);
    }
    const auto& macro = found->second;
    if (steps) {
        if (steps->remaining == 0) {
            throw ParseError(invocation.location, "macro expansion map exceeds the preprocessing limit");
        }
        --steps->remaining;
        steps->steps.push_back({invocation.text, macro.definition});
    }
    Bindings bindings;
    if (macro.parameters) {
        const auto arguments = read_arguments(tokens, index, tokens.size(), invocation.location);
        if (arguments.size() > macro.parameters->size()) {
            throw ParseError(invocation.location, "too many macro arguments: " + invocation.text);
        }
        std::set<std::string> referenced;
        for (const auto& token : macro.replacement) {
            if (token.kind == TokenKind::Identifier) referenced.insert(token.text);
            if (token.kind == TokenKind::MacroQuoted) {
                for (const auto& item : quote_body(token, invocation.location)) {
                    if (item.kind == TokenKind::Identifier) referenced.insert(item.text);
                }
            }
        }
        for (std::size_t parameter = 0; parameter < macro.parameters->size(); ++parameter) {
            const auto& formal = macro.parameters->at(parameter);
            const auto& raw = parameter < arguments.size() && !arguments[parameter].empty()
                ? arguments[parameter] : formal.fallback;
            if (raw.empty()) {
                throw ParseError(invocation.location, "missing macro argument '" + formal.name + "': " + invocation.text);
            }
            auto& expanded = bindings[formal.name];
            if (referenced.count(formal.name)) {
                expand_tokens(raw, invocation.location, stack, expanded, depth + 1, steps);
            }
        }
    }
    stack.push_back(invocation.text);
    if (macro.parameters) {
        std::vector<Token> substituted;
        for (const auto& token : macro.replacement) {
            if (token.kind == TokenKind::MacroQuoted) {
                append_token(substituted, render_quoted(token, invocation.location, stack, depth + 1, steps, bindings));
                continue;
            }
            const auto binding = token.kind == TokenKind::Identifier ? bindings.find(token.text) : bindings.end();
            if (binding == bindings.end()) {
                append_token(substituted, token);
            } else {
                append_substitution(substituted, token, binding->second);
            }
        }
        expand_tokens(substituted, invocation.location, stack, output, depth + 1, steps);
    } else {
        expand_tokens(macro.replacement, invocation.location, stack, output, depth + 1, steps);
    }
    stack.pop_back();
}

Token Preprocessor::render_quoted(const Token& quoted, const SourceLocation& location,
    std::vector<std::string>& stack, std::size_t depth, StepSink* steps,
    const Bindings& bindings) const {
    const auto tokens = quote_body(quoted, location);
    std::vector<Token> substituted;
    for (std::size_t index = 0; index + 1 < tokens.size(); ++index) {
        const auto& token = tokens[index];
        if (token.text == kTokenPaste) continue;
        const auto binding = token.kind == TokenKind::Identifier ? bindings.find(token.text) : bindings.end();
        if (binding == bindings.end()) append_token(substituted, token);
        else append_substitution(substituted, token, binding->second);
    }
    std::vector<Token> expanded;
    expand_tokens(substituted, location, stack, expanded, depth, steps);
    std::string text(1, '"');
    for (const auto& token : expanded) {
        text.append(token.leading_space, ' ');
        for (const auto character : token.text) {
            if (character == '"' || character == '\\') text.push_back('\\');
            text.push_back(character);
        }
    }
    text.append(tokens.back().leading_space, ' ');
    text.push_back('"');
    return Token{TokenKind::String, std::move(text), quoted.location, quoted.leading_space};
}

void Preprocessor::expand_tokens(const std::vector<Token>& tokens, const SourceLocation& location,
    std::vector<std::string>& stack, std::vector<Token>& output, std::size_t depth,
    StepSink* steps) const {
    std::optional<std::vector<Token>> pasted;
    if (std::any_of(tokens.begin(), tokens.end(),
        [](const auto& token) { return token.text == kTokenPaste; })) {
        pasted.emplace(paste_tokens(tokens, location));
    }
    const auto& replacement = pasted ? *pasted : tokens;
    for (std::size_t index = 0; index < replacement.size();) {
        auto token = replacement[index++];
        if (token.text == "`") {
            if (index == replacement.size() || !macro_name(replacement[index]) ||
                !adjacent(token, replacement[index])) {
                throw ParseError(location, "unsupported macro quotation or invalid macro name",
                    InputDiagnosticKind::Unsupported);
            }
            auto invocation = replacement[index++];
            invocation.location = location;
            const auto start = output.size();
            expand(invocation, replacement, index, stack, output, depth, steps);
            if (output.size() != start) output[start].leading_space = token.leading_space;
        } else if (token.kind == TokenKind::MacroQuoted) {
            auto rendered = render_quoted(token, location, stack, depth, steps);
            rendered.location = location;
            append_token(output, std::move(rendered));
        } else {
            token.location = location;
            append_token(output, std::move(token));
        }
    }
}

std::vector<Token> Preprocessor::tokenize_unit(const std::string& source, const std::string& path) {
    return tokenize_unit_impl(source, path, nullptr);
}

PreprocessedUnit Preprocessor::tokenize_unit_with_expansions(const std::string& source, const std::string& path) {
    PreprocessedUnit unit;
    unit.tokens = tokenize_unit_impl(source, path, &unit.expansions);
    return unit;
}

std::vector<Token> Preprocessor::tokenize_unit_impl(const std::string& source, const std::string& path,
    std::vector<MacroExpansion>* expansions) {
    if (source.find('`') == std::string::npos) return tokenize(source, path);
    std::vector<Token> output;
    auto steps_remaining = kMaxExpandedTokens;
    output.push_back(process(source, path, output, 0, expansions, steps_remaining));
    return output;
}

Token Preprocessor::process(const std::string& source, const std::string& path,
                            std::vector<Token>& output, std::size_t depth, std::vector<MacroExpansion>* expansions,
                            std::size_t& steps_remaining) {
    auto tokens = tokenize(source, path);
    std::vector<Conditional> conditions;
    std::vector<std::string> expansion_stack;
    const auto active = [&] { return conditions.empty() || conditions.back().active; };
    for (std::size_t index = 0; index + 1 < tokens.size();) {
        const auto& token = tokens[index++];
        if (active() && (token.text == kTokenPaste || token.kind == TokenKind::MacroQuoted)) {
            throw ParseError(token.location, "macro quotation and token paste require a macro expansion");
        }
        if (token.text != "`") {
            if (active()) append_token(output, token);
            continue;
        }
        if (!macro_name(tokens[index]) || !adjacent(token, tokens[index])) {
            if (active()) throw ParseError(token.location, "expected a directive or macro after backtick");
            continue;
        }
        auto invocation = tokens[index++];
        const auto& name = invocation.text;
        const bool conditional = name == "ifdef" || name == "ifndef" || name == "elsif" ||
            name == "else" || name == "endif";
        const bool definition = name == "define" || name == "undef";
        const bool include = name == "include";
        if (!conditional && !definition && !include) {
            if (!active()) continue;
            if (name == "timescale" || name == "default_nettype" ||
                name == "line" || name == "resetall" || name == "undefineall" ||
                name == "pragma" || name == "__FILE__" || name == "__LINE__") {
                throw ParseError(token.location, "unsupported preprocessor directive: " + name,
                    InputDiagnosticKind::Unsupported);
            }
            invocation.location = token.location;
            if (expansions) {
                MacroExpansion used{MacroUse::SourceTokens, token.location, output.size(), 0, {}};
                StepSink sink{used.steps, steps_remaining};
                expand(invocation, tokens, index, expansion_stack, output, 0, &sink);
                used.output_end = output.size();
                expansions->push_back(std::move(used));
            } else {
                expand(invocation, tokens, index, expansion_stack, output, 0, nullptr);
            }
            continue;
        }

        if (name == "define") {
            const bool enabled = active();
            const auto parts = read_definition(source, tokens, index, token.location.line, enabled);
            if (!enabled) continue;
            require_name(parts, 0, parts.size(), token.location);
            const auto& identifier = parts.front();
            std::size_t body = 1;
            Macro macro;
            macro.definition = identifier.location;
            if (body < parts.size() && parts[body].text == "(" && adjacent(identifier, parts[body])) {
                macro.parameters.emplace();
                std::set<std::string> formals;
                for (const auto& formal : read_arguments(parts, body, parts.size(), token.location)) {
                    if (formal.empty() || !macro_name(formal.front()) ||
                        (formal.size() != 1 && (formal.size() < 3 || formal[1].text != "="))) {
                        throw ParseError(token.location, "invalid macro formal parameter");
                    }
                    if (!formals.insert(formal.front().text).second) {
                        throw ParseError(token.location, "duplicate macro formal: " + formal.front().text);
                    }
                    Parameter parameter{formal.front().text, {}};
                    if (formal.size() > 1) parameter.fallback.assign(formal.begin() + 2, formal.end());
                    macro.parameters->push_back(std::move(parameter));
                }
            }
            macro.replacement.assign(parts.begin() + body, parts.end());
            macros_[identifier.text] = std::move(macro);
            continue;
        }

        auto end = index;
        while (end + 1 < tokens.size() && tokens[end].location.line == token.location.line) ++end;
        const auto argument = index;
        index = end;
        if (!conditional && !active()) continue;
        if (include) {
            const std::vector<Token> operand(tokens.begin() + argument, tokens.begin() + end);
            std::vector<Token> expanded;
            std::vector<MacroExpansionStep> steps;
            StepSink sink{steps, steps_remaining};
            expand_tokens(operand, token.location, expansion_stack, expanded, 0,
                expansions ? &sink : nullptr);
            if (expanded.size() != 1 || expanded.front().kind != TokenKind::String ||
                expanded.front().text.size() <= 2) {
                throw ParseError(token.location, "include requires one quoted relative path after macro expansion");
            }
            if (!include_resolver_) {
                throw ParseError(token.location, "include is unavailable outside a resolved project",
                    InputDiagnosticKind::Unsupported);
            }
            if (depth >= kMaxIncludeDepth) throw ParseError(token.location, "include nesting exceeds 32 levels");
            const auto& quoted = expanded.front().text;
            const auto name = quoted.substr(1, quoted.size() - 2);
            const auto file = include_resolver_(token.location, name);
            if (!file) throw ParseError(token.location, "include file not found: " + name);
            if (expansions && !steps.empty()) {
                expansions->push_back({MacroUse::IncludeOperand, token.location,
                    output.size(), output.size(), std::move(steps)});
            }
            process(file->contents, file->path, output, depth + 1, expansions, steps_remaining);
            continue;
        }
        if (name != "else" && name != "endif") require_name(tokens, argument, end, token.location);
        const std::size_t expected = name == "else" || name == "endif" ? 0 : 1;
        if (end - argument != expected) {
            throw ParseError(token.location, "unexpected directive arguments: " + name);
        }
        if (name == "undef") {
            macros_.erase(tokens[argument].text);
        } else if (name == "ifdef" || name == "ifndef") {
            const bool matches = (macros_.count(tokens[argument].text) != 0) == (name == "ifdef");
            const bool parent = active();
            conditions.push_back({token.location, parent, matches, parent && matches});
        } else {
            if (conditions.empty()) throw ParseError(token.location, "unmatched preprocessor directive: " + name);
            auto& condition = conditions.back();
            if (name == "endif") {
                conditions.pop_back();
                continue;
            }
            if (condition.seen_else) throw ParseError(token.location, "directive follows else: " + name);
            condition.seen_else = name == "else";
            const bool matches = condition.seen_else || macros_.count(tokens[argument].text) != 0;
            condition.active = condition.parent_active && !condition.chosen && matches;
            condition.chosen |= matches;
        }
    }
    if (!conditions.empty()) throw ParseError(conditions.back().location, "unterminated conditional directive");
    return std::move(tokens.back());
}

} // namespace q3a::frontend
