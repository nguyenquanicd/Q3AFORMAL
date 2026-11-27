#include "lexer.hpp"

#include <cctype>
#include <string_view>
#include <utility>

namespace q3a::frontend {
namespace {

class Scanner {
public:
    Scanner(const std::string& source, const std::string& source_name, bool macro_text = false)
        : source_(source), source_name_(source_name), macro_text_(macro_text) {}

    std::vector<Token> run() {
        std::vector<Token> tokens;
        std::size_t trailing_space = 0;
        while (!at_end()) {
            const auto previous_end = offset_;
            skip_trivia();
            if (at_end()) {
                trailing_space = offset_ - previous_end;
                break;
            }
            const auto leading_space = offset_ - previous_end;
            tokens.push_back(next_token());
            tokens.back().leading_space = leading_space;
        }
        tokens.push_back(Token{TokenKind::End, {}, location(), trailing_space});
        return tokens;
    }

private:
    bool at_end() const { return offset_ >= source_.size(); }
    char peek(std::size_t lookahead = 0) const {
        const auto index = offset_ + lookahead;
        return index < source_.size() ? source_[index] : '\0';
    }

    SourceLocation location() const {
        return SourceLocation{source_name_, line_, column_, offset_};
    }

    char advance() {
        if (at_end()) {
            return '\0';
        }
        const char current = source_[offset_++];
        if (current == '\n') {
            ++line_;
            column_ = 1;
        } else {
            ++column_;
        }
        return current;
    }

    [[noreturn]] void fail(const SourceLocation& at,
                           const std::string& message) const {
        throw LexError(at, message);
    }

    void skip_trivia() {
        for (;;) {
            while (std::isspace(static_cast<unsigned char>(peek())) != 0) {
                advance();
            }
            if (macro_text_) return;
            if (peek() == '/' && peek(1) == '/') {
                while (!at_end() && peek() != '\n') {
                    advance();
                }
                continue;
            }
            if (peek() == '/' && peek(1) == '*') {
                const auto start = location();
                advance();
                advance();
                while (!at_end() && !(peek() == '*' && peek(1) == '/')) {
                    advance();
                }
                if (at_end()) {
                    fail(start, "unterminated block comment");
                }
                advance();
                advance();
                continue;
            }
            return;
        }
    }

    static bool identifier_start(char ch) {
        const auto c = static_cast<unsigned char>(ch);
        return std::isalpha(c) != 0 || ch == '_' || ch == '$';
    }

    static bool identifier_continue(char ch) {
        const auto c = static_cast<unsigned char>(ch);
        return std::isalnum(c) != 0 || ch == '_' || ch == '$';
    }

    Token make(TokenKind kind, const SourceLocation& start) const {
        return Token{kind, source_.substr(start.byte_offset,
                                          offset_ - start.byte_offset), start};
    }

    Token scan_identifier() {
        const auto start = location();
        advance();
        while (identifier_continue(peek())) {
            advance();
        }
        return make(TokenKind::Identifier, start);
    }

    Token scan_based_digits(const SourceLocation& start) {
        const char base = peek();
        if (base != 'b' && base != 'B' && base != 'o' && base != 'O' &&
            base != 'd' && base != 'D' && base != 'h' && base != 'H') {
            fail(start, "malformed based integer literal");
        }
        advance();
        const auto digits_start = offset_;
        while (std::isalnum(static_cast<unsigned char>(peek())) != 0 ||
               peek() == '_' || peek() == '?') {
            advance();
        }
        if (offset_ == digits_start) {
            fail(start, "based integer literal has no digits");
        }
        return make(TokenKind::Number, start);
    }

    Token scan_number() {
        const auto start = location();
        while (std::isdigit(static_cast<unsigned char>(peek())) != 0 ||
               peek() == '_') {
            advance();
        }
        if (peek() == '\'') {
            advance();
            if (peek() == 's' || peek() == 'S') {
                advance();
            }
            return scan_based_digits(start);
        }
        return make(TokenKind::Number, start);
    }

