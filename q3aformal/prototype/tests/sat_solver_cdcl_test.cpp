#include "../source/sat/sat_solver.hpp"
#include "../checker/drat_checker.hpp"

#include <cstdint>
#include <iostream>
#include <random>
#include <sstream>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace {

using q3a::sat::Literal;
using q3a::sat::Solver;
using q3a::sat::Status;

bool literal_value(Literal literal, std::uint64_t assignment) {
    const auto variable = static_cast<unsigned>(
        literal < 0 ? -static_cast<std::int64_t>(literal) : literal);
    const bool value = ((assignment >> (variable - 1U)) & 1U) != 0;
    return literal > 0 ? value : !value;
}

bool brute_force(std::uint32_t variable_count,
                 const std::vector<std::vector<Literal>>& clauses,
                 const std::vector<Literal>& assumptions) {
    const auto assignment_count = std::uint64_t{1} << variable_count;
    for (std::uint64_t assignment = 0; assignment < assignment_count; ++assignment) {
        bool assumptions_hold = true;
        for (const auto assumption : assumptions) {
            if (!literal_value(assumption, assignment)) {
                assumptions_hold = false;
                break;
            }
        }
        if (!assumptions_hold) continue;

        bool formula_holds = true;
        for (const auto& clause : clauses) {
            bool clause_holds = false;
            for (const auto literal : clause) {
                if (literal_value(literal, assignment)) {
                    clause_holds = true;
                    break;
                }
            }
            if (!clause_holds) {
                formula_holds = false;
                break;
            }
        }
        if (formula_holds) return true;
    }
    return false;
}

bool assignment_satisfies(const q3a::sat::Result& result,
                          std::uint32_t variable_count,
                          const std::vector<std::vector<Literal>>& clauses,
                          const std::vector<Literal>& assumptions) {
    if (result.assignment.size() != static_cast<std::size_t>(variable_count) + 1) {
        return false;
    }
    for (std::uint32_t variable = 1; variable <= variable_count; ++variable) {
        if (result.assignment[variable] != 0 && result.assignment[variable] != 1) {
            return false;
        }
    }
    const auto value = [&result](Literal literal) {
        const auto variable = static_cast<std::size_t>(
            literal < 0 ? -static_cast<std::int64_t>(literal) : literal);
        const bool bit = result.assignment[variable] != 0;
        return literal > 0 ? bit : !bit;
    };
    for (const auto& clause : clauses) {
        bool clause_holds = false;
        for (const auto literal : clause) clause_holds = clause_holds || value(literal);
        if (!clause_holds) return false;
    }
    for (const auto assumption : assumptions) {
        if (!value(assumption)) return false;
    }
    return true;
}

void check_drat_log(const std::string& label,
                    const Solver& solver,
                    const q3a::sat::Result& result) {
    if (result.status != Status::Unsatisfiable || result.drat_additions.empty() ||
        !result.drat_additions.back().empty()) {
        throw std::runtime_error(label + ": missing complete CDCL refutation log");
    }

    std::ostringstream cnf;
    solver.write_dimacs(cnf);
    std::ostringstream proof;
    for (const auto& clause : result.drat_additions) {
        for (const auto literal : clause) proof << literal << ' ';
        proof << "0\n";
    }
    std::istringstream cnf_input(cnf.str());
    std::istringstream proof_input(proof.str());
    const auto checked = q3a::checker::verify_drat(cnf_input, proof_input);
    if (!checked.accepted) {
        throw std::runtime_error(label + ": independent DRAT checker rejected CDCL log: " +
                                 checked.message);
    }
}

void check_formula(const std::string& label,
                   std::uint32_t variable_count,
                   const std::vector<std::vector<Literal>>& clauses,
                   const std::vector<Literal>& assumptions,
                   Solver& solver) {
    const bool expected_sat = brute_force(variable_count, clauses, assumptions);
    const auto result = solver.solve({}, assumptions);
    const auto expected_status = expected_sat ? Status::Satisfiable : Status::Unsatisfiable;
    if (result.status != expected_status) {
        throw std::runtime_error(label + ": solver status differs from exhaustive oracle");
    }
    if (result.status == Status::Satisfiable &&
        !assignment_satisfies(result, variable_count, clauses, assumptions)) {
        throw std::runtime_error(label + ": returned assignment violates the input");
    }
}

