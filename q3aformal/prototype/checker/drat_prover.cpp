#include "drat_prover.hpp"
#include "checker_input.hpp"

#include <algorithm>
#include <charconv>
#include <cstdint>
#include <limits>
#include <new>
#include <sstream>
#include <stdexcept>
#include <string>
#include <utility>

namespace q3a::checker {
namespace {

using Literal = std::int32_t;
using Clause = std::vector<Literal>;
using Formula = std::vector<Clause>;
using detail::MemoryPoller;
using detail::append_allocation;

struct ParsedFormula {
    std::uint32_t variables = 0;
    Formula clauses;
};

class SearchLimit final : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

std::int64_t parse_integer(const std::string& token) {
    std::int64_t value = 0;
    const auto parsed = std::from_chars(
        token.data(), token.data() + token.size(), value);
    if (token.empty() || parsed.ec != std::errc{} ||
        parsed.ptr != token.data() + token.size()) {
        throw std::runtime_error("malformed DIMACS integer '" + token + "'");
    }
    return value;
}

Clause normalize(Clause clause) {
    std::sort(clause.begin(), clause.end(), [](Literal left, Literal right) {
        const auto left_variable = left < 0 ? -static_cast<std::int64_t>(left) : left;
        const auto right_variable = right < 0 ? -static_cast<std::int64_t>(right) : right;
        return left_variable == right_variable ? left < right
                                               : left_variable < right_variable;
    });
    clause.erase(std::unique(clause.begin(), clause.end()), clause.end());
    return clause;
}

ParsedFormula parse_dimacs(std::istream& input, const ProofLimits& limits,
                           MemoryPoller& memory) {
    ParsedFormula result;
    std::uint64_t declared_clauses = 0;
    bool saw_header = false;
    Clause current_clause;
    std::string line;
    std::uint64_t total_literals = 0;
    while (detail::read_bounded_line(input, line, limits.input_limits, "proof search DIMACS input")) {
        memory.poll(line.size());
        std::istringstream row(line);
        std::string token;
        if (!(row >> token) || token == "c") continue;
        if (token == "p") {
            if (saw_header || !result.clauses.empty() || !current_clause.empty()) {
                throw std::runtime_error("duplicate or misplaced DIMACS header");
            }
            std::string format;
            std::string variable_token;
            std::string clause_token;
            std::string extra;
            if (!(row >> format >> variable_token >> clause_token) ||
                (row >> extra) || format != "cnf") {
                throw std::runtime_error("expected 'p cnf <variables> <clauses>'");
            }
            const auto variables = parse_integer(variable_token);
            const auto clauses = parse_integer(clause_token);
            if (variables < 0 || variables > std::numeric_limits<Literal>::max() ||
                clauses < 0) {
                throw std::runtime_error("DIMACS header count is outside the supported range");
            }
            if (static_cast<std::uint64_t>(variables) >
                std::min(limits.maximum_variables, limits.input_limits.maximum_variables)) {
                throw SearchLimit("proof search variable limit exceeded");
            }
            if (static_cast<std::uint64_t>(clauses) > limits.input_limits.maximum_cnf_clauses) {
                throw SearchLimit("proof search CNF clause limit exceeded");
            }
            result.variables = static_cast<std::uint32_t>(variables);
            declared_clauses = static_cast<std::uint64_t>(clauses);
            saw_header = true;
            continue;
        }
        if (!saw_header) {
            throw std::runtime_error("DIMACS data appears before the problem header");
        }
        do {
            if (result.clauses.size() == declared_clauses) {
                throw std::runtime_error("DIMACS clause count disagrees with the problem header");
            }
            const auto value = parse_integer(token);
            if (value == 0) {
                memory.poll(append_allocation(result.clauses));
                result.clauses.push_back(normalize(std::move(current_clause)));
                current_clause.clear();
                continue;
            }
            if (value < std::numeric_limits<Literal>::min() ||
                value > std::numeric_limits<Literal>::max()) {
                throw std::runtime_error("DIMACS literal is outside the supported range");
            }
            const auto variable = value < 0 ? -value : value;
            if (static_cast<std::uint64_t>(variable) > result.variables) {
                throw std::runtime_error("DIMACS literal references an undeclared variable");
            }
            if (total_literals >= limits.input_limits.maximum_cnf_literals) {
                throw SearchLimit("proof search CNF literal limit exceeded");
            }
            ++total_literals;
            memory.poll(append_allocation(current_clause));
            current_clause.push_back(static_cast<Literal>(value));
        } while (row >> token);
    }
    if (!saw_header) throw std::runtime_error("DIMACS input has no problem header");
    if (!current_clause.empty()) {
        throw std::runtime_error("DIMACS input ends before a clause terminator 0");
    }
    if (result.clauses.size() != declared_clauses) {
        throw std::runtime_error("DIMACS clause count disagrees with the problem header");
    }
    return result;
}

bool assign(std::vector<std::int8_t>& values, Literal literal) {
    const auto variable = static_cast<std::size_t>(
        literal < 0 ? -static_cast<std::int64_t>(literal) : literal);
    const auto wanted = static_cast<std::int8_t>(literal > 0 ? 1 : 0);
    auto& current = values[variable];
    if (current < 0) {
        current = wanted;
        return true;
    }
    return current == wanted;
}

bool literal_satisfied(const std::vector<std::int8_t>& values, Literal literal) {
    const auto variable = static_cast<std::size_t>(
        literal < 0 ? -static_cast<std::int64_t>(literal) : literal);
    return values[variable] >= 0 &&
        ((literal > 0) == (values[variable] != 0));
}

bool propagate(const Formula& formula, std::vector<std::int8_t>& values) {
    for (;;) {
        bool changed = false;
        for (const auto& clause : formula) {
            bool satisfied = false;
            std::size_t unassigned = 0;
            Literal unit = 0;
            for (const auto literal : clause) {
                const auto variable = static_cast<std::size_t>(
                    literal < 0 ? -static_cast<std::int64_t>(literal) : literal);
                if (values[variable] < 0) {
                    ++unassigned;
                    unit = literal;
                } else if (literal_satisfied(values, literal)) {
                    satisfied = true;
                    break;
                }
            }
            if (satisfied) continue;
            if (unassigned == 0) return false;
            if (unassigned == 1) {
                const auto variable = static_cast<std::size_t>(
                    unit < 0 ? -static_cast<std::int64_t>(unit) : unit);
                const bool was_unassigned = values[variable] < 0;
                if (!assign(values, unit)) return false;
                changed = changed || was_unassigned;
            }
        }
        if (!changed) return true;
    }
}

enum class SearchStatus { Unsatisfiable, Satisfiable, Unknown };

struct SearchState {
    Formula formula;
    std::vector<Clause> proof;
    const ProofLimits& limits;
    MemoryPoller& memory;
    std::uint32_t variables = 0;
    std::uint64_t nodes = 0;
};

void append_blocking_clause(SearchState& state, const std::vector<Literal>& decisions) {
    if (state.limits.maximum_proof_records != 0 &&
        state.proof.size() >= state.limits.maximum_proof_records) {
        throw SearchLimit("proof record limit exceeded");
    }
    state.memory.poll(2 * decisions.size() * sizeof(Literal) +
                      append_allocation(state.proof) + append_allocation(state.formula));
    Clause blocking;
    blocking.reserve(decisions.size());
    for (const auto decision : decisions) {
        blocking.push_back(static_cast<Literal>(-decision));
    }
    blocking = normalize(std::move(blocking));
    state.proof.push_back(blocking);
    state.formula.push_back(std::move(blocking));
}

SearchStatus search(
    SearchState& state,
    std::vector<std::int8_t> values,
    std::vector<Literal>& decisions,
    std::uint32_t depth) {
    if (state.limits.maximum_search_nodes != 0 &&
        state.nodes >= state.limits.maximum_search_nodes) {
        return SearchStatus::Unknown;
    }
    ++state.nodes;
    state.memory.poll();
    if (!propagate(state.formula, values)) {
        append_blocking_clause(state, decisions);
        return SearchStatus::Unsatisfiable;
    }

    std::uint32_t selected = 0;
    for (std::uint32_t variable = 1; variable <= state.variables; ++variable) {
        if (values[variable] < 0) {
            selected = variable;
            break;
        }
    }
    if (selected == 0) return SearchStatus::Satisfiable;
    if (state.limits.maximum_depth != 0 && depth >= state.limits.maximum_depth) {
        return SearchStatus::Unknown;
    }

    const auto decision = static_cast<Literal>(selected);
    const auto branch_bytes = values.size() + append_allocation(decisions);
    if (branch_bytes >= 256 * 1024) {
        state.memory.check(branch_bytes);
    } else {
        state.memory.poll(branch_bytes);
    }
    auto positive_values = values;
    assign(positive_values, decision);
    decisions.push_back(decision);
    const auto positive = search(state, std::move(positive_values), decisions, depth + 1);
    decisions.pop_back();
    if (positive != SearchStatus::Unsatisfiable) return positive;

    auto negative_values = std::move(values);
    assign(negative_values, static_cast<Literal>(-decision));
    decisions.push_back(static_cast<Literal>(-decision));
    const auto negative = search(state, std::move(negative_values), decisions, depth + 1);
    decisions.pop_back();
    if (negative != SearchStatus::Unsatisfiable) return negative;

    append_blocking_clause(state, decisions);
    return SearchStatus::Unsatisfiable;
}

} // namespace

ProofResult generate_rup_refutation(
    std::istream& cnf_input, const ProofLimits& limits) {
    try {
        MemoryPoller memory(limits.input_limits);
        memory.check();
        auto parsed = parse_dimacs(cnf_input, limits, memory);
        SearchState state{std::move(parsed.clauses), {}, limits, memory, parsed.variables};
        memory.check(static_cast<std::uint64_t>(parsed.variables) + 1);
        std::vector<std::int8_t> initial_values(
            static_cast<std::size_t>(parsed.variables) + 1, -1);
        std::vector<Literal> decisions;
        const auto status = search(state, std::move(initial_values), decisions, 0);
        memory.check();
        ProofResult result;
        result.search_nodes = state.nodes;
        result.additions = std::move(state.proof);
        switch (status) {
        case SearchStatus::Unsatisfiable:
            result.status = ProofStatus::Unsatisfiable;
            result.message = "RUP refutation generated";
            break;
        case SearchStatus::Satisfiable:
            result.status = ProofStatus::Satisfiable;
            result.additions.clear();
            result.message = "CNF is satisfiable; no refutation was generated";
            break;
        case SearchStatus::Unknown:
            result.status = ProofStatus::Unknown;
            result.additions.clear();
            result.message = "proof search reached a configured limit";
            break;
        }
        return result;
    } catch (const SearchLimit& error) {
        return {ProofStatus::Unknown, 0, {}, error.what()};
    } catch (const detail::ResourceLimitError& error) {
        return {ProofStatus::Unknown, 0, {}, error.what()};
    } catch (const std::bad_alloc&) {
        return {ProofStatus::Unknown, 0, {}, "proof search memory allocation failed"};
    } catch (const std::exception& error) {
        return {ProofStatus::Unknown, 0, {}, std::string("invalid CNF: ") + error.what()};
    }
}

void write_rup_proof(const ProofResult& result, std::ostream& output) {
    if (result.status != ProofStatus::Unsatisfiable || result.additions.empty() ||
        !result.additions.back().empty()) {
        throw std::invalid_argument("only a complete UNSAT result can be serialized as DRAT");
    }
    for (const auto& clause : result.additions) {
        for (const auto literal : clause) output << literal << ' ';
        output << "0\n";
    }
    if (!output) throw std::runtime_error("failed to write RUP proof");
}

} // namespace q3a::checker