    Token scan_unbased_literal() {
        const auto start = location();
        advance();
        if (peek() == '0' || peek() == '1' || peek() == 'x' || peek() == 'X' ||
            peek() == 'z' || peek() == 'Z') {
            advance();
            return make(TokenKind::Number, start);
        }
        if (peek() == 's' || peek() == 'S') {
            advance();
        }
        if (peek() == 'b' || peek() == 'B' || peek() == 'o' || peek() == 'O' ||
            peek() == 'd' || peek() == 'D' || peek() == 'h' || peek() == 'H') {
            return scan_based_digits(start);
        }
        fail(start, "unsupported or malformed apostrophe literal");
    }

    Token scan_string() {
        const auto start = location();
        advance();
        while (!at_end()) {
            if (peek() == '"') {
                advance();
                return make(TokenKind::String, start);
            }
            if (peek() == '\n' || peek() == '\r') {
                fail(start, "newline in string literal");
            }
            if (peek() == '\\') {
                advance();
                if (!at_end()) {
                    advance();
                }
            } else {
                advance();
            }
        }
        fail(start, "unterminated string literal");
    }

    Token scan_macro_quote() {
        const auto start = location();
        advance();
        advance();
        while (!at_end() && peek() != '\n' && peek() != '\r') {
            if (peek() == '`' && peek(1) == '"') {
                advance();
                advance();
                return make(TokenKind::MacroQuoted, start);
            }
            advance();
        }
        fail(start, "unterminated macro quotation");
    }

    Token scan_symbol() {
        static constexpr std::string_view operators[] = {
            "|->", "|=>", "<<<", ">>>", "===", "!==", "==?", "!=?", "~^", "^~", "~&", "~|",
            "&&", "||", "==", "!=", "<=", ">=", "<<", ">>", "##",
            "[*", "->", "+:", "-:", "::", "**", "``"};
        const auto start = location();
        const std::string_view remaining(source_.data() + offset_,
                                         source_.size() - offset_);
        for (const auto candidate : operators) {
            if (remaining.size() >= candidate.size() &&
                remaining.substr(0, candidate.size()) == candidate) {
                for (std::size_t i = 0; i < candidate.size(); ++i) {
                    advance();
                }
                return make(TokenKind::Symbol, start);
            }
        }
        advance();
        return make(TokenKind::Symbol, start);
    }

    Token next_token() {
        const char ch = peek();
        if (identifier_start(ch)) {
            return scan_identifier();
        }
        if (std::isdigit(static_cast<unsigned char>(ch)) != 0) {
            return scan_number();
        }
        if (ch == '\'' && !macro_text_) {
            return scan_unbased_literal();
        }
        if (ch == '`' && peek(1) == '"') return scan_macro_quote();
        if (ch == '"') {
            return scan_string();
        }
        return scan_symbol();
    }

    const std::string& source_;
    const std::string& source_name_;
    bool macro_text_;
    std::size_t offset_ = 0;
    std::size_t line_ = 1;
    std::size_t column_ = 1;
};

} // namespace

LexError::LexError(SourceLocation location, const std::string& message)
    : std::runtime_error(location.file + ":" + std::to_string(location.line) +
                         ":" + std::to_string(location.column) + ": " +
                         message),
      location_(std::move(location)) {}

std::vector<Token> tokenize(const std::string& source,
                            const std::string& source_name) {
    return Scanner(source, source_name).run();
}

std::vector<Token> tokenize_macro_text(const std::string& source,
                                       const std::string& source_name) {
    return Scanner(source, source_name, true).run();
}

const char* token_kind_name(TokenKind kind) noexcept {
    switch (kind) {
    case TokenKind::Identifier: return "identifier";
    case TokenKind::Number: return "number";
    case TokenKind::String: return "string";
    case TokenKind::MacroQuoted: return "macro-quoted";
    case TokenKind::Symbol: return "symbol";
    case TokenKind::End: return "end";
    }
    return "unknown";
}

} // namespace q3a::frontend