void check_wide_base_clause_storage_is_shared() {
    constexpr Literal width = 262144;
    constexpr auto literal_bytes = static_cast<std::uint64_t>(width) * sizeof(Literal);
    bool solving = false;
    Solver solver([&](std::uint64_t pending) {
        if (solving && pending == literal_bytes) {
            throw std::runtime_error("the solve requested a duplicate of the wide base clause");
        }
    });
    std::vector<Literal> clause;
    std::vector<Literal> assumptions;
    clause.reserve(width);
    assumptions.reserve(width);
    for (Literal variable = 1; variable <= width; ++variable) {
        solver.new_variable();
        clause.push_back(variable);
        assumptions.push_back(-variable);
    }
    solver.add_clause(clause);
    solving = true;
    if (solver.solve({}, assumptions).status != Status::Unsatisfiable) {
        throw std::runtime_error("wide clause did not conflict under all-negative assumptions");
    }
    assumptions.front() = 1;
    if (solver.solve({}, assumptions).status != Status::Satisfiable ||
        solver.clause_count() != 1) {
        throw std::runtime_error("a repeated solve changed the wide base clause");
    }
}

void check_temporary_clause_does_not_change_base_query() {
    Solver solver;
    const auto a = static_cast<Literal>(solver.new_variable());
    const auto b = static_cast<Literal>(solver.new_variable());
    solver.add_clause({-a});
    std::ostringstream before;
    solver.write_dimacs(before);

    const auto sat = solver.solve_with_temporary_clause({a, b, b});
    if (sat.status != Status::Satisfiable || sat.assignment[b] != 1 ||
        solver.solve_with_temporary_clause({a}).status != Status::Unsatisfiable ||
        solver.solve_with_temporary_clause({}).status != Status::Unsatisfiable ||
        solver.solve_with_temporary_clause({a, -a}).status != Status::Satisfiable) {
        throw std::runtime_error("temporary clauses changed the expected SAT verdict");
    }
    bool invalid_rejected = false;
    try {
        (void)solver.solve_with_temporary_clause({0});
    } catch (const std::invalid_argument&) {
        invalid_rejected = true;
    }
    std::ostringstream after;
    solver.write_dimacs(after);
    if (!invalid_rejected || before.str() != after.str() ||
        solver.solve().status != Status::Satisfiable) {
        throw std::runtime_error("temporary clauses changed the original CNF");
    }
}

void check_memory_interrupt_restores_temporary_clause() {
    for (const auto stop_at_clause_count : {1U, 2U}) {
        bool stop = false;
        std::uint64_t rejected_allocation = 0;
        Solver solver([&](std::uint64_t pending_bytes) {
            if (stop && solver.clause_count() == stop_at_clause_count && pending_bytes > 0) {
                rejected_allocation = pending_bytes;
                throw std::runtime_error("test memory limit");
            }
        });
        const auto a = static_cast<Literal>(solver.new_variable());
        const auto b = static_cast<Literal>(solver.new_variable());
        solver.add_clause({-a});
        std::ostringstream before;
        solver.write_dimacs(before);

        stop = true;
        bool interrupted = false;
        try {
            (void)solver.solve_with_temporary_clause({a, b});
        } catch (const std::runtime_error& error) {
            interrupted = std::string(error.what()) == "test memory limit";
        }
        stop = false;
        std::ostringstream after;
        solver.write_dimacs(after);
        if (!interrupted || rejected_allocation == 0 || before.str() != after.str() ||
            solver.solve({}, {-b}).status != Status::Satisfiable ||
            solver.solve_with_temporary_clause({a, b}).status != Status::Satisfiable) {
            throw std::runtime_error("memory interrupt left a temporary clause in the solver");
        }
    }
}

