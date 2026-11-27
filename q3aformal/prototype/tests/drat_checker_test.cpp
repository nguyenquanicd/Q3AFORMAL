#include "../checker/drat_checker.hpp"
#include "../checker/drat_prover.hpp"
#include "../checker/proof_artifact.hpp"

#include <algorithm>
#include <sstream>
#include <stdexcept>
#include <string>
#include <iostream>
#include <array>
#include <cstdint>
#include <random>
#include <vector>

namespace {

void require(bool condition, const std::string& message) {
    if (!condition) throw std::runtime_error(message);
}

q3a::checker::CheckResult check(
    const std::string& cnf, const std::string& proof,
    const q3a::checker::CheckerLimits& limits = {}) {
    std::istringstream cnf_input(cnf);
    std::istringstream proof_input(proof);
    return q3a::checker::verify_drat(cnf_input, proof_input, limits);
}

void check_configurable_resource_limits() {
    using q3a::checker::CheckerLimits;

    CheckerLimits variable_limit;
    variable_limit.maximum_variables = 2;
    const auto too_many_variables = check("p cnf 3 0\n", "0\n", variable_limit);
    require(too_many_variables.resource_limited &&
            too_many_variables.message == "DRAT checker variable limit exceeded",
        "checker did not enforce its configurable variable limit");

    CheckerLimits clause_limit;
    clause_limit.maximum_cnf_clauses = 1;
    const auto too_many_clauses = check(
        "p cnf 1 2\n1 0\n-1 0\n", "0\n", clause_limit);
    require(too_many_clauses.resource_limited &&
            too_many_clauses.message == "DRAT checker CNF clause limit exceeded",
        "checker did not enforce its configurable CNF clause limit");

    CheckerLimits cnf_literal_limit;
    cnf_literal_limit.maximum_variables = 3;
    cnf_literal_limit.maximum_cnf_literals = 2;
    const auto too_many_cnf_literals = check(
        "p cnf 3 1\n1 2 3 0\n", "0\n", cnf_literal_limit);
    require(too_many_cnf_literals.resource_limited &&
            too_many_cnf_literals.message == "DRAT checker CNF literal limit exceeded",
        "checker did not enforce its configurable CNF literal limit");

    // The third literal is on the same line and would otherwise exhaust the
    // literal budget while parsing a clause that the header does not permit.
    const std::string excess_cnf = "p cnf 2 2\n1 0 -1 0 2\n";
    const auto excess_clause = check(excess_cnf, "0\n", cnf_literal_limit);
    require(!excess_clause.accepted && !excess_clause.resource_limited &&
            excess_clause.message == "DIMACS clause count disagrees with the problem header",
        "checker parsed a clause beyond the count declared in the DIMACS header");
    q3a::checker::ProofLimits search_limits;
    search_limits.input_limits = cnf_literal_limit;
    std::istringstream excess_query(excess_cnf);
    const auto search_excess = q3a::checker::generate_rup_refutation(excess_query, search_limits);
    require(search_excess.status == q3a::checker::ProofStatus::Unknown &&
            search_excess.message == "invalid CNF: DIMACS clause count disagrees with the problem header",
        "proof search parsed a clause beyond the count declared in the DIMACS header");
    require(check("p cnf 2 2\n1 0 -1 0\nc after final clause\n\n", "0\n").accepted,
        "comments and blank lines must not count as additional CNF clauses");

    CheckerLimits proof_record_limit;
    proof_record_limit.maximum_proof_records = 1;
    const auto too_many_records = check(
        "p cnf 1 0\n", "1 0\n-1 0\n", proof_record_limit);
    require(too_many_records.resource_limited &&
            too_many_records.message == "DRAT checker proof record limit exceeded",
        "checker did not enforce its configurable proof-record limit");

    CheckerLimits proof_literal_limit;
    proof_literal_limit.maximum_variables = 3;
    proof_literal_limit.maximum_proof_literals = 2;
    const auto too_many_proof_literals = check(
        "p cnf 3 0\n", "1 2 3 0\n", proof_literal_limit);
    require(too_many_proof_literals.resource_limited &&
            too_many_proof_literals.message == "DRAT checker proof literal limit exceeded",
        "checker did not enforce its configurable proof literal limit");

    CheckerLimits exact_boundary;
    exact_boundary.maximum_variables = 2;
    exact_boundary.maximum_cnf_clauses = 2;
    exact_boundary.maximum_cnf_literals = 2;
    exact_boundary.maximum_proof_records = 1;
    exact_boundary.maximum_proof_literals = 0;
    const auto at_limits = check(
        "p cnf 2 2\n1 0\n-1 0\n", "0\n", exact_boundary);
    require(at_limits.accepted && !at_limits.resource_limited,
        "checker rejected a proof exactly at all configured safety ceilings");

    CheckerLimits memory_limit;
    std::uint64_t estimated = 0;
    memory_limit.check_memory = [&](std::uint64_t pending) {
        if (pending > 1024 * 1024) {
            estimated = pending;
            throw std::runtime_error("test allocation would exceed memory");
        }
    };
    const auto stopped = check("p cnf 1000000 2\n1 0\n-1 0\n", "0\n", memory_limit);
    require(!stopped.accepted && stopped.resource_limited && estimated > 1024 * 1024 &&
            stopped.message.find("test allocation would exceed memory") != std::string::npos,
        "checker did not stop before allocating its large watch tables");
    require(check("p cnf 2 2\n1 0\n-1 0\n", "0\n", memory_limit).accepted,
        "checker memory policy changed a proof that fits its limit");

    const std::string sparse_cnf = "p cnf 1000000 3\n1 -1000000 0\n-1 0\n1000000 0\n";
    std::uint64_t maximum_pending = 0;
    memory_limit.check_memory = [&](std::uint64_t pending) {
        maximum_pending = std::max(maximum_pending, pending);
        if (pending > 16 * 1024 * 1024) {
            throw std::runtime_error("test RUP workspace exceeds 16 MiB");
        }
    };
    const auto checked_sparse = check(sparse_cnf, "0\n", memory_limit);
    require(checked_sparse.accepted && checked_sparse.proof_records == 1 &&
            maximum_pending > 1024 * 1024 && maximum_pending <= 16 * 1024 * 1024,
        "compact watch storage did not verify the sparse high-index proof within budget");
    const auto invalid_sparse = check(
        "p cnf 1000000 3\n1 -1000000 0\n-1 0\n-1000000 0\n", "0\n", memory_limit);
    require(!invalid_sparse.accepted && !invalid_sparse.resource_limited &&
            invalid_sparse.message == "added clause is neither RUP nor RAT",
        "the sparse workspace accepted a false empty-clause claim");
}

void check_stream_line_limits() {
    using namespace q3a::checker;
    const std::string cnf = "p cnf 1 2\n1 0\n-1 0\n";
    const std::string comment = "c " + std::string(16382, 'x');
    CheckerLimits limit;
    limit.maximum_line_bytes = comment.size();
    require(check(comment + "\n" + cnf, comment + "\n0", limit).accepted,
        "multi-chunk DIMACS/DRAT lines at the byte limit, including an unterminated final proof line, must pass");
    require(check(cnf, "c " + std::string(4093, 'x') + "\n0\n", limit).accepted,
        "a line ending at the chunk boundary must not consume the next record");
    require(check(comment + "x\n" + cnf, "0\n", limit).resource_limited,
        "oversized DIMACS comment must stop at the byte limit");
    require(check(cnf, comment + "x\n0\n", limit).resource_limited,
        "oversized raw proof comment must stop at the byte limit");

    const ArtifactMetadata metadata{
        "induction-base", kCheckerId, std::string(64, 'a'), std::string(64, 'b')};
    std::istringstream raw("0\n");
    std::ostringstream artifact;
    require(write_drat_artifact(raw, 1, metadata, artifact).accepted,
        "could not create test artifact");
    const auto verify = [&](const std::string& contents, const CheckerLimits& fit) {
        std::istringstream query(cnf);
        std::istringstream input(contents);
        return verify_drat_artifact(query, input, metadata, fit);
    };
    const auto clean = artifact.str();
    const auto proof_body = clean.find("proof_begin\n") + std::string("proof_begin\n").size();
    require(verify(clean, limit).accepted, "ordinary artifact failed the line limit");
    require(verify(comment + "x\n" + clean, limit).resource_limited,
        "oversized artifact header must report a resource limit");
    require(verify(clean.substr(0, proof_body) + comment + "x\n" +
                   clean.substr(proof_body), limit).resource_limited,
        "oversized proof body must report a resource limit");
    require(verify(clean + std::string(comment.size() + 1, ' '), limit).resource_limited,
        "oversized trailer must report a resource limit");

    limit.check_memory = [](std::uint64_t pending) {
        if (pending > 4096) throw std::runtime_error("test input allocation exceeds memory");
    };
    const auto memory_stopped = check(cnf, comment + "\n0\n", limit);
    require(memory_stopped.resource_limited &&
            memory_stopped.message.find("test input allocation exceeds memory") != std::string::npos,
        "raw proof reader did not consult the budget before growing its buffer");
    require(verify(comment + "\n" + clean, limit).resource_limited,
        "wrapper header reader did not consult the budget before growing its buffer");
}

using SmallClause = std::vector<int>;
using SmallFormula = std::vector<SmallClause>;
struct SmallFormulaOracleResult {
    std::size_t checked_candidate_proofs = 0;
    std::size_t sat_destroying_additions = 0;
    std::size_t checked_rup_additions = 0;
};

bool small_formula_is_satisfiable(
    const SmallFormula& formula, const SmallClause* extra_clause = nullptr,
    unsigned variable_count = 2) {
    for (unsigned assignment = 0; assignment < (1U << variable_count);
         ++assignment) {
        const auto clause_is_true = [assignment](const SmallClause& clause) {
            for (const auto literal : clause) {
                const auto variable = static_cast<unsigned>(
                    literal < 0 ? -literal : literal) - 1;
                const bool value = ((assignment >> variable) & 1U) != 0;
                if ((literal > 0) == value) return true;
            }
            return false;
        };
        bool formula_is_true = true;
        for (const auto& clause : formula) {
            if (!clause_is_true(clause)) {
                formula_is_true = false;
                break;
            }
        }
        if (formula_is_true &&
            (extra_clause == nullptr || clause_is_true(*extra_clause))) {
            return true;
        }
    }
    return false;
}

bool small_formula_rup(const SmallFormula& formula,
                       unsigned variable_count,
                       const SmallClause& candidate) {
    std::vector<std::int8_t> assignment(variable_count + 1U, -1);
    const auto enqueue = [&assignment](int literal) {
        const auto variable = static_cast<std::size_t>(
            literal < 0 ? -literal : literal);
        const auto wanted = static_cast<std::int8_t>(literal > 0 ? 1 : 0);
        auto& current = assignment[variable];
        if (current < 0) {
            current = wanted;
            return 1;
        }
        return current == wanted ? 0 : -1;
    };
    for (const auto literal : candidate) {
        if (enqueue(-literal) < 0) return true;
    }

    for (;;) {
        bool changed = false;
        for (const auto& clause : formula) {
            bool satisfied = false;
            std::size_t unassigned_count = 0;
            int unit = 0;
            for (const auto literal : clause) {
                const auto variable = static_cast<std::size_t>(
                    literal < 0 ? -literal : literal);
                const auto value = assignment[variable];
                if (value < 0) {
                    ++unassigned_count;
                    unit = literal;
                } else if ((literal > 0) == (value != 0)) {
                    satisfied = true;
                    break;
                }
            }
            if (satisfied) continue;
            if (unassigned_count == 0) return true;
            if (unassigned_count == 1) {
                const auto result = enqueue(unit);
                if (result < 0) return true;
                changed = changed || result > 0;
            }
        }
        if (!changed) return false;
    }
}

bool small_clause_tautological(const SmallClause& clause) {
    for (const auto literal : clause) {
        if (std::find(clause.begin(), clause.end(), -literal) != clause.end()) {
            return true;
        }
    }
    return false;
}

bool small_formula_rat(const SmallFormula& formula,
                       unsigned variable_count,
                       const SmallClause& candidate) {
    if (candidate.empty()) return false;
    for (const auto pivot : candidate) {
        bool pivot_valid = true;
        for (const auto& existing : formula) {
            if (std::find(existing.begin(), existing.end(), -pivot) ==
                existing.end()) {
                continue;
            }
            // The DRAT-trim AT obligation retains the pivot in the candidate.
            SmallClause resolvent = candidate;
            for (const auto literal : existing) {
                if (literal != -pivot) resolvent.push_back(literal);
            }
            if (!small_clause_tautological(resolvent) &&
                !small_formula_rup(formula, variable_count, resolvent)) {
                pivot_valid = false;
                break;
            }
        }
        if (pivot_valid) return true;
    }
    return false;
}

std::string small_formula_dimacs(const SmallFormula& formula,
                                 unsigned variable_count = 2);

void check_full_scan_rup_chain_with_watch_moves() {
    const SmallFormula formula{
        {1, 2, 3}, {-1, 4}, {4, -2}, {2, -3}, {5, -4}};
    const SmallClause first_addition{5};
    const SmallClause second_addition{4};
    require(small_formula_is_satisfiable(formula, nullptr, 5),
        "watch-move RUP-chain base formula must be satisfiable");
    require(small_formula_rup(formula, 5, first_addition),
        "full-scan oracle did not classify the first addition as RUP");
    auto after_first = formula;
    after_first.push_back(first_addition);
    require(small_formula_rup(after_first, 5, second_addition),
        "full-scan oracle did not classify the second addition as RUP");

    const auto cnf = small_formula_dimacs(formula, 5);
    const std::string prefix = "5 0\n4 0\nd 5 0\n";
    const auto prefix_result = check(cnf, prefix);
    require(!prefix_result.accepted && !prefix_result.resource_limited &&
            prefix_result.message == "incomplete DRAT proof: empty clause was not derived",
        "checker did not process the full RUP-addition/deletion prefix");
    const auto empty_result = check(cnf, prefix + "0\n");
    require(!empty_result.accepted && !empty_result.resource_limited &&
            empty_result.message == "added clause is neither RUP nor RAT",
        "checker accepted an empty clause after a sound RUP chain and deletion");
}

std::string small_formula_dimacs(const SmallFormula& formula,
                                 unsigned variable_count) {
    std::ostringstream output;
    output << "p cnf " << variable_count << ' ' << formula.size() << '\n';
    for (const auto& clause : formula) {
        for (const auto literal : clause) output << literal << ' ';
        output << "0\n";
    }
    return output.str();
}

std::string addition_then_empty_proof(const SmallClause& clause) {
    std::ostringstream output;
    for (const auto literal : clause) output << literal << ' ';
    output << "0\n0\n";
    return output.str();
}

std::string single_addition_proof(const SmallClause& clause) {
    std::ostringstream output;
    for (const auto literal : clause) output << literal << ' ';
    output << "0\n";
    return output.str();
}

SmallFormulaOracleResult check_small_formula_sat_preservation() {
    // Ternary choices encode each variable as absent, positive, or negative.
    // This yields every non-tautological clause over two variables, including
    // the empty clause, without depending on the production normalizer.
    std::vector<SmallClause> clauses;
    for (unsigned encoding = 0; encoding < 9; ++encoding) {
        auto remaining = encoding;
        SmallClause clause;
        for (int variable = 1; variable <= 2; ++variable) {
            const auto choice = remaining % 3;
            remaining /= 3;
            if (choice == 1) clause.push_back(variable);
            if (choice == 2) clause.push_back(-variable);
        }
        clauses.push_back(std::move(clause));
    }

    std::size_t checked_candidate_proofs = 0;
    std::size_t sat_destroying_additions = 0;
    std::size_t checked_rup_additions = 0;
    for (unsigned formula_mask = 0; formula_mask < (1U << clauses.size());
         ++formula_mask) {
        SmallFormula formula;
        for (std::size_t clause_index = 0; clause_index < clauses.size();
             ++clause_index) {
            if ((formula_mask & (1U << clause_index)) != 0) {
                formula.push_back(clauses[clause_index]);
            }
        }
        if (!small_formula_is_satisfiable(formula)) continue;

        const auto cnf = small_formula_dimacs(formula);
        for (const auto& candidate : clauses) {
            if (candidate.empty()) continue;
            if (small_formula_rup(formula, 2, candidate)) {
                const auto prefix_result = check(
                    cnf, single_addition_proof(candidate));
                require(!prefix_result.accepted &&
                        !prefix_result.resource_limited &&
                        prefix_result.message ==
                            "incomplete DRAT proof: empty clause was not derived",
                    "watched-literal checker disagreed with full-scan RUP oracle "
                    "on a two-variable addition");
                ++checked_rup_additions;
            }
            const bool remains_satisfiable =
                small_formula_is_satisfiable(formula, &candidate);
            // Any purported refutation from a satisfiable base formula must
            // be rejected. A sound RUP/RAT addition preserves satisfiability;
            // an unsound addition must itself fail RUP/RAT checking.
            const auto result = check(cnf, addition_then_empty_proof(candidate));
            require(!result.accepted,
                "DRAT checker derived UNSAT from a satisfiable two-variable formula");
            ++checked_candidate_proofs;
            if (!remains_satisfiable) ++sat_destroying_additions;
        }
    }
    require(checked_candidate_proofs == 760 && sat_destroying_additions == 224,
        "small-formula soundness oracle did not cover all expected cases");
    require(checked_rup_additions > 0,
        "two-variable full-scan RUP oracle did not check any positive additions");
    return {checked_candidate_proofs, sat_destroying_additions,
            checked_rup_additions};
}

SmallFormulaOracleResult check_three_variable_sat_preservation_sample() {
    // Generate every non-tautological clause over three variables. Formula
    // samples are deterministic, while satisfiability is independently
    // decided by enumerating all eight assignments.
    std::vector<SmallClause> clauses;
    for (unsigned encoding = 1; encoding < 27; ++encoding) {
        auto remaining = encoding;
        SmallClause clause;
        for (int variable = 1; variable <= 3; ++variable) {
            const auto choice = remaining % 3;
            remaining /= 3;
            if (choice == 1) clause.push_back(variable);
            if (choice == 2) clause.push_back(-variable);
        }
        clauses.push_back(std::move(clause));
    }

    std::uint32_t state = 0x51434133U;
    const auto clause_mask = (std::uint32_t{1} << clauses.size()) - 1U;
    std::size_t checked_candidate_proofs = 0;
    std::size_t sat_destroying_additions = 0;
    std::size_t checked_rup_additions = 0;
    std::size_t satisfiable_formula_samples = 0;
    for (unsigned sample = 0; sample < 128; ++sample) {
        const unsigned divisor = std::array<unsigned, 4>{2U, 3U, 5U, 8U}[sample % 4U];
        std::uint32_t formula_mask = 0;
        for (std::size_t index = 0; index < clauses.size(); ++index) {
            state = state * 1664525U + 1013904223U;
            if (state % divisor == 0) {
                formula_mask |= std::uint32_t{1} << index;
            }
        }
        if (sample == 0) formula_mask = 0;
        if (sample == 1) formula_mask = clause_mask;

        SmallFormula formula;
        for (std::size_t index = 0; index < clauses.size(); ++index) {
            if ((formula_mask & (std::uint32_t{1} << index)) != 0) {
                formula.push_back(clauses[index]);
            }
        }
        if (!small_formula_is_satisfiable(formula, nullptr, 3)) continue;
        ++satisfiable_formula_samples;
        const auto cnf = small_formula_dimacs(formula, 3);
        for (const auto& candidate : clauses) {
            if (small_formula_rup(formula, 3, candidate)) {
                const auto prefix_result = check(
                    cnf, single_addition_proof(candidate));
                require(!prefix_result.accepted &&
                        !prefix_result.resource_limited &&
                        prefix_result.message ==
                            "incomplete DRAT proof: empty clause was not derived",
                    "watched-literal checker disagreed with full-scan RUP oracle "
                    "on a three-variable addition");
                ++checked_rup_additions;
            }
            const bool remains_satisfiable =
                small_formula_is_satisfiable(formula, &candidate, 3);
            const auto result = check(cnf, addition_then_empty_proof(candidate));
            require(!result.accepted,
                "DRAT checker derived UNSAT from a sampled satisfiable three-variable formula");
            ++checked_candidate_proofs;
            if (!remains_satisfiable) ++sat_destroying_additions;
        }
    }
    require(satisfiable_formula_samples >= 75 &&
            checked_candidate_proofs >= 1800 &&
            sat_destroying_additions >= 1 && checked_rup_additions > 0,
        "three-variable SAT-preservation sample did not exercise enough cases: " +
            std::to_string(satisfiable_formula_samples) + " satisfiable formulae, " +
            std::to_string(checked_candidate_proofs) + " candidate proofs, " +
            std::to_string(sat_destroying_additions) + " satisfiability-destroying additions, " +
            std::to_string(checked_rup_additions) + " positive RUP additions");
    return {checked_candidate_proofs, sat_destroying_additions,
            checked_rup_additions};
}

struct RatOracleResult {
    std::size_t accepted_additions = 0;
    std::size_t rejected_additions = 0;
    std::size_t rat_only_additions = 0;
};

RatOracleResult check_three_variable_rat_differential_sample() {
    std::vector<SmallClause> clauses;
    for (unsigned encoding = 1; encoding < 27; ++encoding) {
        auto remaining = encoding;
        SmallClause clause;
        for (int variable = 1; variable <= 3; ++variable) {
            const auto choice = remaining % 3;
            remaining /= 3;
            if (choice == 1) clause.push_back(variable);
            if (choice == 2) clause.push_back(-variable);
        }
        clauses.push_back(std::move(clause));
    }

    std::uint32_t state = 0x51434133U;
    const auto clause_mask = (std::uint32_t{1} << clauses.size()) - 1U;
    RatOracleResult result;
    for (unsigned sample = 0; sample < 128; ++sample) {
        const unsigned divisor = std::array<unsigned, 4>{2U, 3U, 5U, 8U}[sample % 4U];
        std::uint32_t formula_mask = 0;
        for (std::size_t index = 0; index < clauses.size(); ++index) {
            state = state * 1664525U + 1013904223U;
            if (state % divisor == 0) {
                formula_mask |= std::uint32_t{1} << index;
            }
        }
        if (sample == 0) formula_mask = 0;
        if (sample == 1) formula_mask = clause_mask;

        SmallFormula formula;
        for (std::size_t index = 0; index < clauses.size(); ++index) {
            if ((formula_mask & (std::uint32_t{1} << index)) != 0) {
                formula.push_back(clauses[index]);
            }
        }
        const auto cnf = small_formula_dimacs(formula, 3);
        for (const auto& candidate : clauses) {
            const bool expected_rup = small_formula_rup(formula, 3, candidate);
            const bool expected_rat = small_formula_rat(formula, 3, candidate);
            const auto checker_result = check(cnf, single_addition_proof(candidate));
            if (expected_rup || expected_rat) {
                require(!checker_result.accepted && !checker_result.resource_limited &&
                        checker_result.message ==
                            "incomplete DRAT proof: empty clause was not derived",
                    "DRAT checker rejected an addition accepted by the independent three-variable RUP/RAT oracle");
                ++result.accepted_additions;
                if (expected_rat && !expected_rup) ++result.rat_only_additions;
            } else {
                require(!checker_result.accepted && !checker_result.resource_limited &&
                        checker_result.message == "added clause is neither RUP nor RAT",
                    "DRAT checker accepted an addition rejected by the independent three-variable RUP/RAT oracle");
                ++result.rejected_additions;
            }
        }
    }
    require(result.accepted_additions + result.rejected_additions == 128U * 26U &&
            result.rat_only_additions > 0,
        "three-variable RUP/RAT differential did not cover the expected clauses and RAT-only cases");
    return result;
}

void check_multistep_formula_updates() {
    constexpr unsigned variables = 4;
    constexpr unsigned samples = 160;
    constexpr unsigned updates = 12;
    SmallFormula candidates;
    for (unsigned encoding = 1; encoding < 81; ++encoding) {
        auto remaining = encoding;
        SmallClause clause;
        for (int variable = 1; variable <= static_cast<int>(variables); ++variable) {
            const auto sign = remaining % 3;
            remaining /= 3;
            if (sign != 0) clause.push_back(sign == 1 ? variable : -variable);
        }
        candidates.push_back(std::move(clause));
    }
    std::mt19937 random(0x51413341U);
    std::size_t rat_only = 0, invalid_additions = 0, missing_deletions = 0;
    std::size_t duplicate_deletions = 0, valid_empty = 0, invalid_empty = 0;
    for (unsigned sample = 0; sample < samples; ++sample) {
        SmallFormula formula;
        for (unsigned clause = 0; clause < 4 + sample % 14; ++clause) {
            formula.push_back(candidates[random() % candidates.size()]);
        }
        formula.push_back(formula.front());
        const auto cnf = small_formula_dimacs(formula, variables);
        std::string prefix;
        for (unsigned step = 0; step < updates; ++step) {
            const auto& candidate = candidates[random() % candidates.size()];
            const auto line = single_addition_proof(candidate);
            const auto where = " at sample " + std::to_string(sample) +
                               " step " + std::to_string(step);
            if (step % 3 == 0) {
                const auto deletion = step == 0 ? formula.begin() :
                    formula.begin() + random() % formula.size();
                if (std::count(formula.begin(), formula.end(), *deletion) > 1) {
                    ++duplicate_deletions;
                }
                auto clause = *deletion;
                std::reverse(clause.begin(), clause.end());
                prefix += "d " + single_addition_proof(clause);
                formula.erase(deletion);
            } else {
                const bool rup = small_formula_rup(formula, variables, candidate);
                const bool rat = !rup && small_formula_rat(formula, variables, candidate);
                if (rup || rat) {
                    const bool was_sat = small_formula_is_satisfiable(formula, nullptr, variables);
                    formula.push_back(candidate);
                    require(was_sat == small_formula_is_satisfiable(formula, nullptr, variables),
                            "independent oracle addition changed satisfiability" + where);
                    prefix += line;
                    if (rat) ++rat_only;
                } else {
                    const auto bad = check(cnf, prefix + line + "0\n");
                    require(!bad.accepted && bad.message == "added clause is neither RUP nor RAT",
                            "invalid addition received the wrong verdict" + where);
                    ++invalid_additions;
                }
            }
            if (std::find(formula.begin(), formula.end(), candidate) == formula.end()) {
                const auto bad = check(cnf, prefix + "d " + line + "0\n");
                require(!bad.accepted &&
                        bad.message == "deletion record names a clause not in the database",
                        "missing deletion received the wrong verdict" + where);
                ++missing_deletions;
            }
            const bool expected = small_formula_rup(formula, variables, {});
            const auto result = check(cnf, prefix + "0\n");
            require(result.accepted == expected && !result.resource_limited &&
                    (expected || result.message == "added clause is neither RUP nor RAT"),
                    "watched checker diverged from full-scan prefix oracle" + where);
            if (result.accepted) {
                require(!small_formula_is_satisfiable(formula, nullptr, variables),
                        "terminal proof accepted in a satisfiable formula" + where);
                ++valid_empty;
            } else {
                ++invalid_empty;
            }
        }
    }
    require(valid_empty > 0 && invalid_empty > 0 && duplicate_deletions > 0 &&
            rat_only > 0 && invalid_additions > 0 && missing_deletions > 0,
            "multi-step oracle coverage is incomplete");
    std::cout << "PASS: " << valid_empty + invalid_empty
              << " four-variable proof prefixes (" << valid_empty << " refutations, "
              << invalid_empty << " rejected empty clauses), " << rat_only
              << " RAT-only additions, " << invalid_additions << " rejected additions, "
              << missing_deletions << " rejected deletions, and " << duplicate_deletions
              << " single-copy deletions of duplicate clauses.\n";
}

} // namespace

