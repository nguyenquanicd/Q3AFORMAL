#include "lexer.hpp"
#include "parser.hpp"

#include <algorithm>
#include <iostream>
#include <stdexcept>
#include <string>
#include <utility>

using namespace q3a::frontend;

static void require(bool result, const char* detail) {
    if (!result) throw std::runtime_error(detail);
}

int main() {
    const std::string source =
        "/* banner */\r\nmodule leaf(input logic a, output logic q);\r\n"
        "assign q = a;\r\nendmodule\r\n";
    auto valid = tokenize(source, "leaf.sv");
    const auto assignment = std::find_if(valid.begin(), valid.end(),
        [](const Token& token) { return token.text == "assign"; });
    require(!valid.empty() && valid.front().text == "module" &&
        valid.front().location.file == "leaf.sv" && valid.front().location.line == 2 &&
        valid.front().location.column == 1 && valid.front().location.byte_offset == 14 &&
        assignment != valid.end() && assignment->location.line == 3 &&
        assignment->location.column == 1 && valid.back().kind == TokenKind::End &&
        valid.back().location.byte_offset == source.size(), "lexer contract mismatch");
    const auto unit = parse_source(valid);
    require(unit.modules.size() == 1 && unit.modules[0].name == "leaf" &&
        unit.modules[0].ports.size() == 2 && unit.modules[0].continuous_assignments.size() == 1 &&
        unit.tokens.size() == valid.size(), "parser syntax-unit mismatch");
    std::cout << "PASS typed lexer locations, end marker and parser result\n";

    try {
        tokenize("module broken;\n /* truncated", "broken.sv");
        throw std::runtime_error("lexer accepted an unterminated comment");
    } catch (const LexError& error) {
        require(error.location().file == "broken.sv" && error.location().line == 2 &&
            error.location().column == 2, "lexer failure lost source span");
    }
    try {
        parse_source(tokenize("module leaf(input logic a, output logic q) endmodule", "parse.sv"));
        throw std::runtime_error("parser accepted a missing declaration terminator");
    } catch (const ParseError& error) {
        require(error.location().file == "parse.sv" && error.location().line == 1 &&
            error.kind() == InputDiagnosticKind::Invalid, "parser failure lost diagnostic contract");
    }
    std::cout << "PASS source-located LexError and ParseError\n";

    auto suffix = tokenize("module discarded; endmodule", "second.sv");
    valid.insert(valid.end(), suffix.begin(), suffix.end());
    try {
        (void)parse_source(std::move(valid));
        throw std::runtime_error("parser accepted tokens after an embedded end marker");
    } catch (const ParseError&) {
        std::cout << "PASS parser rejects embedded end marker\n";
    }
}