void check_incremental_permanent_clauses() {
    Solver solver;
    const auto a = static_cast<Literal>(solver.new_variable());
    const auto b = static_cast<Literal>(solver.new_variable());
    solver.add_clause({-a, b});
    solver.add_clause({-a, -b});
    std::ostringstream original;
    solver.write_dimacs(original);

    const auto first = solver.solve_incremental();
    if (first.status != Status::Satisfiable || first.reused_clauses != 0 ||
        first.learned_clauses == 0 || first.assignment[a] != 0) {
        throw std::runtime_error("incremental feasibility did not learn the forced assignment");
    }
    if (solver.solve_with_temporary_clause({a}).status != Status::Unsatisfiable ||
        solver.solve({}, {a}).status != Status::Unsatisfiable ||
        solver.solve_incremental().status != Status::Satisfiable) {
        throw std::runtime_error("a temporary conflict contaminated a permanent solve");
    }
    std::ostringstream after_temporary;
    solver.write_dimacs(after_temporary);
    if (original.str() != after_temporary.str()) {
        throw std::runtime_error("incremental state changed the serialized base CNF");
    }

    // New variables and clauses preserve consequences of the previous CNF.
    const auto c = static_cast<Literal>(solver.new_variable());
    solver.add_clause({a, c});
    const auto grown = solver.solve_incremental();
    if (grown.status != Status::Satisfiable || grown.reused_clauses == 0 ||
        grown.assignment[a] != 0 || grown.assignment[c] != 1) {
        throw std::runtime_error("incremental solve failed to reuse the learned consequence");
    }
    solver.add_clause({-c});
    const auto unsat = solver.solve_incremental();
    if (unsat.status != Status::Unsatisfiable || unsat.reused_clauses == 0) {
        throw std::runtime_error("incremental solve missed the strengthened formula conflict");
    }
    q3a::sat::Limits limits;
    limits.record_drat_proof = true;
    const auto proof = solver.solve(limits);
    if (proof.status != Status::Unsatisfiable || proof.reused_clauses != 0) {
        throw std::runtime_error("standalone proof was not generated from the original CNF");
    }
    check_drat_log("incremental_proof_isolation", solver, proof);
}

void check_learning_and_backjump_path() {
    Solver solver;
    const auto a = static_cast<Literal>(solver.new_variable());
    const auto b = static_cast<Literal>(solver.new_variable());
    const auto c = static_cast<Literal>(solver.new_variable());
    const std::vector<std::vector<Literal>> clauses{
        {-a, b}, {-a, -b}, {a, c}, {a, -c}};
    for (const auto& clause : clauses) solver.add_clause(clause);

    q3a::sat::Limits proof_limits;
    proof_limits.record_drat_proof = true;
    const auto result = solver.solve(proof_limits);
    if (result.status != Status::Unsatisfiable || result.learned_clauses == 0 ||
        result.conflicts < 2) {
        throw std::runtime_error(
            "crafted conflict case did not exercise learning and a root conflict");
    }
    if (brute_force(3, clauses, {})) {
        throw std::runtime_error("crafted conflict case is not actually UNSAT");
    }
    check_drat_log("crafted_1_uip", solver, result);

    std::vector<std::vector<Literal>> emitted;
    proof_limits.proof_sink = [&](const std::vector<Literal>& clause) {
        emitted.push_back(clause);
    };
    const auto streamed = solver.solve(proof_limits);
    if (streamed.status != Status::Unsatisfiable || !streamed.drat_additions.empty() ||
        streamed.proof_record_count != emitted.size() || emitted != result.drat_additions) {
        throw std::runtime_error("streamed refutation differs from the buffered CDCL proof");
    }
    emitted.clear();
    proof_limits.proof_records = streamed.proof_record_count - 1;
    const auto stopped = solver.solve(proof_limits);
    if (stopped.status != Status::Unknown || stopped.proof_record_count != 0 ||
        emitted.size() != proof_limits.proof_records || emitted.back().empty()) {
        throw std::runtime_error("a partial streamed proof was marked complete");
    }
}

