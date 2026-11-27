#include "dimacs.hpp"

#include <charconv>
#include <cstdint>
#include <limits>
#include <sstream>
#include <string>
#include <system_error>
#include <vector>

namespace q3a::sat {
namespace {

std::uint64_t parse_unsigned(const std::string& text, const std::string& field,
                             std::size_t line_number) {
    std::uint64_t value = 0;
    const auto parsed = std::from_chars(text.data(), text.data() + text.size(), value);
    if (text.empty() || parsed.ec != std::errc{} ||
        parsed.ptr != text.data() + text.size()) {
        throw DimacsError("line " + std::to_string(line_number) +
                          ": invalid " + field + " value '" + text + "'");
    }
    return value;
}

std::int64_t parse_integer(const std::string& text, std::size_t line_number) {
    std::int64_t value = 0;
    const auto parsed = std::from_chars(text.data(), text.data() + text.size(), value);
    if (text.empty() || parsed.ec != std::errc{} ||
        parsed.ptr != text.data() + text.size()) {
        throw DimacsError("line " + std::to_string(line_number) +
                          ": invalid clause literal '" + text + "'");
    }
    return value;
}

} // namespace

Solver read_dimacs(std::istream& input) {
    Solver solver;
    bool header_seen = false;
    std::uint64_t declared_variables = 0;
    std::uint64_t declared_clauses = 0;
    std::uint64_t completed_clauses = 0;
    std::vector<Literal> pending_clause;
    std::string line;
    std::size_t line_number = 0;

    while (std::getline(input, line)) {
        ++line_number;
        std::istringstream row(line);
        std::string token;
        if (!(row >> token)) continue;
        if (token == "c") continue;

        if (token == "p") {
            if (header_seen || completed_clauses != 0 || !pending_clause.empty()) {
                throw DimacsError("line " + std::to_string(line_number) +
                                  ": DIMACS header must appear once before clauses");
            }
            std::string format;
            std::string variables_text;
            std::string clauses_text;
            std::string extra;
            if (!(row >> format >> variables_text >> clauses_text) || (row >> extra)) {
                throw DimacsError("line " + std::to_string(line_number) +
                                  ": expected 'p cnf <variables> <clauses>'");
            }
            if (format != "cnf") {
                throw DimacsError("line " + std::to_string(line_number) +
                                  ": only DIMACS 'cnf' format is supported");
            }
            declared_variables = parse_unsigned(variables_text, "variable count", line_number);
            declared_clauses = parse_unsigned(clauses_text, "clause count", line_number);
            if (declared_variables > static_cast<std::uint64_t>(
                    std::numeric_limits<Literal>::max())) {
                throw DimacsError("line " + std::to_string(line_number) +
                                  ": variable count exceeds the supported literal range");
            }
            for (std::uint64_t index = 0; index < declared_variables; ++index) {
                solver.new_variable();
            }
            header_seen = true;
            continue;
        }

        if (!header_seen) {
            throw DimacsError("line " + std::to_string(line_number) +
                              ": clause data appears before the DIMACS header");
        }

        do {
            const auto value = parse_integer(token, line_number);
            if (value == 0) {
                solver.add_clause(pending_clause);
                pending_clause.clear();
                ++completed_clauses;
                if (completed_clauses > declared_clauses) {
                    throw DimacsError("line " + std::to_string(line_number) +
                                      ": more clauses than declared in the header");
                }
            } else {
                const auto variable = value < 0
                    ? static_cast<std::uint64_t>(-(value + 1)) + 1
                    : static_cast<std::uint64_t>(value);
                if (variable > declared_variables) {
                    throw DimacsError("line " + std::to_string(line_number) +
                                      ": clause literal exceeds the declared variable count");
                }
                if (value < std::numeric_limits<Literal>::min() ||
                    value > std::numeric_limits<Literal>::max()) {
                    throw DimacsError("line " + std::to_string(line_number) +
                                      ": clause literal exceeds the supported range");
                }
                pending_clause.push_back(static_cast<Literal>(value));
            }
        } while (row >> token);
    }

    if (!header_seen) throw DimacsError("missing DIMACS problem header");
    if (!pending_clause.empty()) {
        throw DimacsError("end of file reached before a clause terminator 0");
    }
    if (completed_clauses != declared_clauses) {
        throw DimacsError("DIMACS clause count does not match the problem header");
    }
    return solver;
}

} // namespace q3a::sat
