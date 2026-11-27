#pragma once

#include <cstddef>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

namespace q3a::frontend {

inline bool is_shift_operator(std::string_view op) {
    return op == "<<" || op == ">>" || op == "<<<" || op == ">>>";
}

inline bool is_reduction_operator(std::string_view op) {
    return op == "&" || op == "|" || op == "^" || op == "~&" || op == "~|" || op == "~^" || op == "^~";
}

enum class TokenKind { Identifier, Number, String, MacroQuoted, Symbol, End };
enum class InputDiagnosticKind { Invalid, Unsupported };

struct SourceLocation {
    std::string file;
    std::size_t line = 1;
    std::size_t column = 1;
    std::size_t byte_offset = 0;
};

struct Token {
    TokenKind kind = TokenKind::End;
    std::string text;
    SourceLocation location;
    std::size_t leading_space = 0;
};

class LexError : public std::runtime_error {
public:
    LexError(SourceLocation location, const std::string& message);
    const SourceLocation& location() const noexcept { return location_; }

private:
    SourceLocation location_;
};

std::vector<Token> tokenize(const std::string& source,
                            const std::string& source_name);
std::vector<Token> tokenize_macro_text(const std::string& source,
                                       const std::string& source_name);
const char* token_kind_name(TokenKind kind) noexcept;

} // namespace q3a::frontend
