#include "drat_checker.hpp"
#include "checker_input.hpp"

#include <algorithm>
#include <charconv>
#include <cstdint>
#include <deque>
#include <limits>
#include <new>
#include <sstream>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace q3a::checker {
namespace {

using Literal = std::int32_t;
using Clause = std::vector<Literal>;
using Formula = std::vector<Clause>;

struct ParsedFormula {
    std::uint32_t variables = 0;
    Formula clauses;
};

using detail::ResourceLimitError;
using detail::MemoryPoller;
using detail::append_allocation;

std::int64_t parse_integer(const std::string& token, const std::string& where) {
    std::int64_t value = 0;
    const auto parsed = std::from_chars(
        token.data(), token.data() + token.size(), value);
    if (token.empty() || parsed.ec != std::errc{} ||
        parsed.ptr != token.data() + token.size()) {
        throw std::runtime_error(where + ": malformed integer '" + token + "'");
    }
    return value;
}

bool literal_less(Literal left, Literal right) {
    const auto left_variable = left < 0 ? -static_cast<std::int64_t>(left) : left;
    const auto right_variable = right < 0 ? -static_cast<std::int64_t>(right) : right;
    return left_variable == right_variable ? left < right : left_variable < right_variable;
}

Clause normalize(Clause clause) {
    std::sort(clause.begin(), clause.end(), literal_less);
    clause.erase(std::unique(clause.begin(), clause.end()), clause.end());
    return clause;
}

bool tautological(const Clause& clause) {
    return std::adjacent_find(clause.begin(), clause.end(), [](Literal left, Literal right) {
        return left == -right;
    }) != clause.end();
}

ParsedFormula parse_dimacs(std::istream& input, const CheckerLimits& limits, MemoryPoller& memory) {
    ParsedFormula result;
    bool saw_header = false;
    std::uint64_t declared_clauses = 0;
    std::uint64_t total_literals = 0;
    Clause current_clause;
    std::string line;
    std::size_t line_number = 0;
    while (detail::read_bounded_line(input, line, limits, "checker DIMACS input")) {
        memory.poll(line.size());
        ++line_number;
        std::istringstream row(line);
        std::string token;
        if (!(row >> token)) continue;
        if (token == "c") continue;
        if (token == "p") {
            if (saw_header || !result.clauses.empty() || !current_clause.empty()) {
                throw std::runtime_error("DIMACS line " + std::to_string(line_number) +
                    ": duplicate or misplaced problem header");
            }
            std::string format;
            std::string variable_token;
            std::string clause_token;
            std::string extra;
            if (!(row >> format >> variable_token >> clause_token) ||
                (row >> extra) || format != "cnf") {
                throw std::runtime_error("DIMACS line " + std::to_string(line_number) +
                    ": expected 'p cnf <variables> <clauses>'");
            }
            const auto variables = parse_integer(variable_token, "DIMACS header");
            const auto clauses = parse_integer(clause_token, "DIMACS header");
            if (variables < 0 || variables > std::numeric_limits<Literal>::max() ||
                clauses < 0) {
                throw std::runtime_error("DIMACS header count is outside the supported range");
            }
            if (static_cast<std::uint64_t>(variables) > limits.maximum_variables) {
                throw ResourceLimitError("DRAT checker variable limit exceeded");
            }
            if (static_cast<std::uint64_t>(clauses) > limits.maximum_cnf_clauses) {
                throw ResourceLimitError("DRAT checker CNF clause limit exceeded");
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
            const auto value = parse_integer(token,
                "DIMACS line " + std::to_string(line_number));
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
            if (variable == 0 ||
                static_cast<std::uint64_t>(variable) > result.variables) {
                throw std::runtime_error("DIMACS literal references an undeclared variable");
            }
            if (total_literals >= limits.maximum_cnf_literals) {
                throw ResourceLimitError("DRAT checker CNF literal limit exceeded");
            }
            ++total_literals;
            memory.poll(append_allocation(current_clause));
            current_clause.push_back(static_cast<Literal>(value));
        } while (row >> token);
    }
    if (input.bad() || !input.eof()) throw std::runtime_error("failed while reading checker DIMACS input");
    if (!saw_header) throw std::runtime_error("DIMACS input has no problem header");
    if (!current_clause.empty()) {
        throw std::runtime_error("DIMACS input ends before a clause terminator 0");
    }
    if (result.clauses.size() != declared_clauses) {
        throw std::runtime_error("DIMACS clause count disagrees with the problem header");
    }
    return result;
}

bool literal_true(const std::vector<std::int8_t>& assignment, Literal literal) {
    const auto variable = static_cast<std::size_t>(
        literal < 0 ? -static_cast<std::int64_t>(literal) : literal);
    const auto value = assignment[variable];
    return value >= 0 && ((literal > 0) == (value != 0));
}

bool literal_false(const std::vector<std::int8_t>& assignment, Literal literal) {
    const auto variable = static_cast<std::size_t>(
        literal < 0 ? -static_cast<std::int64_t>(literal) : literal);
    const auto value = assignment[variable];
    return value >= 0 && ((literal > 0) != (value != 0));
}

std::size_t literal_index(Literal literal) {
    const auto variable = static_cast<std::size_t>(
        literal < 0 ? -static_cast<std::int64_t>(literal) : literal);
    return variable * 2 + (literal < 0 ? 1 : 0);
}

bool rup(const Formula& formula, std::uint32_t variables, const Clause& candidate,
         MemoryPoller& memory) {
    using WatchId = std::uint32_t;
    constexpr auto no_watch = std::numeric_limits<WatchId>::max();
    struct Watch {
        WatchId next;
        std::uint32_t position;
    };
    // Each non-unit clause has two fixed watch slots. Its index and the
    // opposite watch slot can both be recovered from either slot's ID.
    if (formula.size() > static_cast<std::size_t>(no_watch) / 2) {
        throw ResourceLimitError("DRAT checker watch index limit exceeded");
    }
    const auto slots = std::uint64_t{variables} + 1;
    memory.check(slots * (sizeof(std::int8_t) + sizeof(Literal) + 2 * sizeof(WatchId)) +
                 formula.size() * (2 * sizeof(Watch)));
    std::vector<std::int8_t> assignment(static_cast<std::size_t>(variables) + 1, -1);
    std::deque<Literal> propagation_queue;
    const auto enqueue = [&](Literal literal) {
        const auto variable = static_cast<std::size_t>(
            literal < 0 ? -static_cast<std::int64_t>(literal) : literal);
        const auto wanted = static_cast<std::int8_t>(literal > 0 ? 1 : 0);
        auto& current = assignment[variable];
        if (current < 0) {
            current = wanted;
            propagation_queue.push_back(literal);
            return true;
        }
        return current == wanted;
    };

    for (const auto literal : candidate) {
        if (!enqueue(static_cast<Literal>(-literal))) return true;
    }

    std::vector<WatchId> watch_heads(static_cast<std::size_t>(slots) * 2, no_watch);
    std::vector<Watch> watches(formula.size() * 2);
    for (std::size_t clause_index = 0; clause_index < formula.size(); ++clause_index) {
        memory.poll();
        const auto& clause = formula[clause_index];
        if (clause.empty()) return true;
        if (clause.size() == 1) {
            if (!enqueue(clause.front())) return true;
            continue;
        }
        for (std::uint32_t position = 0; position < 2; ++position) {
            const auto watch_id = static_cast<WatchId>(2 * clause_index + position);
            auto& head = watch_heads[literal_index(clause[position])];
            watches[watch_id] = {head, position};
            head = watch_id;
        }
    }

    while (!propagation_queue.empty()) {
        const auto assigned_literal = propagation_queue.front();
        propagation_queue.pop_front();
        const auto falsified_literal = static_cast<Literal>(-assigned_literal);
        auto* link = &watch_heads[literal_index(falsified_literal)];
        while (*link != no_watch) {
            memory.poll();
            const auto watch_id = *link;
            const auto& clause = formula[watch_id / 2];
            auto& watch = watches[watch_id];
            const auto other_position = watches[watch_id ^ 1U].position;
            if (clause[watch.position] != falsified_literal) {
                throw std::runtime_error("internal DRAT checker watch-list invariant failed");
            }

            const auto other_literal = clause[other_position];
            if (literal_true(assignment, other_literal)) {
                link = &watch.next;
                continue;
            }

            bool moved_watch = false;
            for (std::size_t replacement = 0; replacement < clause.size(); ++replacement) {
                if (replacement == other_position || replacement == watch.position) continue;
                if (literal_false(assignment, clause[replacement])) continue;
                // The replacement cannot be the falsified literal. Unlink
                // from this list before inserting at the destination head.
                *link = watch.next;
                auto& head = watch_heads[literal_index(clause[replacement])];
                watch = {head, static_cast<std::uint32_t>(replacement)};
                head = watch_id;
                moved_watch = true;
                break;
            }
            if (moved_watch) continue;

            if (literal_false(assignment, other_literal) || !enqueue(other_literal)) {
                return true;
            }
            link = &watch.next;
        }
    }
    return false;
}

bool rat(const Formula& formula, std::uint32_t variables, const Clause& candidate,
         MemoryPoller& memory) {
    if (candidate.empty()) return false;
    // A DRAT addition is RAT if at least one of its literals is a valid pivot.
    // The chosen pivot is not encoded in the proof line, so the checker must
    // search the full candidate clause instead of assuming the first literal.
    for (const auto pivot : candidate) {
        bool pivot_valid = true;
        for (const auto& existing : formula) {
            memory.poll();
            if (!std::binary_search(existing.begin(), existing.end(), -pivot, literal_less)) {
                continue;
            }
            Clause resolvent;
            memory.poll((candidate.size() + existing.size()) * sizeof(Literal));
            resolvent.reserve(candidate.size() + existing.size());
            for (const auto literal : candidate) {
                if (literal != pivot) resolvent.push_back(literal);
            }
            for (const auto literal : existing) {
                if (literal != -pivot) resolvent.push_back(literal);
            }
            resolvent = normalize(std::move(resolvent));
            if (!tautological(resolvent) && !rup(formula, variables, resolvent, memory)) {
                pivot_valid = false;
                break;
            }
        }
        if (pivot_valid) return true;
    }
    return false;
}

struct ProofRecord {
    bool deletion = false;
    Clause clause;
};

ProofRecord parse_proof_record(std::istringstream& row, std::string token,
                               std::size_t line_number, std::uint32_t variables,
                               std::uint64_t& total_literals, const CheckerLimits& limits,
                               MemoryPoller& memory) {
    ProofRecord record;
    if (token == "d") {
        record.deletion = true;
        if (!(row >> token)) {
            throw std::runtime_error("DRAT line " + std::to_string(line_number) +
                ": deletion record has no clause");
        }
    }
    bool terminated = false;
    for (;;) {
        const auto value = parse_integer(token,
            "DRAT line " + std::to_string(line_number));
        if (value == 0) {
            terminated = true;
            std::string extra;
            if (row >> extra) {
                throw std::runtime_error("DRAT line " + std::to_string(line_number) +
                    ": tokens appear after clause terminator 0");
            }
            break;
        }
        if (value < std::numeric_limits<Literal>::min() ||
            value > std::numeric_limits<Literal>::max()) {
            throw std::runtime_error("DRAT literal is outside the supported range");
        }
        const auto variable = value < 0 ? -value : value;
        if (static_cast<std::uint64_t>(variable) > variables) {
            throw std::runtime_error("DRAT literal references an undeclared variable");
        }
        if (total_literals >= limits.maximum_proof_literals) {
            throw ResourceLimitError("DRAT checker proof literal limit exceeded");
        }
        ++total_literals;
        memory.poll(append_allocation(record.clause));
        record.clause.push_back(static_cast<Literal>(value));
        if (!(row >> token)) break;
    }
    if (!terminated) {
        throw std::runtime_error("DRAT line " + std::to_string(line_number) +
            ": clause has no terminating 0");
    }
    record.clause = normalize(std::move(record.clause));
    return record;
}

} // namespace

CheckResult verify_drat_records(std::istream& cnf_input,
                                const ProofLineReader& next_line,
                                const CheckerLimits& limits,
                                std::optional<std::uint64_t> declared_records) {
    try {
        if (declared_records && *declared_records == 0) {
            throw std::runtime_error("artifact requires at least one proof record");
        }
        MemoryPoller memory(limits);
        memory.check();
        auto formula = parse_dimacs(cnf_input, limits, memory);
        bool derived_empty = false;
        std::uint64_t checked_records = 0;
        std::uint64_t total_literals = 0;
        std::size_t line_number = 0;
        std::string line;
        while (next_line(line)) {
            memory.poll(line.size());
            ++line_number;
            std::istringstream row(line);
            std::string token;
            if (!(row >> token) || token == "c") continue;
            if (declared_records && checked_records == *declared_records) {
                throw std::runtime_error("proof_records does not match the artifact body");
            }
            if (checked_records >= limits.maximum_proof_records) {
                throw ResourceLimitError("DRAT checker proof record limit exceeded");
            }
            if (derived_empty) {
                throw std::runtime_error("proof contains a record after the empty clause");
            }
            auto record = parse_proof_record(row, std::move(token), line_number,
                                            formula.variables, total_literals, limits, memory);
            ++checked_records;
            if (record.deletion) {
                const auto found = std::find(
                    formula.clauses.begin(), formula.clauses.end(), record.clause);
                if (found == formula.clauses.end()) {
                    throw std::runtime_error("deletion record names a clause not in the database");
                }
                formula.clauses.erase(found);
                continue;
            }
            if (!rup(formula.clauses, formula.variables, record.clause, memory) &&
                !rat(formula.clauses, formula.variables, record.clause, memory)) {
                throw std::runtime_error("added clause is neither RUP nor RAT");
            }
            derived_empty = record.clause.empty();
            memory.poll(append_allocation(formula.clauses));
            formula.clauses.push_back(std::move(record.clause));
        }
        if (declared_records && checked_records != *declared_records) {
            throw std::runtime_error("proof_records does not match the artifact body");
        }
        if (!derived_empty) {
            throw std::runtime_error("incomplete DRAT proof: empty clause was not derived");
        }
        memory.check();
        return {true, checked_records, "DRAT proof accepted"};
    } catch (const ResourceLimitError& error) {
        return {false, 0, error.what(), true};
    } catch (const std::bad_alloc&) {
        return {false, 0, "DRAT checker memory allocation failed", true};
    } catch (const std::exception& error) {
        return {false, 0, error.what()};
    }
}

CheckResult verify_drat(std::istream& cnf_input, std::istream& proof_input,
                        const CheckerLimits& limits) {
    return verify_drat_records(cnf_input, [&](std::string& line) {
        return detail::read_bounded_line(proof_input, line, limits, "DRAT proof");
    }, limits);
}

} // namespace q3a::checker