void check_nonchronological_backjump_case() {
    Solver solver;
    const auto x = static_cast<Literal>(solver.new_variable());
    solver.new_variable(); // Unconstrained level between x and z.
    const auto z = static_cast<Literal>(solver.new_variable());
    const auto w = static_cast<Literal>(solver.new_variable());
    const auto q = static_cast<Literal>(solver.new_variable());
    const std::vector<std::vector<Literal>> clauses{
        {-x, q}, {-z, -w}, {-z, -q, w}};
    for (const auto& clause : clauses) solver.add_clause(clause);

    const auto result = solver.solve();
    if (result.status != Status::Satisfiable ||
        !assignment_satisfies(result, 5, clauses, {}) ||
        result.nonchronological_backjumps == 0) {
        throw std::runtime_error(
            "crafted three-level case did not skip an irrelevant decision level");
    }
}

void check_pigeonhole_case(std::uint32_t pigeons, std::uint32_t holes) {
    Solver solver;
    std::vector<std::vector<Literal>> occupancy(
        pigeons, std::vector<Literal>(holes));
    for (auto& pigeon : occupancy) {
        for (auto& variable : pigeon) {
            variable = static_cast<Literal>(solver.new_variable());
        }
    }

    std::vector<std::vector<Literal>> clauses;
    const auto add_clause = [&solver, &clauses](std::vector<Literal> clause) {
        solver.add_clause(clause);
        clauses.push_back(std::move(clause));
    };
    for (std::uint32_t pigeon = 0; pigeon < pigeons; ++pigeon) {
        add_clause(occupancy[pigeon]);
        for (std::uint32_t first = 0; first < holes; ++first) {
            for (std::uint32_t second = first + 1; second < holes; ++second) {
                add_clause({-occupancy[pigeon][first], -occupancy[pigeon][second]});
            }
        }
    }
    for (std::uint32_t hole = 0; hole < holes; ++hole) {
        for (std::uint32_t first = 0; first < pigeons; ++first) {
            for (std::uint32_t second = first + 1; second < pigeons; ++second) {
                add_clause({-occupancy[first][hole], -occupancy[second][hole]});
            }
        }
    }

    const auto label = "pigeonhole_" + std::to_string(pigeons) + "_into_" + std::to_string(holes);
    if (pigeons * holes <= 12) {
        check_formula(label, pigeons * holes, clauses, {}, solver);
    }
    if (pigeons <= holes) {
        const auto result = solver.solve();
        if (result.status != Status::Satisfiable ||
            !assignment_satisfies(result, pigeons * holes, clauses, {})) {
            throw std::runtime_error(label + ": solver missed or invalidated a feasible injection");
        }
        return;
    }
    q3a::sat::Limits proof_limits;
    proof_limits.record_drat_proof = true;
    const auto result = solver.solve(proof_limits);
    if (result.learned_clauses == 0) {
        throw std::runtime_error("pigeonhole case produced no learned clauses");
    }
    check_drat_log(label, solver, result);
}

void check_root_conflict_proofs() {
    q3a::sat::Limits proof_limits;
    proof_limits.record_drat_proof = true;

    Solver empty_clause_solver;
    empty_clause_solver.new_variable();
    empty_clause_solver.add_clause({});
    const auto empty_clause_result = empty_clause_solver.solve(proof_limits);
    check_drat_log("explicit_empty_clause", empty_clause_solver, empty_clause_result);

    Solver propagation_conflict_solver;
    const auto x = static_cast<Literal>(propagation_conflict_solver.new_variable());
    const auto y = static_cast<Literal>(propagation_conflict_solver.new_variable());
    const std::vector<std::vector<Literal>> clauses{
        {x}, {-x, y}, {-x, -y}};
    for (const auto& clause : clauses) propagation_conflict_solver.add_clause(clause);
    const auto propagation_result = propagation_conflict_solver.solve(proof_limits);
    check_drat_log("root_propagation_conflict", propagation_conflict_solver,
                   propagation_result);

    bool rejected_assumption_proof = false;
    try {
        (void)propagation_conflict_solver.solve(proof_limits, {x});
    } catch (const std::invalid_argument&) {
        rejected_assumption_proof = true;
    }
    if (!rejected_assumption_proof) {
        throw std::runtime_error("proof logging accepted temporary assumptions");
    }
}