int main() {
    check_configurable_resource_limits();
    check_stream_line_limits();
    check_full_scan_rup_chain_with_watch_moves();
    check_multistep_formula_updates();
    std::cout << "PASS: independent full-scan RUP oracle validates a multi-step chain "
                 "that relocates watched literals.\n";

    const auto unit_conflict = check(
        "c unit conflict\np cnf 1 2\n1 0\n-1 0\n", "0\n");
    require(unit_conflict.accepted,
        "checker rejected the empty-clause proof for a unit-conflict CNF");

    const auto branching_proof = check(
        "p cnf 2 4\n1 2 0\n1 -2 0\n-1 2 0\n-1 -2 0\n",
        "1 0\n-1 0\n0\n");
    require(branching_proof.accepted,
        "checker rejected a valid multi-step RUP refutation");

    const auto rat_and_deletion = check(
        "p cnf 2 3\n1 0\n-1 0\n1 2 0\n",
        "2 0\nd 2 0\n0\n");
    require(rat_and_deletion.accepted,
        "checker rejected a valid RAT addition, deletion, and final refutation");

    const std::string contradictory_units = "p cnf 1 2\n1 0\n-1 0\n";
    const auto tautological_addition = check(
        contradictory_units, "1 -1 0\n0\n");
    require(tautological_addition.accepted,
        "checker rejected a tautological DRAT addition before a valid refutation");
    const auto tautology_cannot_refute_sat = check(
        "p cnf 1 0\n", "1 -1 0\n0\n");
    require(!tautology_cannot_refute_sat.accepted &&
            tautology_cannot_refute_sat.message ==
                "added clause is neither RUP nor RAT",
        "tautological addition led the checker to accept a false empty-clause claim");
    const auto duplicate_literal_addition = check(
        contradictory_units, "1 1 0\n0\n");
    require(duplicate_literal_addition.accepted,
        "checker rejected a valid RUP addition containing a duplicate literal");
    const auto normalized_tautology_deletion = check(
        contradictory_units, "1 -1 0\nd 1 1 -1 0\n0\n");
    require(normalized_tautology_deletion.accepted,
        "checker did not normalize literal order/duplicates when processing deletion");

    const std::string satisfiable_cnf = "p cnf 2 1\n1 2 0\n";
    const std::string satisfiable_prefix =
        "1 0\n2 0\nd 1 0\n-1 0\nd -1 0\n";
    const auto accepted_sat_prefix = check(satisfiable_cnf, satisfiable_prefix);
    require(!accepted_sat_prefix.accepted &&
            accepted_sat_prefix.message ==
                "incomplete DRAT proof: empty clause was not derived",
        "checker did not accept all valid RAT additions and deletions in the satisfiable prefix");
    const auto sat_chain_then_empty = check(
        satisfiable_cnf, satisfiable_prefix + "0\n");
    require(!sat_chain_then_empty.accepted &&
            sat_chain_then_empty.message == "added clause is neither RUP nor RAT",
        "checker accepted a multi-step RAT/deletion trace that derives empty from SAT");

    const auto non_first_pivot_rat = check(
        "p cnf 5 5\n-1 5 0\n3 4 0\n3 -4 0\n-3 4 0\n-3 -4 0\n",
        "1 2 0\n3 0\n-3 0\n0\n");
    require(non_first_pivot_rat.accepted,
        "checker must find a valid RAT pivot beyond the first clause literal");

    const auto non_rup_addition = check(
        "p cnf 1 1\n-1 0\n", "1 0\n0\n");
    require(!non_rup_addition.accepted,
        "checker accepted a clause that is neither RUP nor RAT");

    const auto absent_deletion = check(
        "p cnf 1 2\n1 0\n-1 0\n", "d 1 0\n0\n");
    require(!absent_deletion.accepted,
        "checker accepted deletion of a clause not present in the proof database");

    const auto out_of_range = check(
        "p cnf 1 1\n1 0\n", "2 0\n0\n");
    require(!out_of_range.accepted,
        "checker accepted a proof literal outside the DIMACS variable range");

    const auto incomplete = check(
        "p cnf 1 2\n1 0\n-1 0\n", "");
    require(!incomplete.accepted,
        "checker accepted a proof that does not derive the empty clause");

    const auto malformed_cnf = check(
        "p cnf 1 2\n1 0\n", "0\n");
    require(!malformed_cnf.accepted,
        "checker accepted a CNF whose clause count disagrees with its header");

    const auto over_limit_variables = check(
        "p cnf 1000001 0\n", "0\n");
    require(!over_limit_variables.accepted &&
            over_limit_variables.resource_limited &&
            over_limit_variables.message == "DRAT checker variable limit exceeded",
        "checker did not return an explicit resource-limit result for excessive variables");

    const std::string branching_cnf =
        "p cnf 2 4\n1 2 0\n1 -2 0\n-1 2 0\n-1 -2 0\n";
    std::istringstream prover_input(branching_cnf);
    const auto generated = q3a::checker::generate_rup_refutation(prover_input);
    require(generated.status == q3a::checker::ProofStatus::Unsatisfiable,
        "independent proof search did not refute a known-unsatisfiable CNF");
    std::ostringstream generated_proof;
    q3a::checker::write_rup_proof(generated, generated_proof);
    const auto generated_check = check(branching_cnf, generated_proof.str());
    require(generated_check.accepted,
        "independent proof checker rejected proof generated by the proof search");

    const q3a::checker::ArtifactMetadata metadata{
        "bounded-query",
        "q3a-drat-checker-0.2",
        std::string(64, 'a'),
        std::string(64, 'b')
    };
    std::ostringstream artifact_output;
    const auto artifact_write = q3a::checker::write_drat_artifact(
        generated, metadata, artifact_output);
    require(artifact_write.accepted,
        "proof writer rejected a complete DRAT refutation");
    std::istringstream artifact_cnf(branching_cnf);
    std::istringstream artifact_input(artifact_output.str());
    const auto artifact_check = q3a::checker::verify_drat_artifact(
        artifact_cnf, artifact_input, metadata);
    require(artifact_check.accepted,
        "artifact checker rejected matching schema and identity hashes");

    const auto check_wrapped = [&](const std::string& artifact,
                                   const q3a::checker::CheckerLimits& limits = {}) {
        std::istringstream cnf(branching_cnf);
        std::istringstream input(artifact);
        return q3a::checker::verify_drat_artifact(cnf, input, metadata, limits);
    };
    const auto wrapped_text = artifact_output.str();
    const auto end_at = wrapped_text.rfind("proof_end\n");
    require(end_at != std::string::npos, "wrapped proof has no generated trailer");
    require(!check_wrapped(wrapped_text.substr(0, end_at)).accepted,
        "streaming checker accepted a proof with no proof_end");
    require(!check_wrapped(wrapped_text + "c unexpected trailer\n").accepted,
        "streaming checker accepted data after proof_end");
    auto late_record = wrapped_text;
    late_record.insert(end_at, "1 0\n");
    require(!check_wrapped(late_record).accepted,
        "streaming checker accepted a record after deriving empty");
    auto bad_count = wrapped_text;
    const auto count_at = bad_count.find("proof_records ") +
        std::string("proof_records ").size();
    bad_count.replace(count_at, bad_count.find('\n', count_at) - count_at,
                      std::to_string(artifact_write.proof_records + 1));
    const auto missing_record = check_wrapped(bad_count);
    require(!missing_record.accepted && !missing_record.resource_limited &&
            missing_record.message.find("proof_records does not match") != std::string::npos,
        "streaming checker ignored the declared record count");

    const auto line_end = wrapped_text.find('\n', count_at);
    auto zero_count = wrapped_text;
    zero_count.replace(count_at, line_end - count_at, "0");
    std::istringstream unread_query("invalid query must not be parsed");
    std::istringstream zero_input(zero_count);
    const auto zero = q3a::checker::verify_drat_artifact(unread_query, zero_input, metadata);
    require(!zero.accepted && !zero.resource_limited && unread_query.tellg() == 0 &&
            zero.message.find("at least one proof record") != std::string::npos,
        "a zero-record artifact must be rejected before reading its CNF");

    auto excess_record = wrapped_text;
    const auto body_at = excess_record.find("proof_begin\n") + std::string("proof_begin\n").size();
    excess_record.replace(body_at, end_at - body_at, "1 0\nc comment\n\n-1 0\n0\n");
    excess_record.replace(count_at, line_end - count_at, "1");
    q3a::checker::CheckerLimits one_literal;
    one_literal.maximum_proof_literals = 1;
    const auto excess = check_wrapped(excess_record, one_literal);
    require(!excess.accepted && !excess.resource_limited &&
            excess.message.find("proof_records does not match") != std::string::npos,
        "an excess proof record was parsed instead of being rejected by its declared count");

    auto commented = wrapped_text;
    commented.insert(end_at, "c after the final clause\n\n");
    require(check_wrapped(commented).accepted,
        "blank and comment lines inside the proof must not count as records");
    std::string crlf;
    for (const auto character : wrapped_text) {
        if (character == '\n') crlf.push_back('\r');
        crlf.push_back(character);
    }
    require(check_wrapped(crlf).accepted,
        "streaming checker rejected a CRLF-formatted proof artifact");

    q3a::checker::CheckerLimits artifact_record_limit;
    artifact_record_limit.maximum_proof_records = 0;
    std::istringstream limited_artifact_cnf(branching_cnf);
    std::istringstream limited_artifact_input(artifact_output.str());
    const auto limited_artifact = q3a::checker::verify_drat_artifact(
        limited_artifact_cnf, limited_artifact_input, metadata,
        artifact_record_limit);
    require(!limited_artifact.accepted && limited_artifact.resource_limited &&
            limited_artifact.message == "DRAT checker proof record limit exceeded",
        "proof artifact wrapper did not propagate its configurable record limit");

    std::istringstream mismatch_cnf(branching_cnf);
    std::istringstream mismatch_artifact(artifact_output.str());
    auto wrong_model = metadata;
    wrong_model.model_sha256 = std::string(64, 'c');
    require(!q3a::checker::verify_drat_artifact(
        mismatch_cnf, mismatch_artifact, wrong_model).accepted,
        "artifact checker accepted a different expected model hash");

    std::istringstream wrong_checker_cnf(branching_cnf);
    std::istringstream wrong_checker_artifact(artifact_output.str());
    auto wrong_checker = metadata;
    wrong_checker.checker_id = "q3a-drat-checker-0.1";
    const auto checker_mismatch = q3a::checker::verify_drat_artifact(
        wrong_checker_cnf, wrong_checker_artifact, wrong_checker);
    require(!checker_mismatch.accepted &&
            checker_mismatch.message.find("checker identity") != std::string::npos,
        "artifact checker accepted a mismatched checker identity");

    auto malformed_artifact_text = artifact_output.str();
    const auto schema_at = malformed_artifact_text.find("Q3A_DRAT_ARTIFACT 2");
    malformed_artifact_text.replace(schema_at,
        std::string("Q3A_DRAT_ARTIFACT 2").size(), "Q3A_DRAT_ARTIFACT 3");
    std::istringstream malformed_artifact_cnf(branching_cnf);
    std::istringstream malformed_artifact(malformed_artifact_text);
    require(!q3a::checker::verify_drat_artifact(
        malformed_artifact_cnf, malformed_artifact, metadata).accepted,
        "artifact checker accepted an unsupported proof schema");

    std::istringstream satisfiable_input("p cnf 1 1\n1 0\n");
    const auto satisfiable = q3a::checker::generate_rup_refutation(satisfiable_input);
    require(satisfiable.status == q3a::checker::ProofStatus::Satisfiable,
        "proof search misclassified a satisfiable CNF");

    std::istringstream limited_input(branching_cnf);
    q3a::checker::ProofLimits limited;
    limited.maximum_search_nodes = 1;
    const auto unknown = q3a::checker::generate_rup_refutation(limited_input, limited);
    require(unknown.status == q3a::checker::ProofStatus::Unknown,
        "proof search must return UNKNOWN when its search budget is exhausted");

    std::istringstream depth_limited_input(
        "p cnf 3 8\n"
        "1 2 3 0\n1 2 -3 0\n1 -2 3 0\n1 -2 -3 0\n"
        "-1 2 3 0\n-1 2 -3 0\n-1 -2 3 0\n-1 -2 -3 0\n");
    q3a::checker::ProofLimits depth_limited;
    depth_limited.maximum_depth = 1;
    const auto depth_unknown = q3a::checker::generate_rup_refutation(
        depth_limited_input, depth_limited);
    require(depth_unknown.status == q3a::checker::ProofStatus::Unknown,
        "proof search must return UNKNOWN when its recursion-depth budget is exhausted");

    const auto oracle_result =
        check_small_formula_sat_preservation();
    std::cout << "PASS: exhaustive two-variable SAT-preservation oracle rejected "
              << oracle_result.checked_candidate_proofs
              << " one-addition refutation traces across all 512 formula sets, including "
              << oracle_result.sat_destroying_additions
              << " candidates that individually destroy satisfiability.\n";
    std::cout << "PASS: naive full-scan oracle cross-checked "
              << oracle_result.checked_rup_additions
              << " positive two-variable RUP additions against watched propagation.\n";

    const auto three_variable_result =
        check_three_variable_sat_preservation_sample();
    std::cout << "PASS: deterministic three-variable SAT-preservation sample rejected "
              << three_variable_result.checked_candidate_proofs
              << " one-addition refutation traces across 128 sampled formula masks, including "
              << three_variable_result.sat_destroying_additions
              << " candidates that individually destroy satisfiability.\n";
    std::cout << "PASS: naive full-scan oracle cross-checked "
              << three_variable_result.checked_rup_additions
              << " positive three-variable RUP additions against watched propagation.\n";

    const auto rat_oracle_result = check_three_variable_rat_differential_sample();
    std::cout << "PASS: independent full-scan RUP/RAT oracle agreed with watched checker on "
              << rat_oracle_result.accepted_additions + rat_oracle_result.rejected_additions
              << " three-variable candidate additions across 128 formula masks ("
              << rat_oracle_result.accepted_additions << " accepted, "
              << rat_oracle_result.rejected_additions << " rejected), including "
              << rat_oracle_result.rat_only_additions << " RAT-only additions.\n";

    return 0;
}