void check_random_formulas() {
    std::mt19937 random(0x3AFA2026U);
    std::uint64_t sat_queries = 0;
    std::uint64_t unsat_queries = 0;
    std::uint64_t checked_proof_queries = 0;
    constexpr std::uint32_t kFormulaCount = 1800;

    for (std::uint32_t formula_index = 0;
         formula_index < kFormulaCount; ++formula_index) {
        const std::uint32_t variable_count = 1U + random() % 8U;
        Solver solver;
        for (std::uint32_t variable = 0; variable < variable_count; ++variable) {
            solver.new_variable();
        }

        std::vector<std::vector<Literal>> clauses;
        const auto clause_count = random() % 25U;
        for (std::uint32_t clause_index = 0; clause_index < clause_count;
             ++clause_index) {
            std::vector<Literal> clause;
            const auto clause_length = 1U + random() % 6U;
            for (std::uint32_t literal_index = 0; literal_index < clause_length;
                 ++literal_index) {
                const auto variable = static_cast<Literal>(1U + random() % variable_count);
                clause.push_back((random() & 1U) != 0 ? variable : -variable);
            }
            clauses.push_back(clause);
            solver.add_clause(clause);
        }

        for (std::uint32_t query_index = 0; query_index < 3; ++query_index) {
            std::vector<Literal> assumptions;
            const auto assumption_count = random() % (variable_count + 2U);
            for (std::uint32_t index = 0; index < assumption_count; ++index) {
                const auto variable = static_cast<Literal>(1U + random() % variable_count);
                assumptions.push_back((random() & 1U) != 0 ? variable : -variable);
            }
            const auto expected_sat = brute_force(variable_count, clauses, assumptions);
            const auto result = solver.solve({}, assumptions);
            const auto expected_status = expected_sat
                ? Status::Satisfiable : Status::Unsatisfiable;
            const auto label = "formula=" + std::to_string(formula_index) +
                " query=" + std::to_string(query_index);
            if (result.status != expected_status) {
                throw std::runtime_error(label + ": solver disagrees with brute force");
            }
            if (expected_sat && !assignment_satisfies(
                    result, variable_count, clauses, assumptions)) {
                throw std::runtime_error(label + ": invalid SAT assignment");
            }
            if (!expected_sat && query_index == 0) {
                Solver proof_solver;
                for (std::uint32_t variable = 0; variable < variable_count; ++variable) {
                    proof_solver.new_variable();
                }
                for (const auto& clause : clauses) proof_solver.add_clause(clause);
                for (const auto assumption : assumptions) {
                    proof_solver.add_clause({assumption});
                }
                q3a::sat::Limits proof_limits;
                proof_limits.record_drat_proof = true;
                const auto proof_result = proof_solver.solve(proof_limits);
                if (proof_result.status != Status::Unsatisfiable) {
                    throw std::runtime_error(label + ": unit-encoded query lost UNSAT status");
                }
                check_drat_log(label + "_proof", proof_solver, proof_result);
                ++checked_proof_queries;
            }
            if (expected_sat) ++sat_queries;
            else ++unsat_queries;
        }
        for (std::size_t stage = 0; stage < 3; ++stage) {
            const auto expected = brute_force(variable_count, clauses, {});
            const auto incremental = solver.solve_incremental();
            if (incremental.status != (expected ? Status::Satisfiable : Status::Unsatisfiable) ||
                (expected && !assignment_satisfies(incremental, variable_count, clauses, {}))) {
                throw std::runtime_error("incremental formula differs from exhaustive oracle at formula " +
                    std::to_string(formula_index) + ", stage " + std::to_string(stage));
            }
            if (stage == 2) continue;
            // Each stage appends a permanent unit without changing the
            // deterministic query sequence in the main random oracle.
            const auto unit = stage == 0 ? Literal{1} : -static_cast<Literal>(variable_count);
            clauses.push_back({unit});
            solver.add_clause({unit});
        }
    }

    std::cout << "CDCL_DIFFERENTIAL_PASS formulas=" << kFormulaCount
              << " queries=" << (sat_queries + unsat_queries)
              << " sat=" << sat_queries << " unsat=" << unsat_queries << '\n';
    std::cout << "CDCL_DRAT_ORACLE_PASS checked_proofs="
              << checked_proof_queries << '\n';
    std::cout << "CDCL_INCREMENTAL_ORACLE_PASS queries=" << (3 * kFormulaCount) << '\n';
}

void check_resource_limits() {
    Solver decision_limited;
    decision_limited.new_variable();
    decision_limited.new_variable();
    const auto decision_result = decision_limited.solve({1, 0});
    if (decision_result.status != Status::Unknown || decision_result.decisions != 1) {
        throw std::runtime_error("decision budget did not return UNKNOWN at the limit");
    }

    Solver propagation_limited;
    const auto first = static_cast<Literal>(propagation_limited.new_variable());
    const auto second = static_cast<Literal>(propagation_limited.new_variable());
    propagation_limited.add_clause({first});
    propagation_limited.add_clause({second});
    const auto propagation_result = propagation_limited.solve({0, 1});
    if (propagation_result.status != Status::Unknown ||
        propagation_result.propagations != 1) {
        throw std::runtime_error("propagation budget did not return UNKNOWN at the limit");
    }

    Solver incomplete_proof;
    const auto x = static_cast<Literal>(incomplete_proof.new_variable());
    incomplete_proof.new_variable();
    const auto z = static_cast<Literal>(incomplete_proof.new_variable());
    const auto w = static_cast<Literal>(incomplete_proof.new_variable());
    const auto q = static_cast<Literal>(incomplete_proof.new_variable());
    incomplete_proof.add_clause({-x, q});
    incomplete_proof.add_clause({-z, -w});
    incomplete_proof.add_clause({-z, -q, w});
    q3a::sat::Limits proof_decision_limit{3, 0, true};
    const auto incomplete_result = incomplete_proof.solve(proof_decision_limit);
    if (incomplete_result.status != Status::Unknown ||
        !incomplete_result.drat_additions.empty()) {
        throw std::runtime_error("incomplete SAT search exposed a partial proof as complete");
    }

    Solver proof_record_limited;
    const auto a = static_cast<Literal>(proof_record_limited.new_variable());
    const auto b = static_cast<Literal>(proof_record_limited.new_variable());
    const auto c = static_cast<Literal>(proof_record_limited.new_variable());
    proof_record_limited.add_clause({-a, b});
    proof_record_limited.add_clause({-a, -b});
    proof_record_limited.add_clause({a, c});
    proof_record_limited.add_clause({a, -c});
    q3a::sat::Limits proof_record_limit;
    proof_record_limit.record_drat_proof = true;
    proof_record_limit.proof_records = 1;
    const auto limited_proof_result = proof_record_limited.solve(proof_record_limit);
    if (limited_proof_result.status != Status::Unknown ||
        !limited_proof_result.drat_additions.empty()) {
        throw std::runtime_error("proof-record limit exposed an incomplete refutation");
    }
}

} // namespace

int main() {
    try {
        check_wide_base_clause_storage_is_shared();
        check_temporary_clause_does_not_change_base_query();
        check_memory_interrupt_restores_temporary_clause();
        check_incremental_permanent_clauses();
        check_learning_and_backjump_path();
        check_nonchronological_backjump_case();
        check_pigeonhole_case(4, 3);
        check_pigeonhole_case(6, 5);
        check_pigeonhole_case(6, 6);
        std::cout << "SAT_PIGEONHOLE_ORACLE_PASS 30-variable UNSAT proof and 36-variable SAT model\n";
        check_root_conflict_proofs();
        check_random_formulas();
        check_resource_limits();
        std::cout << "SAT_CDCL_ORACLE_PASS\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "SAT_CDCL_ORACLE_FAIL " << error.what() << '\n';
        return 1;
    }
}
